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

# opencode is installed into a USER-WRITABLE npm prefix (~/.local), never
# the root-owned global (/usr/lib/node_modules). This is load-bearing:
# T3 Code (60-t3code.sh, NoNewPrivileges=true) cannot elevate, and its
# "update opencode" runs `opencode upgrade`, which uses the npm method —
# `npm install -g opencode-ai`. Against the root-owned global that dies
# EACCES → npm exit 243 → "Provider update failed". Against the user prefix
# the same command writes to ~/.local and succeeds unprivileged. The prefix
# is recorded in the user's ~/.npmrc so opencode's bare `npm install -g`
# lands here, and ~/.local/bin is already on PATH for login/interactive
# shells via the stock ~/.profile.
OC_PREFIX="${HOME}/.local"
OC_BIN_DIR="${OC_PREFIX}/bin"
export PATH="${OC_BIN_DIR}:${PATH}"

if [ ! -s "${KEY_FILE}" ]; then
  echo "55-opencode: missing ${KEY_FILE} — run scripts/40-pi.sh first" >&2
  exit 1
fi

# Install + postinstall run AS THIS USER, not root. opencode-ai's
# postinstall calls verifyBinary(), which EXECUTES the binary, which then
# materialises its config dir from HOME/XDG — owner = whoever ran it. As
# this user that is ~/.config/opencode owned by this user, so the
# unprivileged config write below just works. The old root install instead
# left root-owned config dirs under this user's home: `sudo -H` preserves
# HOME and XDG_* survives sudo, so a fresh box could never finish this
# slice. Running as the user sidesteps the whole class — the root-owned-dir
# reclaim block below stays only to mend boxes already broken by the
# previous install.
#
# The prefix above is persisted to ~/.npmrc, so `npm install -g` lands in
# OC_PREFIX and `npm root -g` returns OC_PREFIX/lib/node_modules.
#
# Gate on the USER-prefix binary actually WORKING (`--version`), invoking it
# by absolute path: `command -v opencode` / a PATH search would fall back to
# the stale root-owned /usr/bin/opencode left by the old install and pass. A
# bare `-x` is not enough either: `npm install --ignore-scripts` creates the
# bin symlink BEFORE the separate postinstall.mjs fetches the platform
# binary, so if postinstall fails or bootstrap is interrupted, `-x` is
# satisfied by a broken symlink and the required postinstall is skipped
# forever. `--version` on the absolute path fails for either a missing OR
# broken install, so a re-run of bootstrap repairs it instead of selecting
# an unusable copy (postinstall failure still aborts loudly under `set -e`).
#
# opencode-ai NEEDS its own postinstall (fetches the platform binary). Keep
# --ignore-scripts so no transitive package runs code, then run THIS
# package's postinstall deliberately.
npm config set prefix "${OC_PREFIX}"
if ! "${OC_BIN_DIR}/opencode" --version >/dev/null 2>&1; then
  npm install -g --ignore-scripts opencode-ai >/dev/null
  (cd "$(npm root -g)/opencode-ai" && node postinstall.mjs >/dev/null)
fi
echo "55-opencode: opencode $(opencode --version 2>/dev/null | head -1)"

