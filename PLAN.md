---
status: draft
---

# lavasec-base — minimal VM base: pi + repo sync + local LLM gateway

Goal: one small repo that turns a fresh Oracle Cloud free-tier VM into a working
agent box — pi installed, lavasecurity repos synced, and a local OpenAI-compatible
gateway (LiteLLM) that owns all provider credentials, so pi only ever talks to
`127.0.0.1`.

Architecture, one line:

    pi → http://127.0.0.1:4000/v1 (LiteLLM, master-key auth) → Anthropic / OpenAI / …

## Slices

**S1 — scaffold (shipped)**
Repo layout, plan, config templates, stub scripts.

**S2 — gateway up (shipped)**
`10-system.sh` (base packages, python3 venv, node) + `30-gateway.sh` (litellm in a
venv, systemd unit, `/etc/lavasec/lavasec.env` root:600).
Done when: `curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" 127.0.0.1:4000/v1/models`
lists models, and port 4000 is unreachable from outside the VM.

**S3 — git auth + sync (shipped)**
`20-git.sh`: org git identity on the VM, HTTPS + one fine-grained read-only
PAT (decision 1 resolved), clone/pull every repo in `config/repos.txt` into
`~/src`. Done when: with the token installed, a fresh run clones everything
listed; a re-run only pulls (idempotent); a missing/insufficient token fails
loudly with setup instructions.

**S4 — pi wired to gateway (this PR)**
`40-pi.sh`: install pi, install the `config/pi/` gateway extension, verify.
Done when: `pi --list-models` shows the gateway models and a one-shot prompt
round-trips through LiteLLM.

**S5 — backlog (optional)**
ufw explicit deny-in, unattended-upgrades, litellm log rotation.

## Obligations

- Secrets on the VM live in exactly three files, each mode 600, and nowhere
  else: `/etc/lavasec/lavasec.env` (root:root — gateway/provider credentials,
  read by the litellm service), `~/.config/lavasec/github-token` (user — the
  read-only git PAT), and `~/.config/lavasec/gateway-key` (user — the gateway
  client key, derived from the root env by 40-pi.sh for pi and other local
  clients). Privilege domains stay separate: root holds provider keys; the
  user holds only what its own processes present. The repo carries
  `env/example.env` only.
- Gateway binds `127.0.0.1` exclusively; OCI security list stays SSH-only.
- Every script idempotent — `bootstrap.sh` must be re-runnable after a partial failure.
- pi extension discovery path CONFIRMED (pi.dev/docs/latest/extensions):
  global `~/.pi/agent/extensions/*.ts`, TypeScript loaded natively via jiti.

## Open decisions

1. **Git auth on the VM** — RESOLVED (S3, owner calls 2026-07-29): HTTPS with
   one fine-grained read-only PAT, repository access **All repositories**
   (Contents: Read-only) — this box mirrors the whole org by design, so
   `config/repos.txt` is the explicit sync inventory and the token needs no
   per-repo maintenance. Deploy keys were implemented first and worked, but
   are 1:1 per repo. OAuth user tokens rejected: account-wide read/write,
   cannot be narrowed.
2. **Gateway choice** — LiteLLM recommended: single pip install, no database needed
   in env-key mode, OpenAI-compatible surface, all provider keys in one place.
   Alternatives considered: Portkey Gateway, Bifrost (heavier, or less proven for
   this exact single-box shape).
3. **VM shape** — A1.Flex ARM (4 OCPU / 24 GB) assumed; on the 1 GB AMD micro the
   LiteLLM python proxy is tight.
4. **Anthropic-native features** — via the gateway pi uses the OpenAI-compatible
   surface. If we later want native Anthropic features (prompt caching, thinking),
   use LiteLLM's `/anthropic` passthrough or put `ANTHROPIC_API_KEY` directly on
   the VM for pi. Not needed for v0.
