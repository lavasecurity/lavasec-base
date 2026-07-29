#!/usr/bin/env bash
set -euo pipefail
# C3: build lavasec-console (T3 app) from ~/src/lavasec-console at a pinned
# tag, install its systemd unit (loopback :3000), expose it on the tailnet
# via `tailscale serve` (HTTPS terminates there; app never leaves loopback),
# verify through the tailnet hostname. Obligation: SKIP with a notice when
# the console repo is not synced (public template users without access).
echo "SKIP(C3): 60-console.sh not implemented yet"
exit 0
