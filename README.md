# lavasec-base

Minimal base for spinning up a LavaSecurity agent VM (Oracle Cloud free tier):

1. **pi** — coding-agent harness
2. **git** — auth + sync of lavasecurity repos
3. **LiteLLM gateway** — one local endpoint (`127.0.0.1:4000`) owning all
   LLM-provider credentials

pi talks only to the local gateway; provider keys never leave the VM's env file.

## Quickstart (on the VM)

Assumes Ubuntu 24.04 (Oracle free tier, A1.Flex or AMD), default user with sudo.

```bash
git clone https://github.com/lavasecurity/lavasec-base.git
cd lavasec-base
sudo install -m 600 -D env/example.env /etc/lavasec/lavasec.env
sudoedit /etc/lavasec/lavasec.env   # fill in real keys
./bootstrap.sh
```

## Layout

| path | what |
|---|---|
| `bootstrap.sh` | runs `scripts/` in order; idempotent |
| `scripts/10-system.sh` | base packages (git, python3+venv, node 22) |
| `scripts/20-git.sh` | git identity, auth, sync repos from `config/repos.txt` |
| `scripts/30-gateway.sh` | LiteLLM install + systemd service |
| `scripts/40-pi.sh` | pi install + gateway provider extension |
| `config/litellm.yaml` | gateway model list (keys via env, never inline) |
| `config/pi/` | pi extension registering the local gateway |
| `config/repos.txt` | repos to sync |
| `systemd/litellm.service` | unit template |
| `env/example.env` | secret template — real values live only on the VM |

## Adding a repo to sync

1. Add `org/name` to `config/repos.txt` — or, for private/box-specific
   entries, to `config/repos.local.txt` (gitignored, same format; the sync
   PAT covers all org repos either way).
2. Run `./bootstrap.sh` — it clones into `~/src/`. A missing or invalid
   token fails loudly with setup instructions.

See [PLAN.md](PLAN.md) for slices and open decisions.
