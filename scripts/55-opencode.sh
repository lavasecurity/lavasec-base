#!/usr/bin/env bash
set -euo pipefail
# OpenCode harness wired to the loopback gateway — the T3 Code-supported
# agent whose provider config accepts a custom OpenAI-compatible endpoint.
# Provider credentials stay in the gateway; opencode's config carries only
# an {env:LITELLM_MASTER_KEY} reference, resolved at runtime from the
# gateway-key file (never a literal secret on disk here).

KEY_FILE="${HOME}/.config/lavasec/gateway-key"
OC_CONFIG_DIR="${HOME}/.config/opencode"

if [ ! -s "${KEY_FILE}" ]; then
  echo "55-opencode: missing ${KEY_FILE} — run scripts/40-pi.sh first" >&2
  exit 1
fi

# npm package is opencode-ai; it NEEDS its own postinstall (fetches the
# platform binary). Keep --ignore-scripts so no transitive package runs
# code, then run THIS package's postinstall deliberately.
if ! opencode --version >/dev/null 2>&1; then
  sudo npm install -g --ignore-scripts opencode-ai >/dev/null
  (cd "$(npm root -g)/opencode-ai" && sudo node postinstall.mjs >/dev/null)
fi
echo "55-opencode: opencode $(opencode --version 2>/dev/null | head -1)"

# config OWNED by this script (box-staged; per-project opencode.json can
# still override locally). Models mirror the gateway's curated catalog.
mkdir -p "${OC_CONFIG_DIR}"
cat > "${OC_CONFIG_DIR}/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "lava-gateway": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Lava Gateway",
      "options": {
        "baseURL": "http://127.0.0.1:4000/v1",
        "apiKey": "{env:LITELLM_MASTER_KEY}"
      },
      "models": {
        "deepseek/deepseek-chat": { "name": "DeepSeek Chat (gateway)", "limit": { "context": 131072, "output": 8192 } },
        "deepseek/deepseek-reasoner": { "name": "DeepSeek Reasoner (gateway)", "limit": { "context": 131072, "output": 65536 } },
        "openrouter/moonshotai/kimi-k3": { "name": "Kimi K3 via OpenRouter (gateway)", "limit": { "context": 1048576, "output": 32768 } },
        "neuralwatt/qwen3.6-35b": { "name": "Qwen 3.6 35B (gateway)", "limit": { "context": 131072, "output": 32768 } }
      }
    }
  }
}
EOF

# round-trip: a real completion opencode → gateway → provider.
# success = exit 0 AND sentinel (the prompt contains the sentinel, so
# output alone could false-pass on an echoed error)
if reply=$(LITELLM_MASTER_KEY="$(cat "${KEY_FILE}")" timeout 120 opencode run \
      --model "lava-gateway/deepseek/deepseek-chat" "Reply with exactly: OC-GATEWAY-OK" 2>&1) \
    && printf '%s' "${reply}" | grep -q "OC-GATEWAY-OK"; then
  echo "55-opencode: OK (round-trip via gateway verified)"
else
  echo "55-opencode: round-trip FAILED:" >&2
  printf '%s\n' "${reply}" | tail -5 >&2
  exit 1
fi
