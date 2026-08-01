#!/usr/bin/env python3
"""Behavior tests for the gateway-to-Dagu evaluation ingress."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
RECEIVER = ROOT / "scripts" / "eval-receiver.py"
TEMPLATE = ROOT / "config" / "litellm.yaml"


def _render_template(env):
    """Apply the template's requires markers with a controlled environment."""
    rendered = []
    skip = False
    for line in TEMPLATE.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("# >>> requires "):
            key = stripped.split()[3]
            skip = not env.get(key)
            continue
        if stripped.startswith("# <<< requires "):
            skip = False
            continue
        if not skip:
            rendered.append(line)
    return yaml.safe_load("\n".join(rendered))


class EvalIngressTest(unittest.TestCase):
    def test_receiver_append_waits_for_cross_process_spool_lock(self):
        self.assertTrue(RECEIVER.exists(), "eval receiver is not implemented")
        spec = importlib.util.spec_from_file_location("eval_receiver", RECEIVER)
        receiver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(receiver)

        with tempfile.TemporaryDirectory() as tmp:
            spool = Path(tmp) / "eval-spool.jsonl"
            receiver.SPOOL = str(spool)
            receiver.SPOOL_MAX_BYTES = 1024 * 1024

            ready_r, ready_w = os.pipe()
            release_r, release_w = os.pipe()
            holder = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import fcntl, os, sys; "
                    "fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o600); "
                    "fcntl.flock(fd, fcntl.LOCK_EX); "
                    "os.write(int(sys.argv[2]), b'1'); "
                    "os.read(int(sys.argv[3]), 1); os.close(fd)",
                    str(spool) + ".lock",
                    str(ready_w),
                    str(release_r),
                ],
                pass_fds=(ready_w, release_r),
            )

            os.close(ready_w)
            os.close(release_r)
            os.read(ready_r, 1)

            result = []
            errors = []

            def append():
                try:
                    result.append(receiver._append([
                        {"trace_id": "trace-1", "response": "ok"},
                        {"response": "missing trace id"},
                    ]))
                except Exception as exc:  # surfaced after releasing the child
                    errors.append(exc)

            thread = threading.Thread(target=append)
            thread.start()
            try:
                thread.join(0.2)
                self.assertTrue(
                    thread.is_alive(),
                    "receiver wrote while another process held the spool lock",
                )
            finally:
                os.write(release_w, b"1")
                os.close(release_w)
                thread.join(2)
                holder.wait(timeout=2)

            self.assertFalse(thread.is_alive(), "receiver did not resume after lock release")
            self.assertEqual(errors, [])
            self.assertEqual(result, [1])
            self.assertEqual(
                [json.loads(line) for line in spool.read_text().splitlines()],
                [{"trace_id": "trace-1", "response": "ok"}],
            )

    def test_generic_callback_is_rendered_only_with_endpoint(self):
        without_endpoint = _render_template({"LANGFUSE_ENABLED": "1"})
        with_endpoint = _render_template({
            "LANGFUSE_ENABLED": "1",
            "GENERIC_LOGGER_ENDPOINT": "http://127.0.0.1:4010/",
        })

        self.assertNotIn("callbacks", without_endpoint["litellm_settings"])
        self.assertIn("callbacks", with_endpoint["litellm_settings"])
        self.assertEqual(
            with_endpoint["litellm_settings"]["callbacks"],
            ["generic_api"],
        )
        self.assertEqual(
            with_endpoint["litellm_settings"]["success_callback"],
            ["langfuse"],
        )


if __name__ == "__main__":
    unittest.main()
