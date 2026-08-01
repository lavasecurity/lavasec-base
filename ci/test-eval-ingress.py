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
from urllib.request import Request, urlopen

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


def _load_receiver():
    spec = importlib.util.spec_from_file_location("eval_receiver", RECEIVER)
    receiver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(receiver)
    return receiver


def _fake_dagu(directory, marker):
    executable = Path(directory) / "dagu"
    executable.write_text(
        "#!/usr/bin/env python3\n"
        "import pathlib, sys\n"
        "with pathlib.Path(sys.argv[2]).open('a') as fh: fh.write('triggered\\n')\n"
    )
    executable.chmod(0o755)
    return str(executable), str(marker)


class EvalIngressTest(unittest.TestCase):
    def test_receiver_append_waits_for_cross_process_spool_lock(self):
        self.assertTrue(RECEIVER.exists(), "eval receiver is not implemented")
        receiver = _load_receiver()

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

    def test_each_valid_callback_triggers_dagu(self):
        receiver = _load_receiver()
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "triggers"
            receiver.DAGU_BIN, receiver.DAG = _fake_dagu(tmp, marker)

            processes = [receiver._trigger(), receiver._trigger()]
            for process in processes:
                self.assertIsNotNone(process)
                process.wait(timeout=2)

            self.assertEqual(
                marker.read_text().splitlines(),
                ["triggered", "triggered"],
                "a callback inside a burst lost its Dagu trigger",
            )

    def test_oversized_spool_still_triggers_dagu(self):
        receiver = _load_receiver()
        with tempfile.TemporaryDirectory() as tmp:
            spool = Path(tmp) / "eval-spool.jsonl"
            spool.write_text("already over capacity\n")
            marker = Path(tmp) / "triggers"
            receiver.SPOOL = str(spool)
            receiver.SPOOL_MAX_BYTES = 0
            receiver.DAGU_BIN, receiver.DAG = _fake_dagu(tmp, marker)
            real_trigger = receiver._trigger
            processes = []

            def tracked_trigger():
                process = real_trigger()
                processes.append(process)
                return process

            receiver._trigger = tracked_trigger

            server = receiver.ThreadingHTTPServer(("127.0.0.1", 0), receiver.Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                request = Request(
                    f"http://127.0.0.1:{server.server_port}/",
                    data=b'{"trace_id":"trace-over-capacity"}',
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urlopen(request, timeout=2) as response:
                    self.assertEqual(response.status, 204)
                self.assertEqual(len(processes), 1)
                self.assertIsNotNone(processes[0])
                processes[0].wait(timeout=2)
                self.assertEqual(marker.read_text().splitlines(), ["triggered"])
            finally:
                server.shutdown()
                server.server_close()
                thread.join(2)

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
