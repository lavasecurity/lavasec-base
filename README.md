# 🌋 lavasec-base

[![ci](https://github.com/lavasecurity/lavasec-base/actions/workflows/ci.yml/badge.svg)](https://github.com/lavasecurity/lavasec-base/actions/workflows/ci.yml)
[![security](https://github.com/lavasecurity/lavasec-base/actions/workflows/security.yml/badge.svg)](https://github.com/lavasecurity/lavasec-base/actions/workflows/security.yml)
![platform](https://img.shields.io/badge/platform-Ubuntu%2024.04%20·%20arm64%20%7C%20x86__64-E95420)
![free tier](https://img.shields.io/badge/runs%20on-Oracle%20Always%20Free-2f6db3)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Turn a free-tier cloud VM into a self-contained AI agent box with one command:
**[pi](https://pi.dev)** as the coding agent, **git** keeping your repos fresh,
and a local **[LiteLLM](https://docs.litellm.ai)** gateway that owns every
LLM-provider credential.

```
pi ──▶ http://127.0.0.1:4000/v1 (LiteLLM gateway) ──▶ Anthropic · OpenAI · DeepSeek · OpenRouter · …
```

Provider keys live in one root-owned file on the VM. pi — and any other local
tool — only ever talks to the loopback gateway. Nothing else, nowhere else.

## ✨ What you get

- 🤖 **pi wired to the gateway** — one local endpoint, models from every provider you configure
- 🔁 **repos that keep themselves fresh** — cloned into `~/src/` with a read-only fine-grained PAT
- 🔑 **one place for every key** — add or rotate a provider credential by editing one line and restarting one service
- 🧱 **loopback-only by construction** — the gateway binds `127.0.0.1` and bootstrap verifies it; pair with an SSH-only cloud security list and nothing else is reachable
- ♻️ **idempotent bootstrap** — re-run it any time; it repairs instead of breaking, and fails loudly with instructions when something needs you

## 🚀 Quickstart (on the VM)

Assumes Ubuntu 24.04 (Oracle free tier, A1.Flex or AMD), default user with sudo.

```bash
git clone https://github.com/lavasecurity/lavasec-base.git
cd lavasec-base
sudo install -m 600 -D env/example.env /etc/lavasec/lavasec.env
sudoedit /etc/lavasec/lavasec.env   # fill in real keys
./bootstrap.sh
```

The last step of bootstrap proves the whole chain with a real completion:
`pi → gateway → provider → "LAVA-GATEWAY-OK"`.

## 🗺️ Layout

| path | what |
|---|---|
| `bootstrap.sh` | runs `scripts/` in order; idempotent |
| `scripts/10-system.sh` | base packages (git, python3+venv, node 22) |
| `scripts/20-git.sh` | git identity, auth, sync repos from `config/repos.txt` |
| `scripts/30-gateway.sh` | LiteLLM install + hardened systemd service |
| `scripts/40-pi.sh` | pi install + gateway provider extension + live round-trip check |
| `config/litellm.yaml` | gateway model routes (keys via env, never inline) |
| `config/pi/` | pi extension registering the local gateway |
| `config/repos.txt` | repos to sync |
| `systemd/litellm.service` | unit template |
| `env/example.env` | secret template — real values live only on the VM |

## ➕ Adding a repo to sync

1. Add `org/name` to `config/repos.txt` — or, for private/box-specific
   entries, to `config/repos.local.txt` (gitignored, same format; the sync
   PAT covers all org repos either way).
2. Run `./bootstrap.sh` — it clones into `~/src/`. A missing or invalid
   token fails loudly with setup instructions.

## 🔑 Adding or rotating a provider key

```bash
sudoedit /etc/lavasec/lavasec.env
sudo systemctl restart litellm
```

That's the whole ceremony. Clients never notice — they only hold the local
gateway key.

---

See [PLAN.md](PLAN.md) for the slice-by-slice build history and design decisions.
