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
  # same non-argv rule as the catalog fetches: `-u pk:sk` would expose the
  # Langfuse secret in world-readable /proc/<pid>/cmdline
  lf_code="$(sudo sh -c "umask 077; . ${ENV_FILE}; cfg=\$(mktemp); \
    cat > \"\$cfg\" <<EOF
user = \"\${LANGFUSE_PUBLIC_KEY}:\${LANGFUSE_SECRET_KEY}\"
EOF
    curl -s -o /dev/null -w '%{http_code}' --max-time 20 -K \"\$cfg\" \"\${LANGFUSE_HOST%/}/api/public/projects\"; rc=\$?; rm -f \"\$cfg\"; exit \$rc")"
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
# prefix|base_url|key_var|routing
#   native -> litellm has a first-class provider: route as "<prefix>/<id>"
#     with NO api_base so provider-specific behaviour survives (OpenRouter's
#     HTTP-Referer/X-Title attribution — routing these through the generic
#     openai client made OpenRouter report the caller as "unknown").
#   custom -> OpenAI-compatible endpoint litellm has no provider for:
#     route as "openai/<id>" + api_base.
PROVIDER_CATALOGS="opencode-go|https://opencode.ai/zen/go/v1|OPENCODE_API_KEY|custom
opencode-zen|https://opencode.ai/zen/v1|OPENCODE_API_KEY|custom
neuralwatt|https://api.neuralwatt.com/v1|NEURALWATT_API_KEY|custom
synthetic|https://api.synthetic.new/v1|SYNTHETIC_API_KEY|custom
openrouter|https://openrouter.ai/api/v1|OPENROUTER_API_KEY|native
deepseek|https://api.deepseek.com/v1|DEEPSEEK_API_KEY|native
ollama|${OLLAMA_BASE:-https://ollama.com/v1}|OLLAMA_API_KEY|custom"

catalog_fragment="$(mktemp)"
while IFS='|' read -r prefix base keyvar routing; do
  [ -n "${prefix}" ] || continue
  fetch_failed=""
  if [ -n "${keyvar}" ]; then
    # presence check AND request both run inside the privileged shell:
    # interpolating the key into curl's -H here would expose the secret in
    # this user's process argv, visible to any local process listing
    if ! sudo sh -c ". ${ENV_FILE} && [ -n \"\${${keyvar}:-}\" ]"; then
      continue   # provider not configured on this box
    fi
    # curl -K <file>: the header (and thus the key) never appears in ANY
    # process argv — /proc/<pid>/cmdline is world-readable even for root
    # processes, so `-H "Authorization: Bearer ..."` would leak it to any
    # local user running ps
    # here-doc, not printf args: the key never reaches any argv, whatever
    # /bin/sh happens to be (printf is a builtin in dash/bash, but the
    # guarantee shouldn't rest on that). Config file is 077 and removed
    # immediately; curl -K keeps the header out of the command line.
    raw="$(sudo sh -c "umask 077; . ${ENV_FILE}; cfg=\$(mktemp); \
      cat > \"\$cfg\" <<EOF
header = \"Authorization: Bearer \${${keyvar}}\"
EOF
      curl -fsS --max-time 25 -K \"\$cfg\" \"${base}/models\"; rc=\$?; rm -f \"\$cfg\"; exit \$rc" 2>/dev/null || true)"
    [ -n "${raw}" ] || fetch_failed=1
  else
    # keyless endpoint: skip silently when unreachable
    raw="$(curl -fsS --max-time 10 "${base}/models" 2>/dev/null || true)"
  fi
  # a CONFIGURED provider whose catalog fetch fails must not silently lose
  # its routes: installing a config without them breaks working models
  # until some later successful run
  if [ -n "${fetch_failed}" ]; then
    echo "30-gateway: catalog fetch FAILED for ${prefix} (configured) — refusing to install a config missing its routes" >&2
    rm -f "${catalog_fragment}" "${rendered}"
    exit 1
  fi
  # Keep whatever metadata the provider publishes (OpenRouter gives
  # per-token pricing + context; plain OpenAI-style /models gives none) —
  # dropping it would leave clients showing every model as free with an
  # invented context window.
  # Providers publish metadata in different shapes: OpenRouter uses
  # per-token strings at the top level, Neuralwatt nests per-MILLION
  # prices and capabilities under .metadata. Read both; anything missing
  # is simply omitted (never invented).
  ids="$(printf '%s' "${raw}" | jq -r '
    def permil(x): if x == null then "" else (x / 1000000 | tostring) end;
    .data[]? | [
      .id,
      (if .pricing.prompt then (.pricing.prompt | tostring)
       else permil(.metadata.pricing.input_per_million) end),
      (if .pricing.completion then (.pricing.completion | tostring)
       else permil(.metadata.pricing.output_per_million) end),
      ((.context_length // .top_provider.context_length
        // .metadata.limits.max_context_length // .max_model_len // "") | tostring),
      ((.top_provider.max_completion_tokens
        // .metadata.limits.max_output_tokens // "") | tostring),
      (if .pricing.input_cache_read then (.pricing.input_cache_read | tostring)
       else permil(.metadata.pricing.cached_input_per_million) end),
      ((.pricing.input_cache_write // "") | tostring),
      (((.architecture.input_modalities // [] | index("image")) != null
        or (.metadata.capabilities.vision // false)) | tostring),
      (((.supported_parameters // [] | index("reasoning")) != null
        or (.metadata.capabilities.reasoning // false)) | tostring)
    ] | join("\u001f")' 2>/dev/null || true)"
  [ -n "${ids}" ] || continue
  count=0
  # \x1f (unit separator), NOT tab: tab is IFS *whitespace*, so bash
  # collapses runs of it and empty fields shift every later value into the
  # wrong variable (observed: cache price landing in max_output_tokens)
  while IFS=$'\x1f' read -r id in_cost out_cost ctx max_out cache_r cache_w vision reasoning; do
    [ -n "${id}" ] || continue
    case "${id}" in *'"'*|*'*'*) continue ;; esac   # skip ids we can't quote safely
    {
      echo "  - model_name: \"${prefix}/${id}\""
      echo "    litellm_params:"
      if [ "${routing}" = "native" ]; then
        echo "      model: \"${prefix}/${id}\""
      else
        echo "      model: \"openai/${id}\""
        echo "      api_base: \"${base}\""
      fi
      if [ -n "${keyvar}" ]; then
        echo "      api_key: os.environ/${keyvar}"
      else
        echo "      api_key: \"none\""
      fi
      echo "    model_info:"
      echo "      mode: chat"
      case "${in_cost}" in ''|null) ;; *) echo "      input_cost_per_token: ${in_cost}" ;; esac
      case "${out_cost}" in ''|null) ;; *) echo "      output_cost_per_token: ${out_cost}" ;; esac
      case "${ctx}" in ''|null|0) ;; *) echo "      max_input_tokens: ${ctx}" ;; esac
      # sizes: 0 is meaningless, unlike a published price of 0
      case "${max_out}" in ''|null|0) ;; *) echo "      max_output_tokens: ${max_out}" ;; esac
      case "${cache_r}" in ''|null) ;; *) echo "      cache_read_input_token_cost: ${cache_r}" ;; esac
      case "${cache_w}" in ''|null) ;; *) echo "      cache_creation_input_token_cost: ${cache_w}" ;; esac
      case "${vision}" in true) echo "      supports_vision: true" ;; esac
      case "${reasoning}" in true) echo "      supports_reasoning: true" ;; esac
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

