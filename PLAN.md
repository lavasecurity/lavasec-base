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

**S4 — pi wired to gateway (shipped)**
`40-pi.sh`: install pi, install the `config/pi/` gateway extension, verify.
Done when: `pi --list-models` shows the gateway models and a one-shot prompt
round-trips through LiteLLM.

**C1 — tailscale (this PR)**
`50-tailscale.sh`: overlay access with zero new cloud ingress (outbound
WireGuard); joining the tailnet is one-time owner-interactive, loud-fail
until done. Done when: `tailscale status` is Running, and an external scan
of the public IP still shows only port 22.

**C2 — OpenCode harness via the gateway (55-opencode.sh) — shipped**
T3 Code (pingdotgg/t3code — the web/mobile UI, owner's pick 2026-07-29,
replacing the earlier bespoke-console idea) drives agent-harness CLIs, not
model APIs. OpenCode is the supported harness whose provider config takes
a custom OpenAI-compatible endpoint, so it is the invariant-preserving
bridge: install OpenCode, register the loopback gateway as its provider
(key from `~/.config/lavasec/gateway-key`). Done when an opencode one-shot
round-trips through the gateway. pi stays as the direct-CLI agent (not in
T3 Code's harness list today).

**C3 — T3 Code on the tailnet (60-t3code.sh) — shipped**
`t3 serve` as a systemd unit bound to the TAILNET interface (100.x), never
loopback-only, never 0.0.0.0: reachable by your tailnet devices, closed to
the internet. Tailscale Serve (HTTPS) requires a one-time tailnet-wide
admin-console enable, so it stays an optional upgrade the script prints
rather than a gate on bootstrap. node-pty has no linux prebuilds — that
single native module is built deliberately (`--ignore-scripts` still
applies to everything else). Pairing token surfaced from the journal.
State: `~/.t3` (SQLite). Done: verified reachable from a paired device,
public IP still exposes only 22.

**C4 — OpenCode web UI (65-opencode-web.sh) — shipped**
`opencode web` on the tailnet (:4096), same posture as C3: tailnet-bound,
wildcard-refused, HTTP readiness, restart-only-when-changed. A second
control surface over the same gateway-wired harness — if it proves
sufficient on mobile, T3 Code becomes optional and the two-harness split
collapses. (`--mdns` deliberately unused: it defaults the bind to
0.0.0.0.)

**C5 — n8n workflow orchestration (75-n8n.sh) — shipped**
n8n on the tailnet (:5678), same posture as C3/C4: tailnet-bound,
wildcard-refused, HTTP readiness, restart-only-when-changed. SQLite-backed
(no Postgres, no Docker — a single Node.js process, ~200 MB RAM). Replaces
the systemd timers as the VISUAL trigger + lineage layer for agent drains:
n8n's Schedule Trigger nodes fire `agent-dispatch.sh` on a cadence, and the
n8n dashboard shows run history, duration, and output per workflow. The
agent contracts, dispatch script, gateway, and opencode runtime stay
unchanged — n8n is the trigger + observability layer, not the execution
layer. Auth is NOT basic auth: n8n 1.0 removed `N8N_BASIC_AUTH_*` (verified
— zero references in the 2.32.6 package), so the only app-level control is
n8n's own owner account, which cannot be provisioned from a script. The
tailnet bind is therefore the real boundary, and the script reports whether
the owner account has been claimed instead of asserting protection it does
not have.

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
   (Contents + Pull requests: Read-only — Contents alone clones but 403s
   on private-repo PR reads, verified) — this box mirrors the org, so
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
4. **Web-UI authentication** — RESOLVED (owner, 2026-07-29): keep HTTP
   basic auth on the OpenCode web UI (`OPENCODE_SERVER_PASSWORD`,
   generated into `~/.config/lavasec/opencode-web-password`). Basic auth
   is the only mechanism OpenCode's server supports — no token, cookie,
   or prompt-suppression option — so the browser popup is the cost of
   defence-in-depth over the tailnet. The bind guard refuses to leave an
   unauthenticated server running.
5. **Anthropic-native features** — via the gateway pi uses the OpenAI-compatible
   surface. If we later want native Anthropic features (prompt caching, thinking),
   use LiteLLM's `/anthropic` passthrough or put `ANTHROPIC_API_KEY` directly on
   the VM for pi. Not needed for v0.