# which providers does this box have keys for? (echo names only, never values)
configured="$(sudo sh -c ". ${ENV_FILE} && \
  { [ -n \"\${DEEPSEEK_API_KEY:-}\" ]   && echo deepseek; \
    [ -n \"\${OPENROUTER_API_KEY:-}\" ] && echo openrouter; \
    [ -n \"\${NEURALWATT_API_KEY:-}\" ] && echo neuralwatt; \
    [ -n \"\${ANTHROPIC_API_KEY:-}\" ]  && echo anthropic; \
    [ -n \"\${OPENAI_API_KEY:-}\" ]     && echo openai; \
    [ -n \"\${OPENCODE_API_KEY:-}\" ]   && echo opencode-zen opencode-go; \
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

# Reasoning-effort variants: opencode renders an effort selector (and T3
# Code its effort toggle) ONLY from `variants` in this config — for
# config-defined models it derives nothing from models.dev or the gateway.
# Source exact per-model effort values from opencode's models.dev cache
# (the same reasoning_options derivation opencode itself applies to its
# built-in providers); fall back to the generic low/medium/high set when
# the gateway's /model/info only says supports_reasoning. No enumerable
# metadata exists for speed tiers or temperature values (models.dev has
# none; litellm's per-effort flags are unset and its service_tier entry in
# supported_openai_params is a generic openai-route default, not per-model
# truth), so no other variant kinds are generated.
# (--slurpfile, not --argjson: the cache is multi-MB, over the 128 KiB
# single-argv limit; missing/unreadable cache degrades to an empty db)
md_cache="${HOME}/.cache/opencode/models.json"
md_slurp=/dev/null   # slurping /dev/null yields [] — the empty-db case
if jq -e 'type == "object"' "${md_cache}" >/dev/null 2>&1; then
  md_slurp="${md_cache}"
fi

models_json="$(gw_get /model/info 2>/dev/null \
  | jq --slurpfile md "${md_slurp}" '
      def mddb: ($md[0] // {});
      def mdentry($name):
        ($name | split("/")) as $seg
        | (if ($seg | length) > 1 then
            ($seg[0]) as $h | ($seg[1:] | join("/")) as $t
            | (mddb[$h].models[$t]
              // (if $h == "ollama" then mddb["ollama-cloud"].models[$t] else null end))
          else null end)
          // ([ mddb | to_entries[] | .value.models[$name] // empty ] | first)
          // null;
      [.data[]
        | select((.model_info.mode // "chat") == "chat")
        | select(.model_name | contains("*") | not)]
        | unique_by(.model_name)
        | map(. as $m
          | (mdentry($m.model_name)) as $e
          | ([$e.reasoning_options[]? | select(.type == "effort") | .values[]?]) as $exact
          | (if ($exact | length) > 0 then $exact
             elif ($m.model_info.supports_reasoning // false) then ["low", "medium", "high"]
             else [] end) as $efforts
          | { ($m.model_name): ({
                name: (.model_name + " (gateway)"),
                limit: {
                  context: ($m.model_info.max_input_tokens // 128000),
                  output: ($m.model_info.max_output_tokens // 8192)
                } }
              + (if ($efforts | length) > 0 then
                   { variants: (reduce $efforts[] as $v ({}; .[$v] = { reasoningEffort: $v })) }
                 else {} end)) })
        | add // {}' 2>/dev/null || echo '{}')"

fallback_for() {  # provider -> one representative model id
  case "$1" in
    deepseek)   echo "deepseek/deepseek-chat" ;;
    openrouter) echo "openrouter/openai/gpt-4o-mini" ;;
    neuralwatt) echo "neuralwatt/qwen3.6-35b" ;;
    anthropic)  echo "anthropic/claude-haiku-4-5" ;;
    openai)     echo "openai/gpt-4o-mini" ;;
    opencode-go)  echo "opencode-go/deepseek-v4-flash" ;;
    opencode-zen) echo "opencode-zen/claude-haiku-4-5" ;;
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
# offers (keeps the check aligned with this box's keys). OpenCode shares one
# key across two independently entitled plans — pick the PAYG/Zen route first,
# keeping the Go route as a fallback so a Go-only account still round-trips.
check_model=""
check_fallback=""
for provider in ${configured}; do
  id="$(fallback_for "${provider}")"
  if [ "$(printf '%s' "${models_json}" | jq --arg id "${id}" 'has($id)')" = "true" ]; then
    check_model="${id}"
    case "${provider}" in
      opencode-zen) check_fallback="opencode-go/deepseek-v4-flash" ;;
      opencode-go)  check_fallback="opencode-zen/claude-haiku-4-5" ;;
    esac
    break
  fi
done
if [ -z "${check_model}" ]; then
  check_model="$(printf '%s' "${models_json}" | jq -r 'keys[0] // empty')"
fi
CHECK_MODEL="${OC_CHECK_MODEL:-${check_model}}"
# an explicit OC_CHECK_MODEL disables auto-fallback to another model
if [ -n "${OC_CHECK_MODEL:-}" ]; then
  CHECK_FALLBACK_MODEL=""
else
  CHECK_FALLBACK_MODEL="${check_fallback}"
fi
if [ -z "${CHECK_MODEL}" ]; then
  echo "55-opencode: no usable model in the gateway catalog — check scripts/30-gateway.sh" >&2
  exit 1
fi

# config OWNED by this script (box-staged; per-project opencode.json can
# still override locally)
mkdir -p "${OC_CONFIG_DIR}"
# Repair a box already broken by the OLD root postinstall (pre-user-prefix
# installs ran verifyBinary() as root, creating root-owned dirs here):
# mkdir -p succeeds on an existing unwritable directory, so without this the
# write below fails with a bare "Permission denied" forever. Scoped to the
# one directory this script declares it owns. Fresh boxes never hit it.
if [ ! -w "${OC_CONFIG_DIR}" ]; then
  echo "55-opencode: ${OC_CONFIG_DIR} not writable ($(stat -c '%U:%G %a' "${OC_CONFIG_DIR}")) — reclaiming"
  sudo chown -R "$(id -u):$(id -g)" "${OC_CONFIG_DIR}"
fi

# --slurpfile, NOT --argjson: a single argv string is capped at 128 KiB
# (MAX_ARG_STRLEN), which this catalog exceeds somewhere past ~500 models --
# jq then dies with "Argument list too long". Same lesson as the credential
# rule: keep bulk data out of argv and hand it over as a file.
models_file="$(mktemp)"
trap 'rm -f "${models_file}"' EXIT
printf '%s' "${models_json}" > "${models_file}"
jq -n --slurpfile models "${models_file}" '{
  "$schema": "https://opencode.ai/config.json",
  provider: {
    "lava-gateway": {
      npm: "@ai-sdk/openai-compatible",
      name: "Lava Gateway",
      options: { baseURL: "http://127.0.0.1:4000/v1", apiKey: "{env:LITELLM_MASTER_KEY}" },
      models: $models[0]   # slurpfile wraps the document in an array
    }
  }
}' > "${OC_CONFIG_DIR}/opencode.json"

