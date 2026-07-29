#!/usr/bin/env bash
set -euo pipefail
# Sync org repos over HTTPS with ONE fine-grained READ-ONLY PAT
# (resource owner: lavasecurity, repository access: All repositories,
# permissions: Contents + Pull requests = Read-only (Contents alone clones
# fine but 403s on private-repo PR reads, which gh and T3 Code's
# source-control view need) — owner decision: this box mirrors the
# whole org, so config/repos.txt is the explicit sync inventory and the
# token stays maintenance-free). Deliberately not an OAuth user token —
# those are account-wide read/WRITE and cannot be narrowed. The token lives
# in ~/.config/lavasec/github-token (600); the credential helper reads it
# fresh on every git operation, so rotation is just overwriting that file.

REPOS_FILE="$(cd "$(dirname "$0")/.." && pwd)/config/repos.txt"
# untracked box-specific overlay — private repo names never enter the repo
REPOS_LOCAL="${REPOS_FILE%.txt}.local.txt"
SRC_DIR="${SRC_DIR:-${HOME}/src}"
TOKEN_FILE="${HOME}/.config/lavasec/github-token"

mkdir -p "${SRC_DIR}"
mkdir -p "$(dirname "${TOKEN_FILE}")"

# seed a self-documenting overlay template on first run (never overwrites);
# umask 077: the populated file lists private repo names — owner-only
if [ ! -e "${REPOS_LOCAL}" ]; then
  (umask 077 && cat > "${REPOS_LOCAL}") <<'EOF'
# Box-local repo overlay — read by scripts/20-git.sh alongside
# config/repos.txt, same format: one org/name per line, # ignores a line.
# This file is gitignored: private/box-specific entries belong here and
# never enter the tracked repo.
# example-org/private-repo
EOF
  echo "20-git: created overlay template at ${REPOS_LOCAL} (add private repos there)"
fi

# org identity, not personal — this is a dedicated org VM
git config --global user.name "Lava Security"
git config --global user.email "285110054+lavasecurity@users.noreply.github.com"
git config --global init.defaultBranch main

print_pat_instructions() {
  {
    echo "  Fine-grained PAT setup: github.com → Settings → Developer settings"
    echo "  → Fine-grained tokens. Resource owner: lavasecurity. Repository"
    echo "  access: All repositories. Permissions: Contents = Read-only"
    echo "  AND Pull requests = Read-only (needed by gh / the web console"
    echo "  for private-repo PR views; Contents alone still clones)."
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
    # A clone can legitimately sit on a branch this box's agents created,
    # or one deleted upstream after merge. Syncing is a convenience, not a
    # mandate: leave such checkouts untouched and keep bootstrap green
    # rather than failing every other repo (and never touch local work).
    branch="$(git -C "${dest}" branch --show-current 2>/dev/null || true)"
    if [ -n "${branch}" ] && ! git -C "${dest}" ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1; then
      echo "20-git: ${repo} on '${branch}' (no upstream branch) — left alone"
    elif out=$(git -C "${dest}" pull --ff-only 2>&1 < /dev/null); then
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
# gh authenticates from GH_TOKEN — same read-only PAT, same file. Managed
# block, replaced each run (--follow-symlinks keeps dotfiles symlinks).
if command -v gh >/dev/null; then
  sed -i --follow-symlinks '/^# >>> lavasec-base gh token >>>$/,/^# <<< lavasec-base gh token <<<$/d' "${HOME}/.bashrc"
  {
    echo "# >>> lavasec-base gh token >>>"
    echo "[ -r ${TOKEN_FILE} ] && export GH_TOKEN=\"\$(cat ${TOKEN_FILE})\""
    echo "# <<< lavasec-base gh token <<<"
  } >> "${HOME}/.bashrc"
fi

echo "20-git: OK (${synced} repos in ${SRC_DIR})"
