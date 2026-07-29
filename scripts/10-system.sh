#!/usr/bin/env bash
set -euo pipefail
# Base packages for the agent box. Ubuntu (Oracle free tier), aarch64 or x86_64.
# Idempotent: apt installs no-op when present; node only installed when < v20.

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -q
sudo apt-get install -yq git curl ca-certificates gnupg jq python3 python3-venv

# Node >= 20 for pi. NodeSource repo added manually (keyring + sources entry),
# not their curl|bash installer.
node_major=0
if command -v node >/dev/null; then
  node_major="$(node --version | sed 's/^v\([0-9]*\).*/\1/')"
fi
if [ "${node_major}" -lt 20 ]; then
  sudo install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    | sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
  sudo apt-get update -q
  sudo apt-get install -yq nodejs
fi

echo "10-system: git=$(git --version | awk '{print $3}') python=$(python3 --version | awk '{print $2}') node=$(node --version)"
