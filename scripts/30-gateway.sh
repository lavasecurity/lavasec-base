#!/usr/bin/env bash
set -euo pipefail
# LiteLLM gateway: venv under /opt/lavasec, config + systemd unit installed,
# service enabled, loopback-only bind verified, /v1/models smoke-tested.
# Requires /etc/lavasec/lavasec.env (root:root 600) — see env/example.env.
# Optional: LITELLM_VERSION=x.y.z to pin the litellm release.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE=/etc/lavasec/lavasec.env

# --- preflight: env file present, locked down, master key real ---
if [ ! -f "${ENV_FILE}" ]; then
  echo "missing ${ENV_FILE} — see README quickstart" >&2
  exit 1
fi
perms="$(stat -c '%a %U' "${ENV_FILE}")"
if [ "${perms}" != "600 root" ]; then
  echo "${ENV_FILE} must be root-owned mode 600 (got: ${perms})" >&2
  exit 1
fi
if ! sudo grep -q '^LITELLM_MASTER_KEY=sk-' "${ENV_FILE}" || sudo grep -q 'CHANGE-ME' "${ENV_FILE}"; then
  echo "LITELLM_MASTER_KEY in ${ENV_FILE} is not a real sk- value" >&2
  exit 1
fi

# --- service user + venv ---
if ! id -u lavasec >/dev/null 2>&1; then
  sudo useradd --system --user-group --home-dir /var/lib/lavasec --shell /usr/sbin/nologin lavasec
fi
sudo install -d -m 755 /opt/lavasec
if [ ! -x /opt/lavasec/venv/bin/pip ]; then
  sudo python3 -m venv /opt/lavasec/venv
fi
sudo /opt/lavasec/venv/bin/pip install -q --upgrade pip "litellm[proxy]${LITELLM_VERSION:+==${LITELLM_VERSION}}"

# langfuse SDK only when tracing is configured — keeps the venv lean
# otherwise (the callback in litellm.yaml renders under the same key)
# Tracing is all-or-nothing: a rendered callback without the SDK (or
# without every var) makes litellm 500 on EVERY request. This single
# condition drives both the SDK install and the config render below.
# shellcheck disable=SC2016  # intentionally unexpanded: evaluated inside
# the sudo subshell after the env file is sourced
LANGFUSE_TEST='[ -n "${LANGFUSE_PUBLIC_KEY:-}" ] && [ -n "${LANGFUSE_SECRET_KEY:-}" ] && [ -n "${LANGFUSE_HOST:-}" ]'
if sudo sh -c ". ${ENV_FILE} && ${LANGFUSE_TEST}"; then
  # Credentials are REGION-SCOPED: the wrong Langfuse host authenticates
  # nowhere, yet litellm logs "callbacks initialized" and returns 200 while
  # every trace export 401s in the background. Verify here so the failure
  # is loud at bootstrap instead of silent at runtime.
  lf_code="$(sudo sh -c ". ${ENV_FILE} && curl -s -o /dev/null -w '%{http_code}' --max-time 20 -u \"\${LANGFUSE_PUBLIC_KEY}:\${LANGFUSE_SECRET_KEY}\" \"\${LANGFUSE_HOST%/}/api/public/projects\"")"
  if [ "${lf_code}" != "200" ]; then
    {
      echo "30-gateway: langfuse credentials rejected by $(sudo sh -c ". ${ENV_FILE} && printf %s \"\${LANGFUSE_HOST}\"") (HTTP ${lf_code})"
      echo "  Langfuse keys are region-scoped — set LANGFUSE_HOST to the region"
      echo "  your project lives in (US: https://us.cloud.langfuse.com,"
      echo "  EU: https://cloud.langfuse.com) and re-run."
    } >&2
    exit 1
  fi
  # pin <3: litellm's integration reads langfuse.version.__version__,
  # which the v3+ SDK moved (AttributeError on EVERY traced request).
  # Override with LANGFUSE_PIN when litellm gains v3 support.
  sudo /opt/lavasec/venv/bin/pip install -q "${LANGFUSE_PIN:-langfuse<3}"
  echo "30-gateway: langfuse tracing enabled ($(/opt/lavasec/venv/bin/pip show langfuse 2>/dev/null | awk '/^Version:/{print $2}'), credentials verified)"
