# Changelog

Tags mark states verified end-to-end **on a real box**, not merely CI-green —
CI cannot reach the tailnet slices (`50`/`60`/`65`) or the Langfuse path, so a
green build alone is not a promise that a fresh install works. `main` is the
moving edge; check out a tag if you want a known-good starting point.

Tagged opportunistically, with no release cadence. This file starts here rather
than reconstructing earlier history.

## Unreleased

- Reconciliation gate (`scripts/70-verify-tracing.sh`): sends one minimal probe
  per configured provider, fetches that exact trace back from Langfuse by id,
  and fails if the trace is missing, if its `model_group` tag disagrees with the
  model called, or if its cost contradicts `/model/info`. A provider that
  publishes no pricing is expected to report zero. Skips when tracing is off.
- Langfuse traces are tagged `model_group:<name you called>`, so spend can be
  attributed per vendor. Langfuse's own `model` field is the routing string, so
  a custom OpenAI-compatible endpoint appears as `openai/<id>` — the protocol
  adapter, not the vendor.
- `e2e` workflow: runs the bootstrap chain for real on a throwaway
  `ubuntu-24.04` runner against a mock provider, with no credentials. Covers
  every numbered slice except the three needing a live tailnet. Now a required
  check.
- Privileged `npm`/`node` calls run as root with root's own home *and* config
  dir. `sudo -H` alone was insufficient: `XDG_CONFIG_HOME` survives sudo, and
  opencode honours it over `HOME`, which left a root-owned `~/.config/opencode`
  and broke the slice on every fresh box.
- `55-opencode.sh` passes the model catalog to `jq` via `--slurpfile` instead of
  `--argjson`. A single argv string is capped at 128 KiB on Linux, which the
  catalog crosses past roughly 500 models with realistic ids.
- Verification checks use here-strings instead of `printf | grep -q`, which
  returns 141 under `pipefail` once output exceeds the pipe buffer and so
  reported success as failure.
