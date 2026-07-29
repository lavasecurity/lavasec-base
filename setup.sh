#!/usr/bin/env bash
set -euo pipefail
# Interactive first-run wizard: walks a fresh VM from clone to a verified
# box, one step at a time. Every step keeps existing state (re-run safe),
# secrets are read without echo and never printed, and everything here can
# also be done manually — see README. bootstrap.sh stays the
# non-interactive core; this is just the guided path to it.

cd "$(dirname "$0")" || exit 1

if [ "$(id -u)" -eq 0 ]; then
  echo "setup: run as the normal user — it sudoes only where needed" >&2
  exit 1
fi

say() { printf '\n== %s\n' "$*"; }

ENV_FILE=/etc/lavasec/lavasec.env
TOKEN_FILE="${HOME}/.config/lavasec/github-token"

say "Step 1/4 — provider keys → ${ENV_FILE}"
if sudo test -s "${ENV_FILE}"; then
  echo "   exists — keeping it (edit later: sudoedit ${ENV_FILE})"
else
  master="sk-$(openssl rand -hex 24)"
  echo "   Generated the local gateway master key."
  echo "   Paste provider API keys (input hidden; Enter to skip any):"
  read -rsp "   DEEPSEEK_API_KEY: " k_ds; echo
  read -rsp "   OPENROUTER_API_KEY: " k_or; echo
  read -rsp "   ANTHROPIC_API_KEY: " k_an; echo
  read -rsp "   OPENAI_API_KEY: " k_oa; echo
  read -rsp "   NEURALWATT_API_KEY: " k_nw; echo
  read -rsp "   OPENCODE_API_KEY: " k_oc; echo
  if [ -z "${k_ds}${k_or}${k_an}${k_oa}${k_nw}${k_oc}" ]; then
    echo "   at least one provider key is required — get one and re-run" >&2
    exit 1
  fi
  printf 'LITELLM_MASTER_KEY=%s\nANTHROPIC_API_KEY=%s\nOPENAI_API_KEY=%s\nOPENROUTER_API_KEY=%s\nDEEPSEEK_API_KEY=%s\nOPENCODE_API_KEY=%s\nNEURALWATT_API_KEY=%s\n' \
    "${master}" "${k_an}" "${k_oa}" "${k_or}" "${k_ds}" "${k_oc}" "${k_nw}" \
    | sudo install -m 600 -D /dev/stdin "${ENV_FILE}"
  echo "   written (root:root, 600)."
fi

say "Step 2/4 — GitHub sync token → ${TOKEN_FILE}"
if [ -s "${TOKEN_FILE}" ]; then
  echo "   exists — keeping it"
else
  echo "   Create a fine-grained PAT: github.com → Settings → Developer"
  echo "   settings → Fine-grained tokens. Repository access: the repos in"
  echo "   config/repos.txt (or All). Permissions: Contents = Read-only."
  read -rsp "   Paste token (input hidden; Enter to skip repo sync): " tok; echo
  if [ -n "${tok}" ]; then
    mkdir -p "$(dirname "${TOKEN_FILE}")"
    (umask 077 && printf %s "${tok}" > "${TOKEN_FILE}")
    echo "   written (600)."
  else
    echo "   skipped — the repo-sync step of bootstrap will fail with"
    echo "   instructions until a token is installed."
  fi
fi

say "Step 3/4 — tailnet (optional; needed only for the web console)"
ts_state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null || echo NotInstalled)"
if [ "${ts_state}" = "Running" ]; then
  echo "   already on a tailnet — keeping it"
else
  read -rp "   Join a tailnet now? [y/N] " yn
  case "${yn}" in
    [Yy]*)
      bash scripts/50-tailscale.sh || true
      echo "   Approve the URL below in your browser, then setup continues."
      sudo tailscale up
      ;;
    *)
      echo "   skipped — the tailscale step of bootstrap will fail with"
      echo "   instructions; everything else still comes up."
      ;;
  esac
fi

say "Step 4/4 — bootstrap (idempotent; re-run anytime)"
./bootstrap.sh

say "Done. Try:  pi   (new shell; defaults to the gateway's verified model)"