elif sudo sh -c ". ${ENV_FILE} && [ -n \"\${LANGFUSE_PUBLIC_KEY:-}\${LANGFUSE_SECRET_KEY:-}\${LANGFUSE_HOST:-}\" ]"; then
  echo "30-gateway: langfuse partially configured — tracing OFF (needs LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY and LANGFUSE_HOST)" >&2
fi

# --- config + unit ---
# Render the catalog template: each "requires <KEY>" section is included
# only when that key is set non-empty in the env file, so this box's live
# catalog contains exactly its keyed providers.
rendered="$(mktemp)"
rendered_content="$(sudo sh -c "set -a && . ${ENV_FILE} && if ${LANGFUSE_TEST}; then LANGFUSE_ENABLED=1; fi && set +a && awk '
  /^  # >>> requires / { skip = (ENVIRON[\$4] == \"\"); next }
  /^  # <<< requires / { skip = 0; next }
  !skip { print }
' \"${REPO_DIR}/config/litellm.yaml\"")"
printf '%s\n' "${rendered_content}" > "${rendered}"
# --- sync real catalogs from each provider's own /models endpoint ---
# Wildcards route anything but LIST only what litellm's bundled price DB
# happens to know (stale: e.g. OpenCode Zen's 60 models showed up as 1,
# kimi-k3 missing entirely). Providers publish the truth at /models, so
# enumerate that and emit explicit entries. Wildcards stay in the template
# for ad-hoc slugs; these entries make the LISTING complete and accurate.
# prefix|base_url|key_var   (empty key_var = keyless endpoint)
PROVIDER_CATALOGS="opencode|https://opencode.ai/zen/v1|OPENCODE_API_KEY
neuralwatt|https://api.neuralwatt.com/v1|NEURALWATT_API_KEY
openrouter|https://openrouter.ai/api/v1|OPENROUTER_API_KEY
deepseek|https://api.deepseek.com/v1|DEEPSEEK_API_KEY
ollama|${OLLAMA_BASE:-https://ollama.com/v1}|OLLAMA_API_KEY"

catalog_fragment="$(mktemp)"
while IFS='|' read -r prefix base keyvar; do
  [ -n "${prefix}" ] || continue
  if [ -n "${keyvar}" ]; then
    key="$(sudo sh -c ". ${ENV_FILE} && printf %s \"\${${keyvar}:-}\"")"
    [ -n "${key}" ] || continue
    raw="$(curl -fsS --max-time 25 -H "Authorization: Bearer ${key}" "${base}/models" 2>/dev/null || true)"
  else
    # keyless local provider: skip silently when it isn't running
    raw="$(curl -fsS --max-time 5 "${base}/models" 2>/dev/null || true)"
  fi
  # Keep whatever metadata the provider publishes (OpenRouter gives
  # per-token pricing + context; plain OpenAI-style /models gives none) —
  # dropping it would leave clients showing every model as free with an
  # invented context window.
  ids="$(printf '%s' "${raw}" | jq -r '
    .data[]? | [
      .id,
      (.pricing.prompt // "" | tostring),
      (.pricing.completion // "" | tostring),
      ((.context_length // .top_provider.context_length // "") | tostring),
      ((.top_provider.max_completion_tokens // "") | tostring),
      (.pricing.input_cache_read // "" | tostring),
      (.pricing.input_cache_write // "" | tostring),
      ((.architecture.input_modalities // [] | index("image")) != null | tostring)
    ] | @tsv' 2>/dev/null || true)"
  [ -n "${ids}" ] || continue
  count=0
  while IFS=$'\t' read -r id in_cost out_cost ctx max_out cache_r cache_w vision; do
    [ -n "${id}" ] || continue
    case "${id}" in *'"'*|*'*'*) continue ;; esac   # skip ids we can't quote safely
    {
      echo "  - model_name: \"${prefix}/${id}\""
      echo "    litellm_params:"
      echo "      model: \"openai/${id}\""
      echo "      api_base: \"${base}\""
      if [ -n "${keyvar}" ]; then
        echo "      api_key: os.environ/${keyvar}"
      else
        echo "      api_key: \"none\""
      fi
      echo "    model_info:"
      echo "      mode: chat"
      case "${in_cost}" in ''|null|0) ;; *) echo "      input_cost_per_token: ${in_cost}" ;; esac
      case "${out_cost}" in ''|null|0) ;; *) echo "      output_cost_per_token: ${out_cost}" ;; esac
      case "${ctx}" in ''|null|0) ;; *) echo "      max_input_tokens: ${ctx}" ;; esac
      case "${max_out}" in ''|null|0) ;; *) echo "      max_output_tokens: ${max_out}" ;; esac
      case "${cache_r}" in ''|null|0) ;; *) echo "      cache_read_input_token_cost: ${cache_r}" ;; esac
      case "${cache_w}" in ''|null|0) ;; *) echo "      cache_creation_input_token_cost: ${cache_w}" ;; esac
      case "${vision}" in true) echo "      supports_vision: true" ;; esac
    } >> "${catalog_fragment}"
    count=$((count + 1))
  done <<< "${ids}"
  echo "30-gateway: synced ${count} models from ${prefix}"
