#!/usr/bin/env bash
set -euo pipefail
# 35-eval-receiver.sh — the local sink for litellm's generic_api callback.
#
# Runs scripts/eval-receiver.py as a systemd unit on loopback. The gateway
# posts a StandardLoggingPayload per completion and the receiver spools it,
# giving any downstream consumer the full request and response locally —
# including the SAME trace_id the langfuse callback uses, so anything written
# back joins the right trace.
#
# OPTIONAL, and off unless you ask for it. The callback block in
# config/litellm.yaml is gated on GENERIC_LOGGER_ENDPOINT, so a box that never
# sets that variable renders no callback and never talks to this.
#
# It nudges a scheduler after spooling (Dagu by default, DAGU_BIN/
# LAVASEC_EVAL_DAG to change it). If that binary is absent the trigger is
# logged and skipped — the spool still fills, and whatever drains it can run
# on its own schedule.
#
# Refuse to run as root, before anything else — same reasoning as 75-dagu.sh.
# The generated unit takes User= and HOME= from the invoking environment, so
# `sudo scripts/76-eval-receiver.sh` produces User=root, and this process
# receives and stores full prompts and responses. $EUID rather than $(id -u):
# bash sets EUID itself, so it cannot be defeated by a PATH without `id`.
if [ "${EUID}" -eq 0 ]; then
  echo "35-eval-receiver: refusing to run as root — run it as the service user" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPOOL_DIR="${LAVASEC_EVAL_SPOOL_DIR:-/var/lib/lavasec}"
SPOOL="${SPOOL_DIR}/eval-spool.jsonl"
PORT="${LAVASEC_EVAL_RECEIVER_PORT:-4010}"
UNIT=/etc/systemd/system/lavasec-eval-receiver.service

if [ ! -f "${REPO_DIR}/scripts/eval-receiver.py" ]; then
  echo "35-eval-receiver: no ${REPO_DIR}/scripts/eval-receiver.py" >&2
  exit 1
fi

# The spool holds prompts and responses in the clear. 0750 and owned by the
# service user: readable by that user, not by everyone with a shell on the box.
sudo install -d -m 750 -o "${USER}" -g "${USER}" "${SPOOL_DIR}"

sudo tee "${UNIT}" >/dev/null <<UNITFILE
[Unit]
Description=LavaSec eval receiver (litellm generic_api sink)
After=network-online.target

[Service]
User=${USER}
Environment=LAVASEC_EVAL_SPOOL=${SPOOL}
Environment=LAVASEC_EVAL_RECEIVER_PORT=${PORT}
Environment=LAVASEC_EVAL_RECEIVER_BIND=127.0.0.1
ExecStart=/usr/bin/python3 ${REPO_DIR}/scripts/eval-receiver.py
Restart=on-failure
RestartSec=5
# It only ever writes the spool. Everything else on the box is off limits: this
# process parses payloads derived from model output.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${SPOOL_DIR}

[Install]
WantedBy=multi-user.target
UNITFILE

sudo systemctl daemon-reload
sudo systemctl enable lavasec-eval-receiver >/dev/null
sudo systemctl restart lavasec-eval-receiver

# Verify it is actually up and actually on loopback. A receiver that silently
# failed to bind would look fine here and lose every event the gateway sends.
up=""
for _ in $(seq 1 15); do
  if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    up=1
    break
  fi
  sleep 1
done
if [ -z "${up}" ]; then
  echo "35-eval-receiver: did not come up — last 30 journal lines follow:" >&2
  sudo journalctl -u lavasec-eval-receiver -n 30 --no-pager >&2 || true
  exit 1
fi

# Refuse a wildcard bind outright rather than warning. The spool is prompt and
# response text; anything beyond loopback exposes it to the tailnet and beyond.
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(^|[^0-9.])(0\.0\.0\.0|\[?::\]?):${PORT}\$"; then
  echo "35-eval-receiver: listening beyond loopback on ${PORT} — stopping the unit" >&2
  sudo systemctl stop lavasec-eval-receiver
  exit 1
fi

echo "35-eval-receiver: OK (127.0.0.1:${PORT}, spool ${SPOOL})"
echo "  enable it by setting, in ${ENV_FILE:-/etc/lavasec/lavasec.env}:"
echo "    GENERIC_LOGGER_ENDPOINT=http://127.0.0.1:${PORT}/"
echo "  then re-run scripts/30-gateway.sh. The callback block is gated on that"
echo "  key, so it renders only once it is set — which is also why litellm can"
echo "  never see generic_api without the endpoint it would raise without."