# same non-argv rule as every other credential path in this repo
models="$(sudo sh -c "umask 077; . ${ENV_FILE}; cfg=\$(mktemp); \
  cat > \"\$cfg\" <<EOF
header = \"Authorization: Bearer \${LITELLM_MASTER_KEY}\"
EOF
  curl -fsS -K \"\$cfg\" http://127.0.0.1:4000/v1/models; rc=\$?; rm -f \"\$cfg\"; exit \$rc")"
model_count="$(printf '%s' "${models}" | jq '.data | length')"
if [ "${model_count}" -eq 0 ]; then
  echo "gateway is up but lists zero models — check /opt/lavasec/litellm.yaml" >&2
  exit 1
fi
printf '%s' "${models}" | jq -r '.data[0:5][].id' | sed 's/^/  model: /'
echo "30-gateway: OK (${model_count} models, $(/opt/lavasec/venv/bin/litellm --version 2>/dev/null || true))"

# Structural provider changes (e.g. opencode/* renamed to opencode-zen/* +
# opencode-go/*) invalidate the model ids pi and opencode persist from a
# previous run: ~/.bashrc (default model) and ~/.config/opencode/opencode.json.
# Those are rewritten by their own bootstrap slices, which this refresh path
# does NOT run — so warn the operator instead of leaving stale clients.
if grep -q 'opencode-zen\|opencode-go' /opt/lavasec/litellm.yaml; then
  echo "30-gateway: NOTE — opencode routes changed. If this box already had an" >&2
  echo "OpenCode install, re-run scripts/40-pi.sh and scripts/55-opencode.sh to" >&2
  echo "refresh pi's default model (.bashrc) and opencode.json model list." >&2
fi
