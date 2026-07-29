#!/usr/bin/env bash
set -euo pipefail
# C2: install the OpenCode harness — the T3 Code-supported agent whose
# provider config accepts a custom OpenAI-compatible endpoint — and point
# it at the loopback gateway (key from ~/.config/lavasec/gateway-key;
# provider credentials never leave the gateway). Done when an opencode
# one-shot round-trips through the gateway. Loud-fail with instructions
# on anything owner-interactive.
echo "SKIP(C2): 55-opencode.sh not implemented yet"
exit 0
