#!/usr/bin/env bash
set -euo pipefail
# Reconciliation gate: does what Langfuse RECORDED match what this box is
# configured to do?
#
# Every tracing bug so far was found by a human noticing an odd number in a
# dashboard, because we configure one side and never read the other back:
#   - no data at all            (region-scoped keys pointed at the wrong host)
#   - gateway 500 on every call (Langfuse half-configured)
#   - wrong costs               (a field-shift wrote a cache price into a size)
#   - zero costs                (stale bundled prices won over real ones)
#   - wrong provider attributed (custom routing dropped the vendor)
# One mechanism catches all of them: send a tagged probe per provider, fetch
# that exact trace back, and compare it against /model/info.
#
# Skips cleanly when tracing is off, so a box without Langfuse is unaffected.
# LAVA_TRACING_SELFTEST=1 runs the comparison logic against fixtures and exits
# (no network, no credentials) -- that is what CI can verify.

ENV_FILE=/etc/lavasec/lavasec.env
KEY_FILE="${HOME}/.config/lavasec/gateway-key"
GATEWAY=http://127.0.0.1:4000

# --- cost comparison -------------------------------------------------------
# Returns: OK | MISMATCH:<reason>
# Deliberate asymmetry: a provider that publishes NO pricing (OpenCode Zen,
# Ollama Cloud) legitimately reports zero, so zero is only a failure when we
# DO have a configured price. Getting this backwards would make the gate cry
# wolf on every run, and a gate you learn to ignore is worse than none.
compare_cost() {
  local in_cost="$1" out_cost="$2" ptok="$3" ctok="$4" reported="$5"
  awk -v ic="${in_cost}" -v oc="${out_cost}" -v pt="${ptok}" -v ct="${ctok}" \
      -v got="${reported}" '
    BEGIN {
      priced = (ic > 0 || oc > 0)
      expected = ic * pt + oc * ct
      if (!priced) {
        # no configured price -> the only correct report is zero
        if (got > 1e-12) { printf "MISMATCH:provider publishes no price but trace reports %.8f\n", got }
        else             { print "OK:no-price-expected-zero" }
        exit
      }
      if (got <= 1e-12) {
        printf "MISMATCH:configured price %.10f/%.10f but trace reports zero cost\n", ic, oc
        exit
      }
      diff = got - expected; if (diff < 0) diff = -diff
      tol = expected * 0.05; if (tol < 1e-9) tol = 1e-9
      if (diff > tol) {
        printf "MISMATCH:cost %.8f but configured price implies %.8f\n", got, expected
      } else {
        printf "OK:cost %.8f matches configured %.8f\n", got, expected
      }
    }'
}

# --- self-test -------------------------------------------------------------
# Mutation test of the logic above: each case asserts a specific verdict, so a
# refactor that quietly stops detecting one class fails here.
if [ "${LAVA_TRACING_SELFTEST:-}" = "1" ]; then
  fails=0
  check() { # name expect_prefix args...
    local name="$1" expect="$2"; shift 2
    local got; got="$(compare_cost "$@")"
    if [ "${got#"${expect}"}" != "${got}" ]; then
      echo "  ok   ${name}"
    else
      echo "  FAIL ${name}: expected ${expect}*, got ${got}" >&2
      fails=$((fails + 1))
    fi
  }
  echo "70-verify-tracing: self-test"
  check "priced model, cost matches"        OK       0.000001 0.000002 100 50 0.0002
  check "priced model, cost 50% off"        MISMATCH 0.000001 0.000002 100 50 0.0001
  check "priced model, cost reported zero"  MISMATCH 0.000001 0.000002 100 50 0
  check "unpriced model, zero is correct"   OK       0        0        100 50 0
  check "unpriced model, unexpected cost"   MISMATCH 0        0        100 50 0.0002
  check "priced, tiny rounding within tol"  OK       0.000001 0.000002 100 50 0.000201
  if [ "${fails}" -ne 0 ]; then
    echo "70-verify-tracing: self-test FAILED (${fails})" >&2
    exit 1
  fi
  echo "70-verify-tracing: self-test OK (6 cases)"
  exit 0
