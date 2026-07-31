#!/usr/bin/env bash
set -euo pipefail
# LiteLLM gateway: venv under /opt/lavasec, config + systemd unit installed,
# service enabled, loopback-only bind verified, /v1/models smoke-tested.
# Requires /etc/lavasec/lavasec.env (root:root 600) — see env/example.env.
# Optional: LITELLM_VERSION=x.y.z to override the pinned litellm release.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE=/etc/lavasec/lavasec.env

# This branch needs the 1.95.0 line: only it emits Langfuse's v4 ingestion
# header, which the langfuse_otel callback in litellm.yaml depends on. But
# 1.95.0rc1 CANNOT RUN. Its management_v1 module imports fastapi's
# get_flat_dependant while declaring only fastapi>=0.136.3,<1.0, and fastapi
# deleted that symbol in 0.140.7 (present in 0.140.6, gone from 0.140.7 on).
# Any current fastapi therefore kills the proxy at import:
#   ImportError: cannot import name 'get_flat_dependant'
#     from 'fastapi.dependencies.utils'
# Constraining fastapi back to 0.140.6 would "fix" it, but that version was
# superseded by 13 patches inside two days — pinning into the middle of an
# upstream fix cycle to accommodate a release candidate is the worse trade.
#
# Sitting BELOW the breakage does work: the v4 header landed 2026-07-19 and
# management_v1 arrived between 07-24 and 07-29, so 1.95.0.dev2 has the
# header without the bad import, and e2e went green on it against current
# fastapi 0.141.1 (litellm=1.95.0.dev2 fastapi=0.141.1, 800 models served).
# That proves the approach; it is not pinned here because shipping a dev
# build to the gateway to chase an evaluator feature is not a trade worth
# making while the release line is visibly unsettled.
#
# PARKED until litellm 1.95.0 STABLE. On revisit, check in this order:
#   1. does litellm/proxy/management_endpoints/management_v1/common.py still
#      import get_flat_dependant? if so the release is still broken against
#      any fastapi >= 0.140.7 regardless of version number
#   2. does litellm/integrations/langfuse/langfuse_otel.py still define
#      LANGFUSE_INGESTION_VERSION = "4"? the guard below probes exactly this
#   3. is the legacy langfuse callback still SDK v2? litellm PR #33391 would
#      change that and make this whole OTEL migration unnecessary
#
# Until then the default install is latest-stable, which cannot emit v4, so
# the capability guard below fails by design. That red is this branch
# reporting its blocker, not a regression. LITELLM_VERSION still overrides.

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
# Report what actually landed. `pip -q` hides resolution entirely, so when
# the proxy failed to import there was no way to tell which versions were
# involved without a second trip to the box.
echo "30-gateway: litellm=$(/opt/lavasec/venv/bin/pip show litellm 2>/dev/null | awk '/^Version:/{print $2}') fastapi=$(/opt/lavasec/venv/bin/pip show fastapi 2>/dev/null | awk '/^Version:/{print $2}')"