# round-trip: a real completion opencode → gateway → provider.
# success = exit 0 AND sentinel (the prompt contains the sentinel, so
# output alone could false-pass on an echoed error). One retry: the very
# first run after a config change can hang on opencode's server spawn
# (observed once — 120s of silence, then killed), and heals immediately.
ok=""
reply=""
for m in "${CHECK_MODEL}" ${CHECK_FALLBACK_MODEL:+${CHECK_FALLBACK_MODEL}}; do
  [ -n "${m}" ] || continue
  for attempt in 1 2; do
    if reply=$(LITELLM_MASTER_KEY="$(cat "${KEY_FILE}")" timeout 120 opencode run \
          --model "lava-gateway/${m}" \
          "Reply with exactly: OC-GATEWAY-OK" 2>&1 < /dev/null) && grep -q "OC-GATEWAY-OK" <<< "${reply}"; then
      CHECK_MODEL="${m}"
      ok=1
      break
    fi
    if [ "${attempt}" = 1 ]; then
      echo "55-opencode: round-trip via ${m} failed — retrying once" >&2
      sleep 5
    fi
  done
  [ -n "${ok}" ] && break
done
if [ -z "${ok}" ]; then
  echo "55-opencode: round-trip FAILED after retry:" >&2
  printf '%s\n' "${reply}" | tail -5 >&2
  exit 1
fi
echo "55-opencode: OK (${CHECK_MODEL} round-trip via gateway verified)"
