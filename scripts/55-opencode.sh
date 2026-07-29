#!/usr/bin/env bash
set -euo pipefail
# OpenCode harness wired to the loopback gateway — the T3 Code-supported
# agent whose provider config accepts a custom OpenAI-compatible endpoint.
# Provider credentials stay in the gateway; opencode's config carries only
# an {env:LITELLM_MASTER_KEY} reference, resolved at runtime from the
# gateway-key file (never a literal secret on disk here).
#
# Model list + round-trip model are derived from the provider keys this
# box actually has (same ladder as 40-pi.sh), so a box keyed for any one
# provider works.

ENV_FILE=/etc/lavasec/lavasec.env
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

# which providers does this box have keys for? (echo names only, never values)
configured="$(sudo sh -c ". ${ENV_FILE} && \
  { [ -n \"\${DEEPSEEK_API_KEY:-}\" ]   && echo deepseek; \
    [ -n \"\${OPENROUTER_API_KEY:-}\" ] && echo openrouter; \
    [ -n \"\${NEURALWATT_API_KEY:-}\" ] && echo neuralwatt; \
    [ -n \"\${ANTHROPIC_API_KEY:-}\" ]  && echo anthropic; \
    [ -n \"\${OPENAI_API_KEY:-}\" ]     && echo openai; \
    [ -n \"\${OPENCODE_API_KEY:-}\" ]   && echo opencode; :; }")"
if [ -z "${configured}" ]; then
  echo "55-opencode: no provider key in ${ENV_FILE} — add one and re-run" >&2
  exit 1
fi

models_json='{}'
add_model() {  # id, display, context, output
  models_json="$(printf '%s' "${models_json}" | jq --arg id "$1" --arg n "$2" \
    --argjson c "$3" --argjson o "$4" \
    '. + {($id): {name: $n, limit: {context: $c, output: $o}}}')"
}
check_model=""
for provider in ${configured}; do
  case "${provider}" in
    deepseek)
      add_model "deepseek/deepseek-chat" "DeepSeek Chat (gateway)" 131072 8192
      add_model "deepseek/deepseek-reasoner" "DeepSeek Reasoner (gateway)" 131072 65536
      : "${check_model:=deepseek/deepseek-chat}" ;;
    openrouter)
      add_model "openrouter/openai/gpt-4o-mini" "GPT-4o mini via OpenRouter (gateway)" 128000 16384
      add_model "openrouter/moonshotai/kimi-k3" "Kimi K3 via OpenRouter (gateway)" 1048576 32768
      : "${check_model:=openrouter/openai/gpt-4o-mini}" ;;
    neuralwatt)
      add_model "neuralwatt/qwen3.6-35b" "Qwen 3.6 35B via Neuralwatt (gateway)" 131072 32768
      : "${check_model:=neuralwatt/qwen3.6-35b}" ;;
    anthropic)
      add_model "anthropic/claude-haiku-4-5" "Claude Haiku 4.5 (gateway)" 200000 8192
      : "${check_model:=anthropic/claude-haiku-4-5}" ;;
    openai)
      add_model "openai/gpt-4o-mini" "GPT-4o mini (gateway)" 128000 16384
      : "${check_model:=openai/gpt-4o-mini}" ;;
    opencode)
      add_model "opencode/gpt-5.5" "GPT-5.5 via OpenCode Zen (gateway)" 272000 32768
      : "${check_model:=opencode/gpt-5.5}" ;;
  esac
done
CHECK_MODEL="${OC_CHECK_MODEL:-${check_model}}"

# config OWNED by this script (box-staged; per-project opencode.json can
# still override locally)
mkdir -p "${OC_CONFIG_DIR}"
jq -n --argjson models "${models_json}" '{
  "$schema": "https://opencode.ai/config.json",
  provider: {
    "lava-gateway": {
      npm: "@ai-sdk/openai-compatible",
      name: "Lava Gateway",
      options: { baseURL: "http://127.0.0.1:4000/v1", apiKey: "{env:LITELLM_MASTER_KEY}" },
      models: $models
    }
  }
}' > "${OC_CONFIG_DIR}/opencode.json"

# round-trip: a real completion opencode → gateway → provider.
# success = exit 0 AND sentinel (the prompt contains the sentinel, so
# output alone could false-pass on an echoed error). One retry: the very
# first run after a config change can hang on opencode's server spawn
# (observed once — 120s of silence, then killed), and heals immediately.
oc_roundtrip() {
  LITELLM_MASTER_KEY="$(cat "${KEY_FILE}")" timeout 120 opencode run \
    --model "lava-gateway/${CHECK_MODEL}" \
    "Reply with exactly: OC-GATEWAY-OK" 2>&1 < /dev/null
}
ok=""
for attempt in 1 2; do
  if reply=$(oc_roundtrip) && printf '%s' "${reply}" | grep -q "OC-GATEWAY-OK"; then
    ok=1
    break
  fi
  if [ "${attempt}" = 1 ]; then
    echo "55-opencode: round-trip attempt 1 failed — retrying once" >&2
    sleep 5
  fi
done
if [ -z "${ok}" ]; then
  echo "55-opencode: round-trip via ${CHECK_MODEL} FAILED after retry:" >&2
  printf '%s\n' "${reply}" | tail -5 >&2
  exit 1
fi
echo "55-opencode: OK (${CHECK_MODEL} round-trip via gateway verified)"
