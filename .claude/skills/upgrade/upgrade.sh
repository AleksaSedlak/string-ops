#!/usr/bin/env bash
# Pull a newer version of the framework into this workspace. Instance files (REPOS.md, ROUTING.md,
# workflow.conf, METRICS.md, plans/, learnings/, your repos) are not part of the framework, so they are
# never touched; only .claude/, templates/, tests/, docs/, CLAUDE.md and README.md can change.
#
#   upgrade.sh [--remote <name>] [--branch <name>] [--dry-run]
#
# Uses the `upstream` remote when it exists, else `origin`. Prints the commits and files that would come
# in, then merges (fast-forward when possible), then runs tests/check.sh. Refuses when the working tree
# has uncommitted changes to framework files, so nothing of yours is overwritten.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
WS="$(ws_root)"; cd "$WS" || exit 1
REMOTE=""; BRANCH=main; DRY=0
while [ $# -gt 0 ]; do case "$1" in --remote) REMOTE="$2"; shift 2;; --branch) BRANCH="$2"; shift 2;; --dry-run) DRY=1; shift;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repository: $WS (the workspace itself must be a clone of the framework)" >&2; exit 1; }
if [ -z "$REMOTE" ]; then if git remote get-url upstream >/dev/null 2>&1; then REMOTE=upstream; else REMOTE=origin; fi; fi
git remote get-url "$REMOTE" >/dev/null 2>&1 || { echo "no remote named $REMOTE; add one: git remote add upstream <framework repo url>" >&2; exit 1; }
dirty="$(git status --porcelain -- .claude templates tests docs CLAUDE.md README.md | grep -v '^??' || true)"
[ -z "$dirty" ] || { echo "framework files have uncommitted changes; commit or stash them first:"; printf '%s\n' "$dirty"; exit 1; }
git fetch -q "$REMOTE" "$BRANCH" || { echo "fetch from $REMOTE $BRANCH failed" >&2; exit 1; }
n="$(git rev-list --count "HEAD..$REMOTE/$BRANCH")"
if [ "$n" = 0 ]; then echo "up to date with $REMOTE/$BRANCH"; exit 0; fi
echo "$n new commit(s) on $REMOTE/$BRANCH:"; git log --oneline "HEAD..$REMOTE/$BRANCH" | sed 's/^/  /'
echo "files that change:"; git diff --stat "HEAD...$REMOTE/$BRANCH" | tail -n +1 | sed 's/^/  /'
[ "$DRY" = 1 ] && { echo "dry run, nothing merged"; exit 0; }
if git merge --ff-only "$REMOTE/$BRANCH" >/dev/null 2>&1; then echo "fast-forwarded to $(git rev-parse --short HEAD)"
elif git merge --no-edit "$REMOTE/$BRANCH" >/dev/null 2>&1; then echo "merged $REMOTE/$BRANCH into $(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD)"
else echo "merge has conflicts in your own edits to framework files; resolve them, then run tests/check.sh:"; git diff --name-only --diff-filter=U | sed 's/^/  /'; exit 1; fi
[ -x tests/check.sh ] && { echo "--- tests/check.sh"; tests/check.sh; }
exit 0
