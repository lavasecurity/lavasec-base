#!/usr/bin/env bash
set -euo pipefail
# Local LiteLLM callback sink. It appends completions to the scorer's spool and
# starts the existing langfuse-eval DAG. Off unless GENERIC_LOGGER_ENDPOINT is
# present in /etc/lavasec/lavasec.env.

if [ "${EUID}" -eq 0 ]; then
  echo "35-eval-receiver: run as the normal service user, not root" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE=/etc/lavasec/lavasec.env
SPOOL_DIR="${LAVASEC_EVAL_SPOOL_DIR:-/var/lib/lavasec-eval}"
SPOOL="${SPOOL_DIR}/eval-spool.jsonl"
PORT="${LAVASEC_EVAL_RECEIVER_PORT:-4010}"
UNIT=/etc/systemd/system/lavasec-eval-receiver.service
SERVICE_USER="$(id -un)"
SERVICE_GROUP="$(id -gn)"
SERVICE_HOME="$(getent passwd "${SERVICE_USER}" | cut -d: -f6)"

if ! sudo sh -c ". ${ENV_FILE} && [ -n \"\${GENERIC_LOGGER_ENDPOINT:-}\" ]"; then
  echo "35-eval-receiver: GENERIC_LOGGER_ENDPOINT unset — receiver disabled"
  sudo systemctl disable --now lavasec-eval-receiver >/dev/null 2>&1 || true
  exit 0
fi

# Keep prompt-bearing state outside LiteLLM's StateDirectory. systemd resets
# /var/lib/lavasec ownership whenever the gateway starts; an independent path
# leaves the receiver and Dagu queue untouched by gateway restarts.
sudo install -d -m 750 -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" "${SPOOL_DIR}"
if ! sudo test -e "${SPOOL}"; then
  sudo install -m 600 -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" /dev/null "${SPOOL}"
fi
sudo chown "${SERVICE_USER}:${SERVICE_GROUP}" "${SPOOL}"
sudo chmod 600 "${SPOOL}"
if ! sudo test -e "${SPOOL}.lock"; then
  sudo install -m 600 -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" /dev/null "${SPOOL}.lock"
fi
sudo chown "${SERVICE_USER}:${SERVICE_GROUP}" "${SPOOL}.lock"
sudo chmod 600 "${SPOOL}.lock"
sudo install -m 644 -o root -g root \
  "${REPO_DIR}/scripts/eval-receiver.py" /etc/lavasec/eval-receiver.py

sudo tee "${UNIT}" >/dev/null <<UNITFILE
[Unit]
Description=LavaSec evaluation callback receiver
After=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
Environment=HOME=${SERVICE_HOME}
EnvironmentFile=-/etc/lavasec/agent.env
Environment=LAVASEC_EVAL_SPOOL=${SPOOL}
Environment=LAVASEC_EVAL_RECEIVER_PORT=${PORT}
Environment=LAVASEC_EVAL_RECEIVER_BIND=127.0.0.1
ExecStart=/usr/bin/python3 /etc/lavasec/eval-receiver.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${SPOOL_DIR} -${SERVICE_HOME}/.local/share/dagu

[Install]
WantedBy=multi-user.target
UNITFILE

sudo systemctl daemon-reload
sudo systemctl enable lavasec-eval-receiver >/dev/null
sudo systemctl restart lavasec-eval-receiver

for _ in $(seq 1 15); do
  if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    echo "35-eval-receiver: OK (127.0.0.1:${PORT})"
    exit 0
  fi
  sleep 1
done

echo "35-eval-receiver: receiver did not start" >&2
sudo journalctl -u lavasec-eval-receiver -n 30 --no-pager >&2 || true
exit 1
