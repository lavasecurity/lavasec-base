#!/usr/bin/env bash
set -euo pipefail
# T3 Code (`t3 serve`) reachable from your tailnet devices only.
#
# Bind choice: the TAILNET interface (100.x), not loopback and never
# 0.0.0.0. Tailscale Serve would add HTTPS termination, but enabling it is
# a one-time tailnet-wide admin-console step — gating the box on that
# breaks plug-and-play, so it stays an optional upgrade (URL printed when
# unavailable). Exposure is identical either way: reachable by your
# tailnet devices, unreachable from the internet (cloud ingress stays
# SSH-only); WireGuard encrypts the transport.
#
# State: ~/.t3 (SQLite). Pairing is one-time and owner-interactive; the
# token appears in the service journal and is surfaced below. The unit
# exports LITELLM_MASTER_KEY so harnesses T3 Code spawns (opencode) reach
# providers only through the loopback gateway.

KEY_FILE="${HOME}/.config/lavasec/gateway-key"
if [ ! -s "${KEY_FILE}" ]; then
  echo "60-t3code: missing ${KEY_FILE} — run scripts/40-pi.sh first" >&2
  exit 1
fi
if [ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState' || echo unknown)" != "Running" ]; then
  echo "60-t3code: not on a tailnet — run scripts/50-tailscale.sh first" >&2
  exit 1
fi
ts_ip="$(tailscale ip -4 2>/dev/null | head -1)"
ts_name="$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
if [ -z "${ts_ip}" ]; then
  echo "60-t3code: no tailnet IPv4 — check tailscale status" >&2
  exit 1
fi

# t3 via npm with --ignore-scripts; node-pty ships no linux prebuilds, so
# build that ONE native module deliberately rather than enabling install
# scripts for every package in the tree.
if ! command -v t3 >/dev/null; then
  sudo npm install -g --ignore-scripts t3 >/dev/null
fi
npm_root="$(npm root -g)"
if [ ! -f "${npm_root}/t3/node_modules/node-pty/build/Release/pty.node" ]; then
  if ! command -v g++ >/dev/null; then
    sudo apt-get install -yq build-essential >/dev/null
  fi
  (cd "${npm_root}/t3/node_modules/node-pty" && sudo npx -y node-gyp rebuild >/dev/null 2>&1)
fi
echo "60-t3code: $(t3 --version 2>/dev/null | head -1)"

t3_bin="$(command -v t3)"
sudo tee /etc/systemd/system/t3code.service >/dev/null <<EOF
[Unit]
Description=T3 Code server (lavasec-base)
After=network-online.target litellm.service tailscaled.service
Wants=network-online.target

[Service]
User=${USER}
Environment=HOME=${HOME}
WorkingDirectory=${HOME}
ExecStart=/bin/bash -c 'export LITELLM_MASTER_KEY="\$(cat ${KEY_FILE})"; exec ${t3_bin} serve --mode web --host ${ts_ip} --port 3773 --no-browser'
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable t3code >/dev/null
sudo systemctl restart t3code

up=""
for _ in $(seq 1 40); do
  if ss -tln | grep -q "${ts_ip}:3773"; then
    up=1
    break
  fi
  sleep 1
done
if [ -z "${up}" ]; then
  echo "60-t3code: server did not come up — journalctl -u t3code -n 50" >&2
  exit 1
fi
if ss -tln | grep -qE '(0\.0\.0\.0|\[::\]):3773'; then
  echo "60-t3code: server exposed beyond the tailnet — refusing" >&2
  exit 1
fi
if ! curl -fsS --max-time 15 "http://${ts_ip}:3773/" -o /dev/null; then
  echo "60-t3code: tailnet HTTP check failed — journalctl -u t3code -n 50" >&2
  exit 1
fi

token="$(journalctl -u t3code -n 200 --no-pager 2>/dev/null \
  | grep -oE 'Token: [A-Z0-9]+' | tail -1 | awk '{print $2}')"
echo "60-t3code: OK (http://${ts_name}:3773 — tailnet devices only)"
if [ -n "${token}" ]; then
  echo "60-t3code: pair a device: http://${ts_name}:3773/pair#token=${token}"
else
  echo "60-t3code: pairing token: journalctl -u t3code | grep Token"
fi
if ! sudo tailscale serve status >/dev/null 2>&1 \
    || sudo tailscale serve status 2>&1 | grep -q "No serve config"; then
  enable_url="$(timeout 20 sudo tailscale serve --bg 3773 </dev/null 2>&1 \
    | grep -oE 'https://login\.tailscale\.com/f/serve[^ ]*' || true)"
  if [ -n "${enable_url}" ]; then
    echo "60-t3code: optional HTTPS upgrade — enable Serve for this tailnet at ${enable_url}, then re-run"
  fi
fi
