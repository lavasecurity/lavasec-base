#!/usr/bin/env bash
set -euo pipefail
# Sync org repos over HTTPS with ONE fine-grained READ-ONLY PAT
# (resource owner: lavasecurity, repository access: All repositories,
# permissions: Contents = Read-only — owner decision: this box mirrors the
# whole org, so config/repos.txt is the explicit sync inventory and the
# token stays maintenance-free). Deliberately not an OAuth user token —
# those are account-wide read/WRITE and cannot be narrowed. The token lives
# in ~/.config/lavasec/github-token (600); the credential helper reads it
# fresh on every git operation, so rotation is just overwriting that file.

REPOS_FILE="$(cd "$(dirname "$0")/.." && pwd)/config/repos.txt"
# box-specific overlay lives OUTSIDE every repo (owner call 2026-07-29):
# working trees stay pristine, and box-local config survives re-clones
REPOS_LOCAL="${HOME}/.config/lavasec/repos.local.txt"
SRC_DIR="${SRC_DIR:-${HOME}/src}"
TOKEN_FILE="${HOME}/.config/lavasec/github-token"

mkdir -p "${SRC_DIR}"
mkdir -p "$(dirname "${TOKEN_FILE}")"

# org identity, not personal — this is a dedicated org VM
git config --global user.name "Lava Security"
git config --global user.email "285110054+lavasecurity@users.noreply.github.com"
git config --global init.defaultBranch main

print_pat_instructions() {
  {
    echo "  Fine-grained PAT setup: github.com → Settings → Developer settings"
    echo "  → Fine-grained tokens. Resource owner: lavasecurity. Repository"
    echo "  access: All repositories. Permissions: Contents = Read-only."
    echo "  Install/rotate on this VM:"
    echo "    umask 077 && printf %s '<token>' > ${TOKEN_FILE}"
  } >&2
}

if [ ! -s "${TOKEN_FILE}" ]; then
  echo "20-git: no token at ${TOKEN_FILE}" >&2
  print_pat_instructions
  exit 1
fi
chmod 600 "${TOKEN_FILE}"

# helper reads the token per operation — nothing cached, nothing in remote URLs.
# The empty first value resets any inherited helper list (gh, store, GCM…) so
# ONLY this helper answers for github.com — an earlier helper could inject
# stale/write-scoped creds or persist the PAT elsewhere (gitcredentials(7)).
git config --global --replace-all credential."https://github.com".helper ""
# shellcheck disable=SC2016
git config --global --add credential."https://github.com".helper \
  '!f() { echo "username=x-access-token"; echo "password=$(cat "${HOME}/.config/lavasec/github-token")"; }; f'

# direct redirections, not process substitution — a missing/unreadable file
# must kill the run (set -e), never silently shrink the inventory
mapfile -t lines < "${REPOS_FILE}"
if [ -e "${REPOS_LOCAL}" ]; then
  mapfile -t -O "${#lines[@]}" lines < "${REPOS_LOCAL}"
fi
synced=0
failed=()
for line in "${lines[@]}"; do
  repo="${line%%#*}"
  repo="${repo//[[:space:]]/}"
  if [ -z "${repo}" ]; then
    continue
  fi
  name="${repo##*/}"
  dest="${SRC_DIR}/${name}"
  url="https://github.com/${repo}.git"

  if [ -d "${dest}/.git" ]; then
    git -C "${dest}" remote set-url origin "${url}"  # heals pre-HTTPS remotes
    if out=$(git -C "${dest}" pull --ff-only 2>&1 < /dev/null); then
      echo "20-git: pulled ${repo}"
      synced=$((synced + 1))
    elif heads=$(git -C "${dest}" ls-remote --heads origin 2>/dev/null < /dev/null) \
        && [ -z "${heads}" ]; then
      # empty ONLY counts when ls-remote itself succeeded — a failed
      # ls-remote (broken token, network) must fall through as a failure
      echo "20-git: ${repo} is empty upstream — skipped"
    else
      failed+=("${repo}: $(printf '%s' "${out}" | tail -3 | tr '\n' ' ')")
    fi
  else
    if out=$(git clone "${url}" "${dest}" 2>&1 < /dev/null); then
      echo "20-git: cloned ${repo}"
      synced=$((synced + 1))
    else
      failed+=("${repo}: $(printf '%s' "${out}" | tail -3 | tr '\n' ' ')")
    fi
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  {
    echo ""
    echo "20-git: ${#failed[@]} repo(s) failed:"
    for entry in "${failed[@]}"; do
      echo "  ${entry}"
    done
    echo ""
    echo "  401/403/404 usually means the PAT is invalid or expired."
    echo "  Non-fast-forward means the local clone in ${SRC_DIR} diverged"
    echo "  and needs manual attention."
  } >&2
  print_pat_instructions
  exit 1
fi
echo "20-git: OK (${synced} repos in ${SRC_DIR})"
