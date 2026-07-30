# lavasec-base

[![ci](https://github.com/lavasecurity/lavasec-base/actions/workflows/ci.yml/badge.svg)](https://github.com/lavasecurity/lavasec-base/actions/workflows/ci.yml)
[![e2e](https://github.com/lavasecurity/lavasec-base/actions/workflows/e2e.yml/badge.svg)](https://github.com/lavasecurity/lavasec-base/actions/workflows/e2e.yml)
[![security](https://github.com/lavasecurity/lavasec-base/actions/workflows/security.yml/badge.svg)](https://github.com/lavasecurity/lavasec-base/actions/workflows/security.yml)
![platform](https://img.shields.io/badge/platform-Ubuntu%2024.04%20·%20arm64%20%7C%20x86__64-E95420)
![free tier](https://img.shields.io/badge/runs%20on-Oracle%20Always%20Free-2f6db3)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Stages LLM-provider access on a fresh VM — nothing more, nothing less:
**[pi](https://pi.dev)** as the coding agent, **git** keeping your repos in
sync, and a **[LiteLLM](https://docs.litellm.ai)** gateway on loopback that
holds every provider credential. One idempotent bootstrap.

```
pi ──▶ http://127.0.0.1:4000/v1 (LiteLLM gateway) ──▶ Anthropic · OpenAI · DeepSeek · OpenRouter · …
```

Provider keys live in one root-owned file on the VM. pi — and any other local
tool — only ever talks to the loopback gateway.

## What you get

- **pi wired to the gateway** — one local endpoint; `config/litellm.yaml` is the curated model catalog and pi mirrors it automatically
- **repos that keep themselves fresh** — cloned into `~/src/` with a read-only fine-grained PAT
- **one place for every key** — add or rotate a provider credential by editing one line and restarting one service
- **loopback-only by construction** — the gateway binds `127.0.0.1` and bootstrap verifies it; pair with an SSH-only cloud security list and nothing else is reachable
- **idempotent bootstrap** — re-run it any time; it repairs instead of breaking, and fails loudly with instructions when something needs you

## From zero

Any Ubuntu 24.04 VM works (Oracle free tier A1.Flex is the tested
reference). At creation time you need exactly three things: your SSH
public key, a public IP, and a security list that allows **SSH only** —
everything else stays closed forever.

## Quickstart (on the VM)

Guided — the wizard walks keys → sync token → tailnet → bootstrap, keeps
anything that already exists, and never echoes a secret:

```bash
sudo apt-get update -q && sudo apt-get install -y git   # minimal images lack git
git clone https://github.com/lavasecurity/lavasec-base.git
cd lavasec-base
./setup.sh
```

Manual, if you prefer doing the same by hand:

```bash
sudo install -m 600 -D env/example.env /etc/lavasec/lavasec.env
sudoedit /etc/lavasec/lavasec.env   # fill in real keys
./bootstrap.sh
```

The last step of bootstrap proves the whole chain with a real completion:
`pi → gateway → provider → "LAVA-GATEWAY-OK"`. After that, a bare `pi` in any
new shell defaults to the gateway and the verified model — your own
`--provider`/`--model` flags override.

## Layout

| path | what |
|---|---|
| `setup.sh` | interactive first-run wizard (keys → token → tailnet → bootstrap) |
| `bootstrap.sh` | runs `scripts/` in order; idempotent |
| `scripts/10-system.sh` | base packages (git, python3+venv, node 22) |
| `scripts/20-git.sh` | git identity, auth, sync repos from `config/repos.txt` |
| `scripts/30-gateway.sh` | LiteLLM install + hardened systemd service |
| `scripts/40-pi.sh` | pi install + gateway provider extension + live round-trip check |
| `scripts/50-tailscale.sh` | tailnet access, zero new cloud ingress (one-time device approval) |
| `scripts/55-opencode.sh` | OpenCode harness wired to the gateway (T3 Code's agent backend) |
| `scripts/60-t3code.sh` | T3 Code (`t3 serve`) web/mobile UI on the tailnet |
| `scripts/65-opencode-web.sh` | OpenCode's own web UI on the tailnet (second surface) |
| `scripts/70-verify-tracing.sh` | reconciles what Langfuse recorded against `/model/info` (skips when tracing is off) |
| `scripts/75-n8n.sh` | n8n on the tailnet — visual trigger + run history for scheduled agent work |
| `ci/mock-provider.py` | mock OpenAI-compatible provider so CI runs the real chain with no real keys |
| `config/litellm.yaml` | gateway model routes (keys via env, never inline) |
| `config/pi/` | pi extension registering the local gateway |
| `config/repos.txt` | repos to sync |
| `systemd/litellm.service` | unit template |
| `env/example.env` | secret template — real values live only on the VM |

## What CI checks

`ci` is static: `bash -n`, shellcheck, config sanity, and two structural guards
(no credential-bearing `curl` options, no secret-shaped strings).

`e2e` runs the chain for real on a throwaway Ubuntu 24.04 runner — because
static analysis cannot see runtime behaviour, and shellcheck does not flag the
`printf | grep -q` + `pipefail` false negative that once reached `main` green.
A mock provider (`ci/mock-provider.py`) plugs into the `OLLAMA_BASE` override,
so no real credentials are involved and fork PRs work unchanged. It also
asserts at runtime what the static guards can only infer from source: the
gateway is loopback-only, the catalog round-trips a sentinel, and no credential
ever appeared in a process command line.

Not covered: `50-tailscale`, `60-t3code`, `65-opencode-web` and `75-n8n` need a
live tailnet, which a hosted runner has no way to join. Those stay
owner-verified on the box. The run list is derived, so a newly added slice is
included automatically rather than silently skipped — `75-n8n` failed `chain`
on arrival for exactly that reason, which is the guard working.

## Adding a repo to sync

1. Add `org/name` to `config/repos.txt` — or, for private/box-specific
   entries, to `config/repos.local.txt` (gitignored, same format; the sync
   PAT covers all org repos either way).
2. Run `./bootstrap.sh` — it clones into `~/src/`. A missing or invalid
   token fails loudly with setup instructions.

## Adding or rotating a provider key

```bash
sudoedit /etc/lavasec/lavasec.env
bash scripts/30-gateway.sh
```

`30-gateway.sh` re-renders the catalog for the keys you now have,
restarts the service, and re-verifies it — required when *adding* a
provider's first key, and harmless for a plain rotation. Clients never
notice — they only hold the local gateway key.

## Tracing (optional)

Add `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, and `LANGFUSE_HOST` to
`/etc/lavasec/lavasec.env` and re-run `bash scripts/30-gateway.sh`. Because
every client reaches providers through the gateway, instrumenting it once
traces them all — pi, opencode, and the web UIs — with no client-side SDK.
Leave the keys empty and nothing is installed or sent.

Reading the traces: Langfuse's **model** field is the routing string, not the
name you called. Providers LiteLLM supports natively show their own prefix
(`openrouter/…`), but an OpenAI-compatible endpoint it has no provider for is
dispatched as `openai/<id>` — so a Neuralwatt call appears as
`openai/glm-5.2`. That is the protocol adapter, not the vendor; the request
went to Neuralwatt. Every trace is tagged `model_group:<the name you called>`,
so filter or group by that tag for true per-vendor attribution — necessary
once a real `OPENAI_API_KEY` exists, since native OpenAI routes would
otherwise share the same `openai/` namespace.

`scripts/70-verify-tracing.sh` keeps the two sides honest: it sends one
minimal probe per configured provider, fetches that exact trace back by id,
and fails if the trace is missing, if its `model_group` tag disagrees with the
model you called, or if its cost contradicts the price in `/model/info`. A
provider that publishes no pricing is expected to report zero, so that case
passes rather than crying wolf. It runs as part of `bootstrap.sh` and skips
silently when tracing is off.

## Adding a model

Keyed native providers use wildcards (`openrouter/*`), so their catalogs
list dynamically and *any* provider slug routes through — even unlisted
ones. Explicit `config/litellm.yaml` entries are only needed for custom
OpenAI-compatible endpoints and models too new for litellm's DB (see the
comments there), then re-run `bash scripts/30-gateway.sh`. The gateway,
`/model/info`, and pi's model list all update together.

---

See [PLAN.md](PLAN.md) for the slice-by-slice build history and design decisions.
