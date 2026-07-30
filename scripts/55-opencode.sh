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
  # sudo -H, not bare sudo: Ubuntu's sudo PRESERVES HOME, so this postinstall
  # ran as root against THIS user's home and left a root-owned
  # ~/.config/opencode -- which then failed the config write below on every
  # fresh box (a long-lived box only escapes it if the dir predates the
  # postinstall). -H sends root's writes to /root.
  sudo -H npm install -g --ignore-scripts opencode-ai >/dev/null
  (cd "$(npm root -g)/opencode-ai" && sudo -H node postinstall.mjs >/dev/null)
fi
echo "55-opencode: opencode $(opencode --version 2>/dev/null | head -1)"

# which providers does this box have keys for? (echo names only, never values)
configured="$(sudo sh -c ". ${ENV_FILE} && \
  { [ -n \"\${DEEPSEEK_API_KEY:-}\" ]   && echo deepseek; \
    [ -n \"\${OPENROUTER_API_KEY:-}\" ] && echo openrouter; \
    [ -n \"\${NEURALWATT_API_KEY:-}\" ] && echo neuralwatt; \
    [ -n \"\${ANTHROPIC_API_KEY:-}\" ]  && echo anthropic; \
    [ -n \"\${OPENAI_API_KEY:-}\" ]     && echo openai; \
    [ -n \"\${OPENCODE_API_KEY:-}\" ]   && echo opencode; \
    [ -n \"\${OLLAMA_API_KEY:-}\" ]     && echo ollama; :; }")"
if [ -z "${configured}" ]; then
  echo "55-opencode: no provider key in ${ENV_FILE} — add one and re-run" >&2
  exit 1
fi

# Model list comes from the gateway's own catalog (/model/info) — the same
# source pi's extension uses — so opencode sees every routable model, with
# real context/output limits, and new ones appear without editing this
# script. Falls back to one model per configured provider if the gateway
# is unreachable.
# Fetch from the gateway without putting the key in any argv: curl -K
# reads the auth header from a 0600 config file (/proc/<pid>/cmdline is
# world-readable, so -H "Authorization: ..." would expose it).
gw_get() {  # $1 = path
  local cfg rc
  cfg="$(mktemp)"
  chmod 600 "${cfg}"
  cat > "${cfg}" <<EOF
header = "Authorization: Bearer $(cat "${KEY_FILE}")"
EOF
  curl -fsS --max-time 15 -K "${cfg}" "http://127.0.0.1:4000$1"
  rc=$?
  rm -f "${cfg}"
  return ${rc}
}

models_json="$(gw_get /model/info 2>/dev/null \
  | jq '[.data[]
        | select((.model_info.mode // "chat") == "chat")
        | select(.model_name | contains("*") | not)]
        | unique_by(.model_name)
        | map({ (.model_name): {
            name: (.model_name + " (gateway)"),
            limit: {
              context: (.model_info.max_input_tokens // 128000),
              output: (.model_info.max_output_tokens // 8192)
            } } })
        | add // {}' 2>/dev/null || echo '{}')"

fallback_for() {  # provider -> one representative model id
  case "$1" in
    deepseek)   echo "deepseek/deepseek-chat" ;;
    openrouter) echo "openrouter/openai/gpt-4o-mini" ;;
    neuralwatt) echo "neuralwatt/qwen3.6-35b" ;;
    anthropic)  echo "anthropic/claude-haiku-4-5" ;;
    openai)     echo "openai/gpt-4o-mini" ;;
    opencode)   echo "opencode/gpt-5.5" ;;
    ollama)     printf '%s' "${models_json}" | jq -r '[keys[] | select(startswith("ollama/"))][0] // empty' ;;
  esac
}
if [ "$(printf '%s' "${models_json}" | jq 'length')" -eq 0 ]; then
  echo "55-opencode: gateway catalog unavailable — falling back to one model per configured provider" >&2
  for provider in ${configured}; do
    id="$(fallback_for "${provider}")"
    models_json="$(printf '%s' "${models_json}" | jq --arg id "${id}" \
      '. + {($id): {name: ($id + " (gateway)"), limit: {context: 128000, output: 8192}}}')"
  done
fi

# round-trip model: first configured provider that the catalog actually
# offers (keeps the check aligned with this box's keys)
check_model=""
for provider in ${configured}; do
  id="$(fallback_for "${provider}")"
  if [ "$(printf '%s' "${models_json}" | jq --arg id "${id}" 'has($id)')" = "true" ]; then
    check_model="${id}"
    break
  fi
done
if [ -z "${check_model}" ]; then
  check_model="$(printf '%s' "${models_json}" | jq -r 'keys[0] // empty')"
fi
CHECK_MODEL="${OC_CHECK_MODEL:-${check_model}}"
if [ -z "${CHECK_MODEL}" ]; then
  echo "55-opencode: no usable model in the gateway catalog — check scripts/30-gateway.sh" >&2
  exit 1
fi

# config OWNED by this script (box-staged; per-project opencode.json can
# still override locally)
mkdir -p "${OC_CONFIG_DIR}"
# Repair a box already broken by the bare-sudo postinstall above: mkdir -p
# succeeds on an existing unwritable directory, so without this the write
# below fails with a bare "Permission denied" forever. Scoped to the one
# directory this script declares it owns.
if [ ! -w "${OC_CONFIG_DIR}" ]; then
  echo "55-opencode: ${OC_CONFIG_DIR} not writable (root-owned by an earlier run) — reclaiming"
  sudo chown -R "$(id -u):$(id -g)" "${OC_CONFIG_DIR}"
fi
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
  if reply=$(oc_roundtrip) && grep -q "OC-GATEWAY-OK" <<< "${reply}"; then
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
