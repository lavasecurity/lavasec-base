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
#
# The `.git` test is not redundant: git discovery walks UP, so a tarball
# unpacked anywhere inside an unrelated worktree would otherwise describe that
# enclosing repository and print its tag as if it were ours. Requiring a .git
# right here (a directory for a clone, a file for a worktree/submodule) keeps
# the claim about THIS checkout.
if [ -e .git ]; then
  version="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
  # `--dirty` covers TRACKED modifications only, while the loop below globs the
  # filesystem. Test exactly what will execute: ask git whether each numbered
  # script the glob matches is tracked. Deliberately NOT
  # `ls-files --others --exclude-standard` — that hides a script ignored via
  # .gitignore, .git/info/exclude, or a global excludes file, which the loop
  # would still happily run under a clean-looking tag.
  for s in scripts/[0-9]*.sh; do
    [ -e "${s}" ] || continue
    if ! git ls-files --error-unmatch "${s}" >/dev/null 2>&1; then
      version="${version}+untracked-scripts"
      break
    fi
  done
else
  version="unknown"
fi
echo "lavasec-base ${version}"

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
