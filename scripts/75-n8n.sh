#!/usr/bin/env bash
set -euo pipefail
# 75-n8n.sh — n8n workflow automation, tailnet-bound, SQLite-backed.
#
# n8n replaces the systemd timers as the VISUAL trigger + lineage layer for
# agent drains. The agent contracts, dispatch script, gateway, and opencode
# runtime all stay as-is — n8n just fires agent-dispatch.sh on a cadence and
# shows the run history in a dashboard. It is the "Airflow but lighter" piece:
# no Airflow scheduler, no Postgres, no Docker — a single Node.js process with
# a SQLite database file, same posture as t3code and opencode-web.
#
# Architecture:
#   n8n (tailnet :5678) → Execute Workflow node → agent-dispatch.sh <agent> <flow>
#
# Bind choice: the TAILNET interface (100.x), not loopback and never 0.0.0.0.
# Same posture as 60-t3code.sh: reachable by your tailnet devices, unreachable
# from the internet (cloud ingress stays SSH-only); WireGuard encrypts.
#
# State: ~/.n8n (SQLite + config). No Docker volume, no Postgres.
#
# The unit exports LITELLM_MASTER_KEY so n8n's HTTP Request nodes (if used for
# direct gateway calls) and the spawned agent-dispatch.sh both reach providers
# only through the loopback gateway.

KEY_FILE="${HOME}/.config/lavasec/gateway-key"
if [ ! -s "${KEY_FILE}" ]; then
  echo "75-n8n: missing ${KEY_FILE} — run scripts/40-pi.sh first" >&2
  exit 1
