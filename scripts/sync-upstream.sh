#!/usr/bin/env bash
# Replays upstream rustdesk-server changes onto the vendored tree in server/.
#   scripts/sync-upstream.sh [upstream-ref]        default: master
#
# server/ = fork (FORK_COMMIT) + upstream (UPSTREAM_COMMIT) + local hardening, see server/UPSTREAM.
# Each file upstream changed since UPSTREAM_COMMIT is three-way merged into server/, so the
# fork's WebSocket support and our fixes are kept. Conflicts are left as <<<<<<< markers.
# hbb_common (a git submodule upstream) is replaced with the commit the new ref points to.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain -- server 2>/dev/null)" ] || { echo "commit or stash changes in server/ first"; exit 1; }
. server/UPSTREAM
ref=${1:-master}
# Upstream paths that are not vendored.
skip='^(\.github/|ui/|debian/|systemd/|docker/|docker-classic/|kubernetes/|\.vscode/|libs/hbb_common|README|AGENTS\.md|\.gitmodules|\.gitattributes|\.gitignore|docker-compose\.yml|rcd$|readme)'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone -q "$UPSTREAM_REPO" "$work/up"
up() { git -C "$work/up" "$@"; }
new=$(up rev-parse "origin/$ref^{commit}" 2>/dev/null || up rev-parse "$ref^{commit}")
conflicts=0

if [ "$new" = "$UPSTREAM_COMMIT" ]; then
  echo "server: already at upstream $new"
else
  echo "server: $UPSTREAM_COMMIT -> $new"
  up log --oneline --no-merges "$UPSTREAM_COMMIT..$new" | sed 's/^/  /'
  while IFS=$'\t' read -r status path; do
    [[ $path =~ $skip ]] && continue
    case $status in
      A)
        if [ -e "server/$path" ]; then echo "CONFLICT (added on both sides): $path -> server/$path.upstream"
          up show "$new:$path" > "server/$path.upstream"; conflicts=$((conflicts + 1))
        else mkdir -p "server/$(dirname "$path")"; up show "$new:$path" > "server/$path"; echo "added    $path"; fi ;;
      D)
        if [ -e "server/$path" ] && up show "$UPSTREAM_COMMIT:$path" | cmp -s - "server/$path"; then
          rm "server/$path"; echo "deleted  $path"
        elif [ -e "server/$path" ]; then echo "CONFLICT (deleted upstream, changed here): $path"; conflicts=$((conflicts + 1)); fi ;;
      M)
        [ -e "server/$path" ] || { echo "skipped  $path (not vendored)"; continue; }
        up show "$UPSTREAM_COMMIT:$path" > "$work/base"; up show "$new:$path" > "$work/theirs"
        if cmp -s "$work/base" "server/$path"; then cp "$work/theirs" "server/$path"; echo "updated  $path"
        elif git merge-file -L local -L base -L upstream "server/$path" "$work/base" "$work/theirs" 2>/dev/null; then echo "merged   $path"
        else echo "CONFLICT: $path"; conflicts=$((conflicts + 1)); fi ;;
    esac
  done < <(up diff --no-renames --name-status "$UPSTREAM_COMMIT" "$new")
fi

hbb=$(up ls-tree "$new" libs/hbb_common | awk '{print $3}')
if [ "$hbb" != "$HBB_COMMON_COMMIT" ]; then
  echo "hbb_common: $HBB_COMMON_COMMIT -> $hbb"
  git clone -q "$HBB_COMMON_REPO" "$work/hbb"
  git -C "$work/hbb" checkout -q "$HBB_COMMON_COMMIT"
  if ! diff -rq -x .git -x .github "$work/hbb" server/libs/hbb_common >/dev/null; then
    echo "WARNING: server/libs/hbb_common has local changes, they are being overwritten (see git diff)"
  fi
  git -C "$work/hbb" checkout -q "$hbb"
  rm -rf server/libs/hbb_common
  mkdir -p server/libs/hbb_common
  git -C "$work/hbb" archive "$hbb" | tar -x -C server/libs/hbb_common
  rm -rf server/libs/hbb_common/.github
else
  echo "hbb_common: already at $hbb"
fi

sed -i -e "s/^UPSTREAM_COMMIT=.*/UPSTREAM_COMMIT=$new/" -e "s/^HBB_COMMON_COMMIT=.*/HBB_COMMON_COMMIT=$hbb/" server/UPSTREAM

fork=$(git ls-remote "$FORK_REPO" "refs/heads/$FORK_BRANCH" | cut -f1)
[ "$fork" = "$FORK_COMMIT" ] || echo "NOTE: fork $FORK_BRANCH moved to $fork (vendored: $FORK_COMMIT): review its changes by hand"

echo
if [ "$conflicts" -gt 0 ]; then
  echo "$conflicts conflict(s): fix them in server/ (grep -rn '<<<<<<<' server/src), then build and test."
  exit 1
fi
echo "Done. Next: scripts/cargo.sh test --locked && docker compose build && test/e2e/run.sh"
