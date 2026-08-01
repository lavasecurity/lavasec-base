#!/usr/bin/env python3
"""Loopback sink for LiteLLM completions; spool them and trigger Dagu."""

from contextlib import contextmanager
import fcntl
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SPOOL = os.environ.get("LAVASEC_EVAL_SPOOL", "/var/lib/lavasec/eval-spool.jsonl")
BIND = os.environ.get("LAVASEC_EVAL_RECEIVER_BIND", "127.0.0.1")
PORT = int(os.environ.get("LAVASEC_EVAL_RECEIVER_PORT", "4010"))
DAGU_BIN = os.environ.get("DAGU_BIN", "/usr/local/bin/dagu")
DAG = os.environ.get(
    "LAVASEC_EVAL_DAG", "/etc/lavasec/dags/langfuse-eval.yaml"
)
SPOOL_MAX_BYTES = int(
    os.environ.get("LAVASEC_EVAL_SPOOL_MAX_BYTES", str(64 * 1024 * 1024))
)


def _log(message):
    print(f"eval-receiver: {message}", file=sys.stderr, flush=True)


@contextmanager
def _spool_lock():
    """Share the scorer's lock across open, append, flush, and fsync."""
    fd = os.open(SPOOL + ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _trigger():
    """Start the evaluator without blocking or affecting the request path."""
    try:
        return subprocess.Popen(
            [DAGU_BIN, "start", DAG],
            start_new_session=True,
        )
    except Exception as exc:
        _log(f"dagu trigger failed: {exc!r}")
        return None


def _append(events):
    valid = [event for event in events if isinstance(event, dict) and event.get("trace_id")]
    if not valid:
        return None

    with _spool_lock():
        try:
            if os.path.exists(SPOOL) and os.path.getsize(SPOOL) > SPOOL_MAX_BYTES:
                _log(
                    f"spool over {SPOOL_MAX_BYTES} bytes; dropping event until Dagu drains it"
                )
                return 0
        except OSError:
            pass

        fd = os.open(
            SPOOL,
            os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW,
            0o600,
        )
        with os.fdopen(fd, "a") as spool:
            os.fchmod(spool.fileno(), 0o600)
            for event in valid:
                spool.write(json.dumps(event, default=str) + "\n")
            spool.flush()
            os.fsync(spool.fileno())
    return len(valid)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        # This is a logging callback: always acknowledge so a receiver failure
        # cannot turn into a gateway retry storm.
        try:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            payload = json.loads(raw or b"[]")
            events = payload if isinstance(payload, list) else [payload]
            # Zero means the spool is over capacity. Trigger anyway so Dagu
            # can drain it and recover; None alone means no evaluable event.
            if _append(events) is not None:
                _trigger()
        except Exception as exc:
            _log(f"rejected payload: {exc!r}")
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        size = os.path.getsize(SPOOL) if os.path.exists(SPOOL) else 0
        self.wfile.write(json.dumps({"ok": True, "spool_bytes": size}).encode())

    def log_message(self, *_args):
        pass


def main():
    if BIND not in ("127.0.0.1", "localhost", "::1"):
        _log(f"refusing non-loopback bind: {BIND}")
        return 1
    os.makedirs(os.path.dirname(SPOOL) or ".", exist_ok=True)
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    _log(f"listening on {BIND}:{PORT}")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
