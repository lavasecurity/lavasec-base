#!/usr/bin/env bash
set -uo pipefail
# No -e on purpose: run every step, report every failure at the end, so a
# fresh box surfaces all its problems in one pass (missing env file AND
# unregistered deploy keys, not one at a time).
cd "$(dirname "$0")" || exit 1

# Identify this checkout on the FIRST line, so any pasted bootstrap output
# self-identifies without asking "which version are you on". Derived from git
# rather than a VERSION file, which would silently drift; `--dirty` flags local
# edits, and `--always` still yields a short SHA when no tag is reachable.
# Falls back to "unknown" for a tarball download with no .git.
echo "lavasec-base $(git describe --tags --always --dirty 2>/dev/null || echo unknown)"

rc=0
for s in scripts/[0-9]*.sh; do
  echo "==> ${s}"
  if ! bash "${s}"; then
    echo "==> ${s} FAILED" >&2
    rc=1
  fi
done

if [ "${rc}" -ne 0 ]; then
  echo "bootstrap: one or more steps FAILED" >&2
  exit 1
fi
echo "bootstrap complete"
