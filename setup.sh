#!/usr/bin/env bash
set -euo pipefail
# Interactive first-run wizard: walks a fresh VM from clone to a verified
# box, one step at a time. Every step keeps existing state (re-run safe),
# secrets are read without echo and never printed, and everything here can
# also be done manually — see README. bootstrap.sh stays the
# non-interactive core; this is just the guided path to it.

# readlink -f: work even when setup.sh is invoked via a symlink
cd "$(dirname "$(readlink -f "$0")")" || exit 1

if [ "$(id -u)" -eq 0 ]; then
  echo "setup: run as the normal user — it sudoes only where needed" >&2
  exit 1
fi

say() { printf '\n== %s\n' "$*"; }

# hidden-input prompt; strips ALL whitespace so space-mashed input can't
# masquerade as a key
ask_key() {
  local v
  read -rsp "   $2: " v
  echo
  printf -v "$1" '%s' "${v//[[:space:]]/}"
}

ENV_FILE=/etc/lavasec/lavasec.env
TOKEN_FILE="${HOME}/.config/lavasec/github-token"

say "Step 1/4 — provider keys → ${ENV_FILE}"
if sudo test -s "${ENV_FILE}"; then
  echo "   exists — keeping it (edit later: sudoedit ${ENV_FILE})"
else
  master="sk-$(openssl rand -hex 24)"
  echo "   Generated the local gateway master key."
  echo "   Paste provider API keys (input hidden; Enter to skip any):"
  ask_key k_ds DEEPSEEK_API_KEY
  ask_key k_or OPENROUTER_API_KEY
  ask_key k_an ANTHROPIC_API_KEY
  ask_key k_oa OPENAI_API_KEY
  ask_key k_nw NEURALWATT_API_KEY
  ask_key k_oc OPENCODE_API_KEY
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
  echo "   config/repos.txt (or All). Permissions: Contents = Read-only"
  echo "   AND Pull requests = Read-only (for gh / the web console)."
  read -rsp "   Paste token (input hidden; Enter to skip repo sync): " tok; echo
  tok="${tok//[[:space:]]/}"  # clipboard paste often carries a trailing newline/space
  if [ -n "${tok}" ]; then
    mkdir -p "$(dirname "${TOKEN_FILE}")"
    (umask 077 && printf '%s\n' "${tok}" > "${TOKEN_FILE}")
    chmod 600 "${TOKEN_FILE}"  # umask covers new files only; enforce on pre-existing too
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
      # prerequisites first (idempotent): a minimal image may lack curl/jq,
      # and the tailscale step needs both
      bash scripts/10-system.sh
      # exit 1 here is EXPECTED pre-login (NeedsLogin); a real install
      # failure is caught by the binary check below
      bash scripts/50-tailscale.sh || true
      if ! command -v tailscale >/dev/null; then
        echo "   tailscale install failed — see output above" >&2
        exit 1
      fi
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