fi
if [ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState' || echo unknown)" != "Running" ]; then
  echo "75-n8n: not on a tailnet — run scripts/50-tailscale.sh first" >&2
  exit 1
fi
ts_ip="$(tailscale ip -4 2>/dev/null | head -1)"
ts_name="$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
if [ -z "${ts_ip}" ]; then
  echo "75-n8n: no tailnet IPv4 — check tailscale status" >&2
  exit 1
fi

# npm install with --ignore-scripts (same discipline as 55-opencode.sh and
# 60-t3code.sh): no transitive package runs code at install time. n8n is pure
# JavaScript/TypeScript with no native modules on linux-arm64.
N8N_PORT="${N8N_PORT:-5678}"
if ! command -v n8n >/dev/null 2>&1; then
  sudo npm install -g --ignore-scripts n8n >/dev/null
fi
echo "75-n8n: $(n8n --version 2>/dev/null | head -1)"

n8n_bin="$(command -v n8n)"

# n8n reads config from env vars prefixed N8N_ (or DB_ for db settings).
# SQLite is the default — no DB_TYPE env var needed. The data directory is
# ~/.n8n (SQLite database.sqlite + config + encryption key).
#
# N8N_ENCRYPTION_KEY: n8n encrypts stored credentials with this key. If unset,
# n8n generates one on first run and stores it in ~/.n8n/config. That's fine
# for a single-instance self-hosted deploy — losing the key loses stored
# credentials, but the agent-dispatch.sh approach passes creds via env, not
# n8n's credential store, so the blast radius of a lost key is low.
#
# N8N_BASIC_AUTH_ACTIVE: n8n's built-in basic auth, same posture as
# opencode-web (65-opencode-web.sh). The tailnet is the primary defense;
# basic auth is defence-in-depth for the HTTP surface.
N8N_PASSWORD="${N8N_PASSWORD:-$(openssl rand -hex 12)}"

# Credential-change fingerprint: same technique as 60-t3code.sh — mtime+size
# of the gateway key file, so a rotated key triggers a unit restart without
# leaking the key itself into a world-readable unit file.
tok_fp="$( { stat -c '%Y:%s' "${KEY_FILE}" 2>/dev/null || true; } | sha256sum | awk '{print $1}')"

unit_tmp="$(mktemp)"
cat > "${unit_tmp}" <<EOF
[Unit]
# lavasec-base credential-fingerprint: ${tok_fp}
Description=n8n workflow automation (lavasec-base)
After=network-online.target litellm.service tailscaled.service
Wants=network-online.target

[Service]
User=${USER}
Environment=HOME=${HOME}
Environment=N8N_HOST=${ts_ip}
Environment=N8N_PORT=${N8N_PORT}
Environment=N8N_PROTOCOL=http
Environment=N8N_EDITOR_BASE_URL=http://${ts_name}:${N8N_PORT}
Environment=N8N_BASIC_AUTH_ACTIVE=true
Environment=N8N_BASIC_AUTH_USER=admin
Environment=N8N_BASIC_AUTH_PASSWORD=${N8N_PASSWORD}
Environment=WEBHOOK_URL=http://${ts_name}:${N8N_PORT}
Environment=EXECUTIONS_MODE=regular
Environment=N8N_METRICS=true
Environment=GEN_CONFIG_VARS_OVERRIDE_PATH=${HOME}/.n8n/config
WorkingDirectory=${HOME}
ExecStart=/bin/bash -c 'export LITELLM_MASTER_KEY="\$(cat ${KEY_FILE})"; exec ${n8n_bin} start --host ${ts_ip} --port ${N8N_PORT}'
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# restart only when the unit changed or the service isn't healthy — same
# reasoning as t3code: a running n8n has in-memory workflow state, so
# needless restarts interrupt active executions.
if ! sudo cmp -s "${unit_tmp}" /etc/systemd/system/n8n.service; then
  sudo install -m 644 "${unit_tmp}" /etc/systemd/system/n8n.service
  sudo systemctl daemon-reload
  sudo systemctl enable n8n >/dev/null
  sudo systemctl restart n8n
  echo "75-n8n: unit updated — service restarted"
elif ! systemctl is-active --quiet n8n; then
  sudo systemctl enable n8n >/dev/null
  sudo systemctl start n8n
  echo "75-n8n: service started"
else
  echo "75-n8n: service already healthy — left running"
fi
rm -f "${unit_tmp}"

# a unit can be ACTIVE but DISABLED (would vanish on reboot); repair
# enablement without restarting, so workflow state survives
if ! systemctl is-enabled --quiet n8n 2>/dev/null; then
  sudo systemctl enable n8n >/dev/null
fi

# wildcard bind is a security failure, not a warning: stop the unit before
# exiting so nothing keeps listening beyond the tailnet
refuse_if_wildcard() {
  if ss -tln | grep -qE "(0\.0\.0\.0|\[::\]):${N8N_PORT}"; then
    sudo systemctl stop n8n
    echo "75-n8n: server bound beyond the tailnet — unit stopped, refusing" >&2
    exit 1
  fi
}
refuse_if_wildcard

# readiness = HTTP answers, not just a listening socket (the socket opens
# before the app serves — n8n's first boot can take 10-20s as it initializes
# the SQLite database and migrates schemas)
wait_ready() {
  for _ in $(seq 1 "$1"); do
    if curl -fsS --max-time 5 "http://${ts_ip}:${N8N_PORT}/" -o /dev/null 2>/dev/null; then
      return 0
    fi
    refuse_if_wildcard
    sleep 2
  done
  return 1
}
if ! wait_ready 60; then
  echo "75-n8n: no HTTP response — restarting the service once" >&2
  sudo systemctl restart n8n
  if ! wait_ready 30; then
    echo "75-n8n: server did not answer on the tailnet — journalctl -u n8n -n 50" >&2
    exit 1
  fi
fi
refuse_if_wildcard

echo "75-n8n: OK (http://${ts_name}:${N8N_PORT} — tailnet devices only)"
echo "75-n8n: basic auth: admin / ${N8N_PASSWORD}"
echo "75-n8n: basic auth password is in the service environment (journalctl -u n8n)"
echo "75-n8n: to make it persistent across reboots, set N8N_PASSWORD in ~/.n8n/config"
echo ""
echo "75-n8n: agent trigger workflows — import these from the n8n editor:"
echo "  1. Schedule Trigger (every 5 min) → Execute Command: agent-dispatch.sh pr-reviewer B"
echo "  2. Schedule Trigger (daily 06:00) → Execute Command: agent-dispatch.sh knowledge-drain B"
echo "  3. Schedule Trigger (daily 07:00) → Execute Command: agent-dispatch.sh knowledge-drain C"
echo "  4. Schedule Trigger (daily 07:05) → Execute Command: agent-dispatch.sh pr-reviewer C"
echo ""
echo "75-n8n: the systemd timers in lavasec-infra/scripts/70-agent-setup.sh"
echo "  remain as the fallback if n8n is down. Disable them with:"
echo "  sudo systemctl stop lavasec-agent-*.timer"
echo "  when you've imported the workflows into n8n."

# optional HTTPS upgrade via Tailscale Serve — same as t3code: never auto-enable
if ! sudo tailscale serve status 2>&1 | grep -q "${N8N_PORT}"; then
  echo "75-n8n: optional HTTPS upgrade (not enabled by this script):"
  echo "         sudo tailscale serve --bg http://${ts_ip}:${N8N_PORT}"
fi
