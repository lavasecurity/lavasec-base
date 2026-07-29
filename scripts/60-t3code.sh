#!/usr/bin/env bash
set -euo pipefail
# C3: install T3 Code (npm, --ignore-scripts) and run `t3 serve` (:3773)
# as a systemd unit — loopback bind + `tailscale serve` per its
# remote-access doc (hosted pairing is optional and never proxies
# traffic). The one-time owner pairing token is owner-interactive:
# loud instructions until paired. Done when the T3 Code web app answers
# over the tailnet and the public IP still exposes only 22.
echo "SKIP(C3): 60-t3code.sh not implemented yet"
exit 0
