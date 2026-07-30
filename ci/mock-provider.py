#!/usr/bin/env python3
"""Minimal OpenAI-compatible provider for the end-to-end CI job.

Exists so the whole chain (gateway -> harness -> round-trip) can run on a
throwaway runner with NO real provider credentials: it plugs into the
OLLAMA_BASE override that scripts/30-gateway.sh already supports, so nothing
in the production path is bent for testing.

Deliberate properties:

* Publishes MOCK_MODEL_COUNT models. The count is load-bearing, not padding:
  the false-negative bug fixed in #15 (`printf | grep -q` returning 141 under
  `set -o pipefail`) only reproduces once output exceeds the 64 KiB pipe
  buffer, so a catalog of five models would have passed a green build. The
  workflow asserts the resulting output is actually large enough.
* Requires `Authorization: Bearer $MOCK_API_KEY` and 401s otherwise, so a run
  that never forwards the credential fails instead of passing blind.
* Echoes the last user message back as the completion, so it is agnostic to
  whatever sentinel a caller greps for (LAVA-GATEWAY-OK, OC-GATEWAY-OK, ...)
  and won't need editing when one changes.
* Publishes no pricing — same shape as Ollama Cloud and OpenCode Zen, which
  is the case where invented metadata would otherwise go unnoticed.

Loopback-only by design; it is a test double, not a service.
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("MOCK_PORT", "8899"))
API_KEY = os.environ.get("MOCK_API_KEY", "")
MODEL_COUNT = int(os.environ.get("MOCK_MODEL_COUNT", "800"))

if not API_KEY:
    sys.exit("mock-provider: MOCK_API_KEY must be set (auth is asserted, not optional)")

# Long-ish ids on purpose: the pipe-buffer regression class above is a
# function of total output bytes, not model count.
MODELS = [
    f"mock-vendor-{i // 100:02d}/ci-chat-model-{i:04d}-instruct-preview"
    for i in range(MODEL_COUNT)
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A002 - stdlib signature
        sys.stderr.write("mock-provider: " + (fmt % args) + "\n")
        sys.stderr.flush()

    # --- helpers ---------------------------------------------------------
    def _send(self, code, payload, ctype="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        if self.headers.get("Authorization", "") == f"Bearer {API_KEY}":
            return True
        self.log_message("401 missing/incorrect bearer token on %s", self.path)
        self._send(401, {"error": {"message": "invalid api key", "type": "auth_error"}})
        return False

    def _last_user_message(self, body):
        """Echo target: the last user turn, whatever it says."""
        for msg in reversed(body.get("messages") or []):
            if msg.get("role") != "user":
                continue
            content = msg.get("content")
            if isinstance(content, str):
                return content
            if isinstance(content, list):  # content-parts form
                return " ".join(
                    p.get("text", "") for p in content if isinstance(p, dict)
                )
        return "(no user message)"

    # --- routes ----------------------------------------------------------
    def do_GET(self):
        if self.path.rstrip("/") in ("/health", "/v1/health"):
            self._send(200, {"status": "ok", "models": len(MODELS)})
            return
        if self.path.rstrip("/") == "/v1/models":
            if not self._authed():
                return
            # Same minimal shape Ollama Cloud / OpenCode Zen return: id,
            # object, created, owned_by -- and no pricing whatsoever.
            self._send(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": m,
                            "object": "model",
                            "created": 1735689600,
                            "owned_by": "lavasec-ci",
                        }
                        for m in MODELS
                    ],
                },
            )
            return
        self._send(404, {"error": {"message": f"no route for {self.path}"}})

    def do_POST(self):
        if self.path.rstrip("/") not in ("/v1/chat/completions", "/chat/completions"):
            self._send(404, {"error": {"message": f"no route for {self.path}"}})
            return
        if not self._authed():
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError as exc:
            self._send(400, {"error": {"message": f"bad json: {exc}"}})
            return

        model = body.get("model") or "mock-model"
        reply = self._last_user_message(body)
        created = 1735689600
        usage = {
            "prompt_tokens": max(1, len(reply) // 4),
            "completion_tokens": max(1, len(reply) // 4),
            "total_tokens": max(2, len(reply) // 2),
        }

        if body.get("stream"):
            self._stream(model, reply, created, usage, body)
            return

        self._send(
            200,
            {
                "id": "chatcmpl-mock-0001",
                "object": "chat.completion",
                "created": created,
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": reply},
                        "finish_reason": "stop",
                    }
                ],
                "usage": usage,
            },
        )

    def _stream(self, model, reply, created, usage, body):
        """SSE form -- harness CLIs stream by default, so this path is the
        one that actually gets exercised by pi/opencode."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def chunk(delta, finish=None):
            payload = {
                "id": "chatcmpl-mock-0001",
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())

        chunk({"role": "assistant", "content": ""})
        # One chunk per word keeps the sentinel intact for a substring grep
        # while still exercising multi-chunk reassembly.
        for word in reply.split(" "):
            chunk({"content": word + " "})
        chunk({}, finish="stop")
        if (body.get("stream_options") or {}).get("include_usage"):
            self.wfile.write(
                f"data: {json.dumps({'id': 'chatcmpl-mock-0001', 'object': 'chat.completion.chunk', 'created': created, 'model': model, 'choices': [], 'usage': usage})}\n\n".encode()
            )
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    sys.stderr.write(
        f"mock-provider: listening on 127.0.0.1:{PORT} with {len(MODELS)} models\n"
    )
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
