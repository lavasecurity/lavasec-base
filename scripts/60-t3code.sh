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
# Credential-change fingerprint: ExecStart reads the token files only at
# process start, so a rotated key would otherwise leave a byte-identical
# unit running with stale secrets. mtime+size (not content) — no
# secret-derived material lands in a world-readable unit file.
tok_fp="$(stat -c '%Y:%s' "${KEY_FILE}" "${HOME}/.config/lavasec/github-token" 2>/dev/null | sha256sum | awk '{print $1}')"

unit_tmp="$(mktemp)"
cat > "${unit_tmp}" <<EOF
[Unit]
# lavasec-base credential-fingerprint: ${tok_fp}
Description=T3 Code server (lavasec-base)
After=network-online.target litellm.service tailscaled.service
Wants=network-online.target

[Service]
User=${USER}
Environment=HOME=${HOME}
WorkingDirectory=${HOME}
ExecStart=/bin/bash -c 'export LITELLM_MASTER_KEY="\$(cat ${KEY_FILE})"; [ -r ${HOME}/.config/lavasec/github-token ] && export GH_TOKEN="\$(cat ${HOME}/.config/lavasec/github-token)"; exec ${t3_bin} serve --mode web --host ${ts_ip} --port 3773 --no-browser'
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
# restart ONLY when the unit changed or the service isn't healthy: each
# start mints a new one-time pairing token, so needless restarts would
# invalidate a link the owner is about to use
if ! sudo cmp -s "${unit_tmp}" /etc/systemd/system/t3code.service; then
  sudo install -m 644 "${unit_tmp}" /etc/systemd/system/t3code.service
  sudo systemctl daemon-reload
  sudo systemctl enable t3code >/dev/null
  sudo systemctl restart t3code
  echo "60-t3code: unit updated — service restarted (new pairing token)"
elif ! systemctl is-active --quiet t3code; then
  sudo systemctl enable t3code >/dev/null
  sudo systemctl start t3code
else
  echo "60-t3code: service already healthy — left running (pairing preserved)"
fi
rm -f "${unit_tmp}"

# wildcard bind is a security failure, not a warning: stop the unit before
# exiting so nothing keeps listening beyond the tailnet
refuse_if_wildcard() {
  if ss -tln | grep -qE '(0\.0\.0\.0|\[::\]):3773'; then
    sudo systemctl stop t3code
    echo "60-t3code: server bound beyond the tailnet — unit stopped, refusing" >&2
    exit 1
  fi
}
refuse_if_wildcard   # catches an already-running wildcard service

# readiness = HTTP answers, not just a listening socket (the socket opens
# before the app serves)
wait_ready() {
  for _ in $(seq 1 "$1"); do
    if curl -fsS --max-time 5 "http://${ts_ip}:3773/" -o /dev/null 2>/dev/null; then
      return 0
    fi
    refuse_if_wildcard
    sleep 2
  done
  return 1
}
if ! wait_ready 40; then
  # systemd-active but not serving (hung): restart once so repeated
  # bootstraps can recover instead of failing forever
  echo "60-t3code: no HTTP response — restarting the service once" >&2
  sudo systemctl restart t3code
  if ! wait_ready 30; then
    echo "60-t3code: server did not answer on the tailnet — journalctl -u t3code -n 50" >&2
    exit 1
  fi
fi
# authoritative: a slow wildcard start can answer HTTP before any earlier
# check saw its socket, so re-check AFTER readiness
refuse_if_wildcard

# no match must not kill the script (pipefail) — the fallback below is the
# intended path when the journal has rolled or the format changed
token="$(journalctl -u t3code --no-pager 2>/dev/null \
  | grep -oE 'Token: [A-Z0-9]+' | tail -1 | awk '{print $2}' || true)"
echo "60-t3code: OK (http://${ts_name}:3773 — tailnet devices only)"
if [ -n "${token}" ]; then
  echo "60-t3code: pair a device: http://${ts_name}:3773/pair#token=${token}"
else
  echo "60-t3code: pairing token: journalctl -u t3code | grep Token"
fi
# NEVER auto-enable Serve: `tailscale serve --bg` mutates persistent
# daemon state (tailnet-wide HTTPS on :443, surviving reboots). This
# script only reports the option; the owner opts in deliberately. The
# node-specific enable URL is only obtainable from a mutating attempt, so
# we point at the command instead.
# print unless Serve is already configured for our port — covers
# admin-disabled, unconfigured, and status-error cases alike
if ! sudo tailscale serve status 2>&1 | grep -q "3773"; then
  echo "60-t3code: optional HTTPS upgrade (not enabled by this script):"
  # target the BOUND address — a bare port would proxy to loopback, where
  # nothing listens
  echo "           sudo tailscale serve --bg http://${ts_ip}:3773   # prints the tailnet enable URL if needed"
fi