fi

# --- preconditions ---------------------------------------------------------
if [ ! -f "${ENV_FILE}" ]; then
  echo "70-verify-tracing: no ${ENV_FILE} — skipping"
  exit 0
fi
# Same all-or-nothing condition 30-gateway.sh uses to render the callbacks.
# shellcheck disable=SC2016  # evaluated inside the sudo subshell
LF_TEST='[ -n "${LANGFUSE_PUBLIC_KEY:-}" ] && [ -n "${LANGFUSE_SECRET_KEY:-}" ] && [ -n "${LANGFUSE_HOST:-}" ]'
if ! sudo sh -c ". ${ENV_FILE} && ${LF_TEST}"; then
  echo "70-verify-tracing: tracing not configured — skipping"
  exit 0
fi
if [ ! -r "${KEY_FILE}" ]; then
  echo "70-verify-tracing: no gateway key at ${KEY_FILE} — run scripts/40-pi.sh" >&2
  exit 1
fi

gw_cfg="$(mktemp)"; chmod 600 "${gw_cfg}"
cat > "${gw_cfg}" <<EOF
header = "Authorization: Bearer $(cat "${KEY_FILE}")"
header = "Content-Type: application/json"
EOF
trap 'rm -f "${gw_cfg}"' EXIT

# One probe model per configured provider, with its configured prices.
# Cheapest available per prefix; the point is the accounting path, not output.
probes="$(curl -fsS --max-time 20 -K "${gw_cfg}" "${GATEWAY}/model/info" | jq -r '
  [ .data[]
    | select(.model_name | contains("*") | not)
    | { provider: (.model_name | split("/")[0]),
        model:    .model_name,
        in:       (.model_info.input_cost_per_token  // 0),
        out:      (.model_info.output_cost_per_token // 0) } ]
  | group_by(.provider) | map(.[0])
  | .[] | [.provider, .model, (.in|tostring), (.out|tostring)] | @tsv')"

if [ -z "${probes}" ]; then
  echo "70-verify-tracing: gateway lists no concrete models — nothing to verify" >&2
  exit 1
fi

# --- send one tagged probe per provider ------------------------------------
# trace_id from request metadata is honoured by litellm's langfuse handler,
# so each probe is fetched back by exact id rather than searched for.
sent="$(mktemp)"; trap 'rm -f "${gw_cfg}" "${sent}"' EXIT
while IFS=$'\t' read -r provider model in_cost out_cost; do
  [ -n "${provider}" ] || continue
  # openssl, NOT `tr < /dev/urandom | head -c 12`: head exits at 12 bytes, tr
  # keeps writing and takes SIGPIPE, and under pipefail+errexit the 141 aborts
  # the whole script. Same class as the false negative fixed in #15 -- and it
  # would have fired on the FIRST probe, on a path CI cannot reach (CI skips
  # before this line for want of Langfuse credentials).
  trace_id="lavasec-recon-$(date +%s)-$(openssl rand -hex 6)"
  body="$(mktemp)"
  jq -n --arg m "${model}" --arg t "${trace_id}" '{
    model: $m,
    max_tokens: 1,
    messages: [{role: "user", content: "ping"}],
    metadata: { trace_id: $t, trace_name: "lavasec-reconciliation" }
  }' > "${body}"
  if resp="$(curl -fsS --max-time 60 -K "${gw_cfg}" -X POST \
      --data-binary "@${body}" "${GATEWAY}/v1/chat/completions" 2>/dev/null)"; then
    ptok="$(printf '%s' "${resp}" | jq -r '.usage.prompt_tokens // 0')"
    ctok="$(printf '%s' "${resp}" | jq -r '.usage.completion_tokens // 0')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${provider}" "${model}" "${trace_id}" "${in_cost}" "${out_cost}" "${ptok}" "${ctok}" >> "${sent}"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${provider}" "${model}" "REQUEST_FAILED" "${in_cost}" "${out_cost}" 0 0 >> "${sent}"
  fi
  rm -f "${body}"
done <<< "${probes}"

# Langfuse batches; give the exporter time to flush before reading back.
sleep 10

# --- read each trace back and compare --------------------------------------
lf_host="$(sudo sh -c ". ${ENV_FILE} && printf %s \"\${LANGFUSE_HOST%/}\"")"
rc=0
printf '\n%-12s %-34s %s\n' "PROVIDER" "MODEL" "VERDICT"
while IFS=$'\t' read -r provider model trace_id in_cost out_cost ptok ctok; do
  [ -n "${provider}" ] || continue
  if [ "${trace_id}" = "REQUEST_FAILED" ]; then
    printf '%-12s %-34s %s\n' "${provider}" "${model}" "FAIL: gateway request failed"
    rc=1; continue
  fi

  # Poll: the trace may not be queryable the instant it is flushed.
  trace=""
  for _ in 1 2 3 4 5 6; do
    trace="$(sudo sh -c "umask 077; . ${ENV_FILE}; cfg=\$(mktemp); \
      cat > \"\$cfg\" <<EOF
user = \"\${LANGFUSE_PUBLIC_KEY}:\${LANGFUSE_SECRET_KEY}\"
EOF
      curl -fsS --max-time 20 -K \"\$cfg\" \"${lf_host}/api/public/traces/${trace_id}\"; \
      rc=\$?; rm -f \"\$cfg\"; exit \$rc" 2>/dev/null || true)"
    [ -n "${trace}" ] && break
    sleep 5
  done
  if [ -z "${trace}" ]; then
    printf '%-12s %-34s %s\n' "${provider}" "${model}" "FAIL: no trace in Langfuse (id ${trace_id})"
    rc=1; continue
  fi

  # Schema-tolerant: Langfuse has spelled cost several ways across versions.
  # If NONE match we fail loudly with the payload rather than assume zero --
  # silently reading a missing field as 0 is exactly how the zero-cost bug hid.
  cost="$(printf '%s' "${trace}" | jq -r '
    [ (.observations // [])[]?
      | (.calculatedTotalCost // .totalCost // .usageDetails.total_cost
         // .costDetails.total // .metadata.litellm_response_cost) ]
    | map(select(. != null)) | add // "ABSENT"')"
  group="$(printf '%s' "${trace}" | jq -r '
    ((.tags // []) | map(select(startswith("model_group:"))) | .[0] // "")
    | sub("^model_group:"; "") | if . == "" then "ABSENT" else . end')"

  if [ "${cost}" = "ABSENT" ]; then
    printf '%-12s %-34s %s\n' "${provider}" "${model}" "FAIL: no cost field recognised in trace"
    # bash substring, not `| head -c`: same SIGPIPE-under-pipefail trap, and
    # here it would abort precisely when there is a failure to report.
    printf '%s\n' "${trace:0:400}" >&2
    rc=1; continue
  fi

  problems=""
  # The label check: model_group is the name the CALLER used, which is what
  # makes per-vendor attribution possible at all (the model field is the
  # dispatch string and reads "openai/..." for custom providers).
  if [ "${group}" != "${model}" ]; then
    problems="model_group is '${group}', called '${model}'"
  fi
  verdict="$(compare_cost "${in_cost}" "${out_cost}" "${ptok}" "${ctok}" "${cost}")"
  case "${verdict}" in
    MISMATCH:*) problems="${problems:+${problems}; }${verdict#MISMATCH:}" ;;
  esac

  if [ -n "${problems}" ]; then
    printf '%-12s %-34s %s\n' "${provider}" "${model}" "FAIL: ${problems}"
    rc=1
  else
    printf '%-12s %-34s %s\n' "${provider}" "${model}" "ok (${verdict#OK:})"
  fi
done < "${sent}"

echo
if [ "${rc}" -ne 0 ]; then
  echo "70-verify-tracing: FAILED — Langfuse disagrees with this box's config" >&2
  exit 1
fi
echo "70-verify-tracing: OK (Langfuse matches /model/info for every provider)"