# tracing deps only when tracing is configured — keeps the venv lean
# otherwise (the callback in litellm.yaml renders under the same key)
# Tracing is all-or-nothing: a rendered callback without its deps (or
# without every var) makes litellm 500 on EVERY request. This single
# condition drives both the dep install and the config render below.
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
  # Does the config actually ask for langfuse_otel? Everything below that
  # concerns the OTEL path is gated on this. The v4 cutover is PARKED (see
  # dags and the plan: 1.95.0rc1 cannot start), so the callback above is
  # `langfuse` and this branch has to stay deployable on 1.94.x — an
  # unconditional guard would refuse every install.
  #
  # Gated on the template rather than a separate flag so the two cannot drift:
  # flipping the callback to langfuse_otel arms the install and the guard in
  # the same edit, and flipping it back disarms them.
  wants_otel=""
  if grep -qE '^[[:space:]]*(success_callback|failure_callback|callbacks):.*langfuse_otel' \
      "${REPO_DIR}/config/litellm.yaml"; then
    wants_otel=1
  fi

  if [ -n "${wants_otel}" ]; then
  # OTEL stack for the langfuse_otel callback. litellm[proxy] does NOT
  # carry it: these live in litellm's separate "proxy-runtime" extra,
  # which we don't install wholesale (it also drags in vertex, ddtrace,
  # sentry, mangum — against the lean-venv rule above). Versions mirror
  # that extra exactly so the opentelemetry packages move in lockstep
  # with what litellm actually tests against.
  sudo /opt/lavasec/venv/bin/pip install -q \
    "opentelemetry-api==1.28.0" \
    "opentelemetry-sdk==1.28.0" \
    "opentelemetry-exporter-otlp==1.28.0" \
    "opentelemetry-instrumentation-fastapi==0.49b0"
  fi

  # The langfuse SDK is CUTOVER SCAFFOLDING, not a dependency of tracing.
  # langfuse_otel speaks OTLP directly and imports no langfuse package at
  # all; only the legacy "langfuse" callback uses the SDK, and it imports
  # it lazily (inside functions, not at module load). It is kept solely so
  # reverting litellm.yaml to success_callback: ["langfuse"] works without
  # a pip install under incident pressure — a missing SDK would not fail
  # at startup, it would fail on every traced request.
  #
  # pin <3 because litellm itself declares langfuse>=2.59.7,<3.0, and the
  # legacy handler reads langfuse.version.__version__, which the v3+ SDK
  # moved (AttributeError on EVERY traced request).
  #
  # FOLLOW-UP: drop this install once the OTEL cutover is confirmed
  # stable. Doing so also removes a latent break — litellm PR #33391
  # raises its own requirement to langfuse>=4.7,<5, at which point this
  # line would silently downgrade the SDK and break the install.
  sudo /opt/lavasec/venv/bin/pip install -q "${LANGFUSE_PIN:-langfuse<3}"

  # Refuse rather than degrade: langfuse_otel only reaches Langfuse's v4
  # ingestion path when it sends x-langfuse-ingestion-version: 4, and that
  # header is absent from the entire 1.94.x line (present from 1.95.0 —
  # earliest RC-grade build 1.95.0rc1). Without it spans still arrive and
  # dashboards still look healthy, but they ingest the OLD way and
  # observation-level evaluators silently never run.
  #
  # Probing the constant beats parsing "1.95.0rc1" — version strings are a
  # proxy for the capability, this is the capability. It does NOT survive
  # the module being moved: litellm PR #33391 touches this file, and if it
  # relocates the constant the import breaks. That is why the two failure
  # modes are distinguished below (exit 2 = cannot probe, exit 1 = probed
  # and too old) and the interpreter's own error is surfaced. Failing
  # loudly on a moved symbol is the safe direction; failing loudly while
  # blaming the wrong cause is not.
  if [ -n "${wants_otel}" ]; then
  probe_err=""
  probe_rc=0
  probe_err="$(sudo /opt/lavasec/venv/bin/python -c 'import sys
try:
    from litellm.integrations.langfuse.langfuse_otel import LANGFUSE_INGESTION_VERSION as v
except Exception as exc:  # ImportError, but also a broken venv or moved symbol
    print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(2)
if v != "4":
    print(f"LANGFUSE_INGESTION_VERSION is {v!r}, expected \"4\"", file=sys.stderr)
    sys.exit(1)' 2>&1)" || probe_rc=$?
  if [ "${probe_rc}" -ne 0 ]; then
    {
      if [ "${probe_rc}" -eq 2 ]; then
        echo "30-gateway: cannot verify Langfuse v4 ingestion support"
        echo "  The probe could not read LANGFUSE_INGESTION_VERSION at all. Either the"
        echo "  venv is broken, or litellm moved the symbol (PR #33391 touches this"
        echo "  file) — in which case this guard needs its import path updated."
      else
        echo "30-gateway: installed litellm cannot emit Langfuse v4 ingestion"
        echo "  litellm.yaml routes tracing through the langfuse_otel callback, but this"
        echo "  build does not send x-langfuse-ingestion-version: 4 — traces would ingest"
        echo "  via the old path and observation-level evaluators would never run."
        echo "  Install a 1.95.0+ build, e.g. LITELLM_VERSION=1.95.0rc1, and re-run."
      fi
      echo "  python: ${probe_err}"
    } >&2
    exit 1
  fi
  echo "30-gateway: langfuse tracing enabled via langfuse_otel (v4 ingestion verified, credentials verified)"
  else
    echo "30-gateway: langfuse tracing enabled (legacy callback; v4 cutover parked)"
  fi
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
PROVIDER_CATALOGS="opencode|https://opencode.ai/zen/v1|OPENCODE_API_KEY|custom
neuralwatt|https://api.neuralwatt.com/v1|NEURALWATT_API_KEY|custom
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
  # Dump the journal rather than only naming it: on a CI runner nobody is
  # there to run the follow-up command, so the actual reason was lost and
  # every startup failure looked identical from the log.
  echo "gateway did not come up — last 50 journal lines follow:" >&2
  sudo journalctl -u litellm -n 50 --no-pager >&2 || true
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