done <<< "${PROVIDER_CATALOGS}"

# splice the generated entries into model_list (before general_settings)
if [ -s "${catalog_fragment}" ]; then
  spliced="$(mktemp)"
  awk -v frag="${catalog_fragment}" '
    /^general_settings:/ && !done {
      while ((getline line < frag) > 0) print line
      close(frag); done = 1
    }
    { print }
  ' "${rendered}" > "${spliced}"
  mv "${spliced}" "${rendered}"
fi
rm -f "${catalog_fragment}"

if ! grep -q "model_name" "${rendered}"; then
  echo "30-gateway: rendered catalog has no models — no provider key in ${ENV_FILE} matches any template section" >&2
  rm -f "${rendered}"
  exit 1
fi
sudo install -m 644 "${rendered}" /opt/lavasec/litellm.yaml
rm -f "${rendered}"
sudo install -m 644 "${REPO_DIR}/systemd/litellm.service" /etc/systemd/system/litellm.service
sudo systemctl daemon-reload
sudo systemctl enable litellm >/dev/null
sudo systemctl restart litellm

# --- verify: up within 30s, loopback-only, models listed with master key ---
up=""
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1; then
    up=1
    break
  fi
  sleep 1
done
if [ -z "${up}" ]; then
  echo "gateway did not come up — check: journalctl -u litellm -n 50" >&2
  exit 1
fi

if ! ss -tln | grep -q '127\.0\.0\.1:4000'; then
  echo "gateway not bound to 127.0.0.1:4000" >&2
  exit 1
fi
if ss -tln | grep -qE '(0\.0\.0\.0|\[::\]):4000'; then
  echo "gateway exposed beyond loopback — refusing" >&2
  exit 1
fi

models="$(sudo sh -c ". ${ENV_FILE} && curl -fsS -H \"Authorization: Bearer \${LITELLM_MASTER_KEY}\" http://127.0.0.1:4000/v1/models")"
model_count="$(printf '%s' "${models}" | jq '.data | length')"
if [ "${model_count}" -eq 0 ]; then
  echo "gateway is up but lists zero models — check /opt/lavasec/litellm.yaml" >&2
  exit 1
fi
printf '%s' "${models}" | jq -r '.data[0:5][].id' | sed 's/^/  model: /'
echo "30-gateway: OK (${model_count} models, $(/opt/lavasec/venv/bin/litellm --version 2>/dev/null || true))"
