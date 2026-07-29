#!/usr/bin/env bash
set -euo pipefail
# C3 contract (owner, 2026-07-29): converge the lavasec-console T3 app at
# a target path — CONSOLE_DIR (default ~/lavasec-console), owned by THIS
# script exclusively (the console stays out of repos.txt so the sync loop
# never fights this checkout):
#   1. path absent  -> clone (credential helper/PAT), npm ci + build,
#                      install systemd unit (loopback :3000),
#                      `tailscale serve` for tailnet HTTPS
#   2. path present -> git pull --ff-only, rebuild, restart
#   3. clone impossible (no repo access) -> SKIP with notice, bootstrap
#      stays green (public template users)
# App never leaves loopback; runtime state lives in
# ~/.local/share/lavasec-console/ — never in any git repo.
echo "SKIP(C3): 60-console.sh not implemented yet (waiting on C2: lavasec-console repo)"
exit 0
