#!/usr/bin/env bash
set -euo pipefail
# pi coding agent wired to the local gateway. Installs pi globally
# (--ignore-scripts: no npm lifecycle scripts from the dep tree), derives
# the gateway client key into the user secret domain, installs the
# lava-gateway extension into pi's global discovery path, then verifies
# pi can see the gateway models.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE=/etc/lavasec/lavasec.env
KEY_FILE="${HOME}/.config/lavasec/gateway-key"
EXT_DIR="${HOME}/.pi/agent/extensions"

# sudo -H, not bare sudo: Ubuntu's sudo PRESERVES HOME, so root's npm cache
# and any config a package writes land root-owned in THIS user's home and
# break later unprivileged writes there. -H points root at /root instead.
sudo -H npm install -g --ignore-scripts @earendil-works/pi-coding-agent >/dev/null

# client key: the master key is the gateway's CLIENT credential too; pi runs
# as this user, so it gets a user-domain 600 copy (root env stays root-only).
mkdir -p "$(dirname "${KEY_FILE}")"
key="$(sudo sh -c ". ${ENV_FILE} && printf %s \"\${LITELLM_MASTER_KEY}\"")"
# write only on change: services fingerprint this file's mtime to detect
# credential rotation, so rewriting an identical key would restart them
# (and rotate T3 Code's pairing token) on every bootstrap
if [ ! -f "${KEY_FILE}" ] || [ "$(cat "${KEY_FILE}")" != "${key}" ]; then
  (umask 077 && printf %s "${key}" > "${KEY_FILE}")
fi
chmod 600 "${KEY_FILE}"

# export for interactive shells (idempotent marker block)
if ! grep -qs "lavasec-base gateway key" "${HOME}/.bashrc"; then
  {
    echo "# lavasec-base gateway key"
    echo "export LITELLM_MASTER_KEY=\"\$(cat ${KEY_FILE})\""
  } >> "${HOME}/.bashrc"
fi

mkdir -p "${EXT_DIR}"
install -m 644 "${REPO_DIR}/config/pi/lava-gateway.ts" "${EXT_DIR}/lava-gateway.ts"

# extension discovery check — static registration only, NOT proof of a
# working path (that's the round-trip below)
# provider-agnostic: any lava-gateway row proves the extension registered;
# which SPECIFIC model works is the round-trip check's job below
pi_models=$(LITELLM_MASTER_KEY="$(cat "${KEY_FILE}")" pi --list-models 2>&1) || true
# here-string, NOT a pipe: `printf | grep -q` returns 141 under pipefail
# once output is large enough that printf is still writing when grep exits
if ! grep -q "lava-gateway" <<< "${pi_models}"; then
  echo "40-pi: no lava-gateway models visible in pi --list-models:" >&2
  printf '%s\n' "${pi_models}" | tail -5 >&2
  exit 1
fi

# round-trip: a real completion pi → gateway → provider. The check route is
# picked from whichever provider key is actually configured (PI_CHECK_MODEL
# overrides); a box with no provider key at all cannot meet the S4
# round-trip criterion and fails explicitly.
if [ -z "${PI_CHECK_MODEL:-}" ]; then
  PI_CHECK_MODEL="$(sudo sh -c ". ${ENV_FILE} && \
    if   [ -n \"\${DEEPSEEK_API_KEY:-}\" ];   then echo deepseek/deepseek-chat; \
    elif [ -n \"\${OPENROUTER_API_KEY:-}\" ]; then echo openrouter/openai/gpt-4o-mini; \
    elif [ -n \"\${NEURALWATT_API_KEY:-}\" ]; then echo neuralwatt/qwen3.6-35b; \
    elif [ -n \"\${ANTHROPIC_API_KEY:-}\" ];  then echo anthropic/claude-haiku-4-5; \
    elif [ -n \"\${OPENAI_API_KEY:-}\" ];     then echo openai/gpt-4o-mini; \
    elif [ -n \"\${OPENCODE_API_KEY:-}\" ];   then echo opencode/gpt-5.5; fi")"
  # Ollama Cloud publishes no fixed ids we can assume — take the first one
  # the gateway actually routes
  if [ -z "${PI_CHECK_MODEL}" ] && sudo sh -c ". ${ENV_FILE} && [ -n \"\${OLLAMA_API_KEY:-}\" ]"; then
    cfg="$(mktemp)"; chmod 600 "${cfg}"
    cat > "${cfg}" <<EOF
header = "Authorization: Bearer $(cat "${KEY_FILE}")"
EOF
    PI_CHECK_MODEL="$(curl -fsS --max-time 10 -K "${cfg}" http://127.0.0.1:4000/model/info 2>/dev/null \
      | jq -r '[.data[].model_name | select(startswith("ollama/"))][0] // empty' 2>/dev/null || true)"
    rm -f "${cfg}"
  fi
fi
if [ -z "${PI_CHECK_MODEL}" ]; then
  echo "40-pi: no provider API key configured in ${ENV_FILE} — cannot verify a round-trip. Add at least one provider key and re-run." >&2
  exit 1
fi
# success = pi exits 0 AND the sentinel appears — the prompt itself contains
# the sentinel, so output alone could false-pass on an echoed error
if reply=$(LITELLM_MASTER_KEY="$(cat "${KEY_FILE}")" pi --provider lava-gateway \
      --model "${PI_CHECK_MODEL}" --no-session -p "Reply with exactly: LAVA-GATEWAY-OK" 2>&1) \
    && grep -q "LAVA-GATEWAY-OK" <<< "${reply}"; then
  echo "40-pi: OK (pi installed, ${PI_CHECK_MODEL} round-trip verified)"
else
  echo "40-pi: round-trip via ${PI_CHECK_MODEL} FAILED:" >&2
  printf '%s\n' "${reply}" | tail -5 >&2
  exit 1
fi

# bare-`pi` defaults for interactive shells: provider pinned to the gateway,
# default model = the round-trip model verified above; user flags override
# (later flags win). The block is REPLACED on every run so the default
# tracks whichever provider keys this box currently has.
# --follow-symlinks: a dotfiles-managed (symlinked) .bashrc must keep
# pointing at its target, not be replaced by a regular file
sed -i --follow-symlinks '/^# >>> lavasec-base pi defaults >>>$/,/^# <<< lavasec-base pi defaults <<<$/d' "${HOME}/.bashrc"
{
  echo "# >>> lavasec-base pi defaults >>>"
  echo "pi() { command pi --provider lava-gateway --model ${PI_CHECK_MODEL} \"\$@\"; }"
  echo "# <<< lavasec-base pi defaults <<<"
} >> "${HOME}/.bashrc"
