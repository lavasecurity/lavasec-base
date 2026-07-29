#!/usr/bin/env bash
set -euo pipefail
# Tailscale: overlay access to this box with ZERO new cloud ingress —
# tailscaled connects outbound (WireGuard + NAT traversal), so the cloud
# security list stays SSH-only. Joining the tailnet is a one-time
# owner-interactive step; until it happens this fails loudly with
# instructions. No auth keys are stored anywhere.

# install via manual keyring + apt repo (no curl|bash), idempotent
if ! command -v tailscale >/dev/null; then
  # shellcheck disable=SC1091
  . /etc/os-release
  sudo install -d -m 755 /etc/apt/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.noarmor.gpg" \
    | sudo tee /etc/apt/keyrings/tailscale-archive-keyring.gpg >/dev/null
  echo "deb [signed-by=/etc/apt/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${VERSION_CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  sudo apt-get update -q
  sudo apt-get install -yq tailscale
fi
sudo systemctl enable --now tailscaled >/dev/null

state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState' || echo unknown)"
if [ "${state}" != "Running" ]; then
  {
    echo "50-tailscale: box is not on a tailnet (state: ${state}). One-time setup:"
    echo "  1. Create/log into a Tailscale account; install it on the devices"
    echo "     that should reach this box (they become the ONLY such devices)"
    echo "  2. On this box:  sudo tailscale up"
    echo "  3. Approve the printed URL in your browser, then re-run bootstrap."
  } >&2
  exit 1
fi

tsname="$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
echo "50-tailscale: OK (on tailnet as ${tsname}; cloud ingress unchanged)"
