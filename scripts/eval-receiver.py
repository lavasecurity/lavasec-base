#!/usr/bin/env python3
"""Local sink for litellm's generic_api callback. Spools events, nudges Dagu.

The gateway posts a StandardLoggingPayload here on every completion. That
payload carries the SAME trace_id the langfuse callback resolves
(langfuse.py:555-562 reads it from standard_logging_object), so scores written
later join the right trace by construction rather than by correlation.

Why this exists at all: the eval used to poll Langfuse Cloud to discover what
to evaluate, which meant a local process was gated on a remote round trip, a
5-minute settle window, and a lookback that silently dropped anything older.
The payload arrives here complete — the response is already in it — so none of
that is needed. Langfuse is touched once, on publish.

Deliberately stdlib-only and loopback-only. It sits in the gateway's callback
path; a dependency here is a dependency of every request that gets traced.
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SPOOL = os.environ.get("LAVASEC_EVAL_SPOOL", "/var/lib/lavasec/eval-spool.jsonl")
BIND = os.environ.get("LAVASEC_EVAL_RECEIVER_BIND", "127.0.0.1")
PORT = int(os.environ.get("LAVASEC_EVAL_RECEIVER_PORT", "4010"))
DAGU_BIN = os.environ.get("DAGU_BIN", "/usr/local/bin/dagu")
DAG_NAME = os.environ.get("LAVASEC_EVAL_DAG", "langfuse-eval")
# Dagu's overlap_policy: skip already collapses a burst into one run, but each
# `dagu start` is still a process spawn. Debouncing here keeps a 50-event burst
# from spawning 50 processes only for 49 to be told to go away.
TRIGGER_DEBOUNCE_SEC = float(os.environ.get("LAVASEC_EVAL_TRIGGER_DEBOUNCE", "20"))
# A spool that grows without bound would eventually fill the disk on a free-tier
# box. The judge truncates what it consumes; this is the backstop for the case
# where the judge is broken and nobody noticed.
SPOOL_MAX_BYTES = int(os.environ.get("LAVASEC_EVAL_SPOOL_MAX_BYTES", str(64 * 1024 * 1024)))

_lock = threading.Lock()
_last_trigger = 0.0


def _log(msg):
    print(f"eval-receiver: {msg}", file=sys.stderr, flush=True)


def _trigger():
    """Nudge Dagu, debounced. Never raises into the request path."""
    global _last_trigger
    now = time.monotonic()
    with _lock:
        if now - _last_trigger < TRIGGER_DEBOUNCE_SEC:
            return
        _last_trigger = now
    try:
        subprocess.Popen([DAGU_BIN, "start", DAG_NAME],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except Exception as exc:
        # A missing or broken Dagu must not stop us spooling. The events keep
        # accumulating and the next successful trigger — or the DAG's own
        # schedule — picks them all up.
        _log(f"dagu trigger failed: {exc!r}")


def _append(events):
    with _lock:
        try:
            if os.path.exists(SPOOL) and os.path.getsize(SPOOL) > SPOOL_MAX_BYTES:
                _log(f"spool over {SPOOL_MAX_BYTES} bytes — dropping event, is the judge running?")
                return 0
        except OSError:
            pass
        written = 0
        with open(SPOOL, "a") as fh:
            for ev in events:
                # trace_id is the whole point; an event without one cannot be
                # joined to anything and is dropped here rather than failing
                # later in publish.
                if not isinstance(ev, dict) or not ev.get("trace_id"):
                    continue
                fh.write(json.dumps(ev, default=str) + "\n")
                written += 1
            fh.flush()
            os.fsync(fh.fileno())
    return written


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        # ALWAYS 204, whatever happens below. This endpoint sits in the
        # gateway's logging path: a non-2xx makes litellm retry, and a retry
        # storm caused by our own bug would be a self-inflicted load problem on
        # the box serving real traffic. Failures are logged, not signalled.
        try:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            payload = json.loads(raw or b"[]")
            events = payload if isinstance(payload, list) else [payload]
            n = _append(events)
            if n:
                _trigger()
        except Exception as exc:
            _log(f"rejected a payload: {exc!r}")
        self.send_response(204)
        self.end_headers()

    def do_GET(self):    # liveness, for the unit and for humans
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        size = os.path.getsize(SPOOL) if os.path.exists(SPOOL) else 0
        self.wfile.write(json.dumps({"ok": True, "spool": SPOOL, "spool_bytes": size}).encode())

    def log_message(self, *args):
        pass   # one line per traced request would drown the journal


def main():
    os.makedirs(os.path.dirname(SPOOL) or ".", exist_ok=True)
    if BIND not in ("127.0.0.1", "localhost", "::1"):
        # The gateway posts from this host. Anything else listening means the
        # spool — which holds full prompts and responses — is reachable off-box.
        _log(f"refusing to bind {BIND}: loopback only")
        return 1
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    _log(f"listening on {BIND}:{PORT}, spooling to {SPOOL}")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
