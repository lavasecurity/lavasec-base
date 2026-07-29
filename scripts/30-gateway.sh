#!/usr/bin/env bash
set -euo pipefail
# LiteLLM gateway: venv under /opt/lavasec, config + systemd unit installed,
# service enabled, loopback-only bind verified, /v1/models smoke-tested.
# Requires /etc/lavasec/lavasec.env (root:root 600) — see env/example.env.
# Optional: LITELLM_VERSION=x.y.z to pin the litellm release.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE=/etc/lavasec/lavasec.env

# --- preflight: env file present, locked down, master key real ---
if [ ! -f "${ENV_FILE}" ]; then
  echo "missing ${ENV_FILE} — see README quickstart" >&2
  exit 1
fi
perms="$(stat -c '%a %U' "${ENV_FILE}")"
if [ "${perms}" != "600 root" ]; then
  echo "${ENV_FILE} must be root-owned mode 600 (got: ${perms})" >&2
  exit 1
fi
if ! sudo grep -q '^LITELLM_MASTER_KEY=sk-' "${ENV_FILE}" || sudo grep -q 'CHANGE-ME' "${ENV_FILE}"; then
  echo "LITELLM_MASTER_KEY in ${ENV_FILE} is not a real sk- value" >&2
  exit 1
fi

# --- service user + venv ---
if ! id -u lavasec >/dev/null 2>&1; then
  sudo useradd --system --user-group --home-dir /var/lib/lavasec --shell /usr/sbin/nologin lavasec
fi
sudo install -d -m 755 /opt/lavasec
if [ ! -x /opt/lavasec/venv/bin/pip ]; then
  sudo python3 -m venv /opt/lavasec/venv
fi
sudo /opt/lavasec/venv/bin/pip install -q --upgrade pip "litellm[proxy]${LITELLM_VERSION:+==${LITELLM_VERSION}}"

# --- config + unit ---
sudo install -m 644 "${REPO_DIR}/config/litellm.yaml" /opt/lavasec/litellm.yaml
sudo install -m 644 "${REPO_DIR}/systemd/litellm.service" /etc/systemd/system/litellm.service
sudo systemctl daemon-reload
sudo systemctl enable litellm >/dev/null
sudo systemctl restart litellm

# --- verify: up within 30s, loopback-only, models listed with master key ---
up=""
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1; then
    up=1
    break
  fi
  sleep 1
done
if [ -z "${up}" ]; then
  echo "gateway did not come up — check: journalctl -u litellm -n 50" >&2
  exit 1
fi

if ! ss -tln | grep -q '127\.0\.0\.1:4000'; then
  echo "gateway not bound to 127.0.0.1:4000" >&2
  exit 1
fi
if ss -tln | grep -qE '(0\.0\.0\.0|\[::\]):4000'; then
  echo "gateway exposed beyond loopback — refusing" >&2
  exit 1
fi

models="$(sudo sh -c ". ${ENV_FILE} && curl -fsS -H \"Authorization: Bearer \${LITELLM_MASTER_KEY}\" http://127.0.0.1:4000/v1/models")"
model_count="$(printf '%s' "${models}" | jq '.data | length')"
if [ "${model_count}" -eq 0 ]; then
  echo "gateway is up but lists zero models — check /opt/lavasec/litellm.yaml" >&2
  exit 1
fi
printf '%s' "${models}" | jq -r '.data[0:5][].id' | sed 's/^/  model: /'
echo "30-gateway: OK (${model_count} models, $(/opt/lavasec/venv/bin/litellm --version 2>/dev/null || true))"
