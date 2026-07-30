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

# Resolve the upgradeable, user-writable opencode from 55-opencode.sh's
# prefix (~/.local/bin) regardless of how this slice is invoked — a
# non-interactive shell's PATH stops at /usr/bin, where only the stale
# root-owned copy (if any) lives.
export PATH="${HOME}/.local/bin:${PATH}"

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

# The tailnet is a trust boundary, not an authenticator: any peer device
# (or a compromised one) that reaches this port would otherwise drive the
# agent with this user's filesystem, gateway key and GH_TOKEN. OpenCode
# supports HTTP basic auth via OPENCODE_SERVER_PASSWORD — generate one
# once, keep it owner-only beside the other secrets.
WEB_PW_FILE="${HOME}/.config/lavasec/opencode-web-password"
if [ ! -s "${WEB_PW_FILE}" ]; then
  mkdir -p "$(dirname "${WEB_PW_FILE}")"
  (umask 077 && openssl rand -hex 24 > "${WEB_PW_FILE}")
fi
chmod 600 "${WEB_PW_FILE}"
# Credential-change fingerprint: ExecStart reads the token files only at
# process start, so a rotated key would otherwise leave a byte-identical
# unit running with stale secrets. mtime+size (not content) — no
# secret-derived material lands in a world-readable unit file.
# `|| true` inside the group: the GitHub token is optional (setup.sh lets
# it be skipped), and a failing stat under pipefail would kill the script
tok_fp="$( { stat -c '%Y:%s' "${KEY_FILE}" "${WEB_PW_FILE}" "${HOME}/.config/lavasec/github-token" 2>/dev/null || true; } | sha256sum | awk '{print $1}')"

unit_tmp="$(mktemp)"
cat > "${unit_tmp}" <<EOF
[Unit]
# lavasec-base credential-fingerprint: ${tok_fp}
Description=OpenCode web UI (lavasec-base)
After=network-online.target litellm.service tailscaled.service
Wants=network-online.target

[Service]
User=${USER}
Environment=HOME=${HOME}
Environment=PATH=${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=${HOME}
ExecStart=/bin/bash -c 'export LITELLM_MASTER_KEY="\$(cat ${KEY_FILE})"; export OPENCODE_SERVER_USERNAME=lavasec; export OPENCODE_SERVER_PASSWORD="\$(cat ${WEB_PW_FILE})"; [ -r ${HOME}/.config/lavasec/github-token ] && export GH_TOKEN="\$(cat ${HOME}/.config/lavasec/github-token)"; exec ${oc_bin} web --hostname ${ts_ip} --port ${PORT}'
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

# a unit can be ACTIVE but DISABLED (would vanish on reboot); repair
# enablement without restarting, so pairing survives
if ! systemctl is-enabled --quiet opencode-web 2>/dev/null; then
  sudo systemctl enable opencode-web >/dev/null
fi

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
    # 401 proves it is serving AND that auth is enforced; -o /dev/null
    # with --max-time keeps this cheap
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ts_ip}:${PORT}/" 2>/dev/null || true)"
    # 401/403 = auth enforced; 3xx = redirect to a login page, also fine
    case "${code}" in
      401|403|30[0-9]) return 0 ;;
    esac
    if [ "${code#2}" != "${code}" ] && [ -n "${code}" ]; then
      sudo systemctl stop opencode-web
      echo "65-opencode-web: server answered WITHOUT auth — unit stopped, refusing" >&2
      exit 1
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

echo "65-opencode-web: OK (http://${ts_name}:${PORT} — tailnet devices only, basic auth enforced)"
echo "65-opencode-web: sign in as 'lavasec'; password: cat ${WEB_PW_FILE}"

# Copy buttons need HTTPS (see 60-t3code.sh for the full rationale): the web
# UI's navigator.clipboard.writeText() is gated behind a secure context, and
# plain HTTP on a tailnet IP is not one, so copy silently fails. HTTPS is the
# fix, not optional hardening. Enabling Serve here is the owner's deliberate
# call (it mutates persistent daemon state, tailnet-wide, surviving reboots),
# so this script only prints the command. The opencode-web port has no built
# in :443 (t3code claims it), so use a distinct HTTPS port.
# PREREQ: --https provisions a cert for the *.ts.net name, needing HTTPS cert
# support + MagicDNS in the admin console (one-time, tailnet-wide).
# NO-MAGIDNS FALLBACK: ssh -L ${PORT}:${ts_ip}:${PORT} -N ${USER}@${ts_ip},
# then open http://localhost:${PORT} (localhost IS a secure context over HTTP).
if ! sudo tailscale serve status 2>&1 | grep -q "${PORT}"; then
  echo "65-opencode-web: copy buttons need HTTPS (plain HTTP on a tailnet IP is not a secure context):"
  echo "                  sudo tailscale serve --bg --https=8443 http://${ts_ip}:${PORT}   # needs HTTPS cert support + MagicDNS (admin console)"
  echo "                  no-DNS fallback: ssh -L ${PORT}:${ts_ip}:${PORT} -N ${USER}@${ts_ip}, then http://localhost:${PORT}"
fi
