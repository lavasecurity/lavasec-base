#!/usr/bin/env bash
set -euo pipefail
# OpenCode's own web UI (`opencode web`) on the tailnet — a second control
# surface beside T3 Code, driving the same gateway-wired opencode harness
# (so both see the same catalog and the same provider credentials never
# leave the gateway). Same posture as 60-t3code.sh: bound to the TAILNET
# interface, never loopback-only, never 0.0.0.0; --mdns deliberately
# unused because it defaults the bind to 0.0.0.0.

PORT="${OPENCODE_WEB_PORT:-4096}"
KEY_FILE="${HOME}/.config/lavasec/gateway-key"

if ! command -v opencode >/dev/null; then
  echo "65-opencode-web: opencode not installed — run scripts/55-opencode.sh first" >&2
  exit 1
fi
if [ ! -s "${KEY_FILE}" ]; then
  echo "65-opencode-web: missing ${KEY_FILE} — run scripts/40-pi.sh first" >&2
  exit 1
fi
if [ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState' || echo unknown)" != "Running" ]; then
  echo "65-opencode-web: not on a tailnet — run scripts/50-tailscale.sh first" >&2
  exit 1
fi
ts_ip="$(tailscale ip -4 2>/dev/null | head -1)"
ts_name="$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
if [ -z "${ts_ip}" ]; then
  echo "65-opencode-web: no tailnet IPv4 — check tailscale status" >&2
  exit 1
fi

oc_bin="$(command -v opencode)"
unit_tmp="$(mktemp)"
cat > "${unit_tmp}" <<EOF
[Unit]
Description=OpenCode web UI (lavasec-base)
After=network-online.target litellm.service tailscaled.service
Wants=network-online.target

[Service]
User=${USER}
Environment=HOME=${HOME}
WorkingDirectory=${HOME}
ExecStart=/bin/bash -c 'export LITELLM_MASTER_KEY="\$(cat ${KEY_FILE})"; [ -r ${HOME}/.config/lavasec/github-token ] && export GH_TOKEN="\$(cat ${HOME}/.config/lavasec/github-token)"; exec ${oc_bin} web --hostname ${ts_ip} --port ${PORT}'
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

if ! sudo cmp -s "${unit_tmp}" /etc/systemd/system/opencode-web.service; then
  sudo install -m 644 "${unit_tmp}" /etc/systemd/system/opencode-web.service
  sudo systemctl daemon-reload
  sudo systemctl enable opencode-web >/dev/null
  sudo systemctl restart opencode-web
else
  if ! systemctl is-active --quiet opencode-web; then
    sudo systemctl enable opencode-web >/dev/null
    sudo systemctl start opencode-web
  fi
fi
rm -f "${unit_tmp}"

refuse_if_wildcard() {
  if ss -tln | grep -qE "(0\.0\.0\.0|\[::\]):${PORT}"; then
    sudo systemctl stop opencode-web
    echo "65-opencode-web: bound beyond the tailnet — unit stopped, refusing" >&2
    exit 1
  fi
}
refuse_if_wildcard

wait_ready() {
  for _ in $(seq 1 "$1"); do
    if curl -fsS --max-time 5 "http://${ts_ip}:${PORT}/" -o /dev/null 2>/dev/null; then
      return 0
    fi
    refuse_if_wildcard
    sleep 2
  done
  return 1
}
if ! wait_ready 30; then
  echo "65-opencode-web: no HTTP response — restarting once" >&2
  sudo systemctl restart opencode-web
  if ! wait_ready 30; then
    echo "65-opencode-web: did not answer on the tailnet — journalctl -u opencode-web -n 50" >&2
    exit 1
  fi
fi
refuse_if_wildcard   # authoritative: a slow wildcard start can answer first

echo "65-opencode-web: OK (http://${ts_name}:${PORT} — tailnet devices only)"
