#!/usr/bin/env bash
# Deterministic ship preflight for one repo checkout. Prints one PASS/FAIL line per check and exits 1
# if any check failed. Pushes nothing, changes nothing.
#
# usage: preflight.sh --checkout <abs path> --target <PR target branch> --branch <workstream branch>
#
# Checks: on the workstream branch; clean tree; ahead of origin/<target>; no attribution in commit
# messages; no secrets in the diff (gitleaks when installed, pattern scan otherwise); merges cleanly
# into the current origin/<target> (dry run with git merge-tree, nothing written).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
CO=""; TARGET=""; BRANCH=""
while [ $# -gt 0 ]; do case "$1" in --checkout) CO="$2"; shift 2;; --target) TARGET="$2"; shift 2;; --branch) BRANCH="$2"; shift 2;; *) echo "unknown argument: $1" >&2; exit 2;; esac; done
[ -n "$CO" ] && [ -n "$TARGET" ] && [ -n "$BRANCH" ] || { echo "need --checkout, --target, --branch" >&2; exit 2; }
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

cur="$(git -C "$CO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ "$cur" = "$BRANCH" ] && ok "branch: on $BRANCH" || bad "branch: on '$cur', expected $BRANCH"
is_protected "$cur" && bad "branch: $cur is protected"

[ -z "$(git -C "$CO" status --porcelain)" ] && ok "tree: clean" || bad "tree: uncommitted changes present"

git -C "$CO" fetch -q origin "$TARGET" 2>/dev/null || echo "note: fetch of origin/$TARGET failed, using the local ref"
base="origin/$TARGET"; git -C "$CO" show-ref --verify -q "refs/remotes/$base" || bad "base: origin/$TARGET not found"
n="$(git -C "$CO" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
[ "$n" -gt 0 ] && ok "commits: $n ahead of $base" || bad "commits: nothing ahead of $base"

msgs="$(git -C "$CO" log "$base..HEAD" --format=%B 2>/dev/null)"
if printf '%s' "$msgs" | grep -qiE 'claude|anthropic|co-authored-by|generated-by|generated with|\bAI\b'; then bad "attribution: commit messages mention Claude, AI, Anthropic or carry trailers"
elif printf '%s' "$msgs" | grep -qP '[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]' 2>/dev/null; then bad "attribution: emoji in commit messages"
else ok "attribution: clean"; fi

# secrets: gitleaks over the branch commits when available, else a pattern scan of the added lines
if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks git --log-opts="$base..HEAD" --no-banner --exit-code 1 "$CO" >/dev/null 2>&1; then ok "secrets: gitleaks found nothing"; else bad "secrets: gitleaks reported findings (run: gitleaks git --log-opts=$base..HEAD $CO)"; fi
else
  added="$(git -C "$CO" diff "$base...HEAD" | grep -E '^\+' | grep -vE '^\+\+\+' || true)"  # three dots: the branch's own additions
  pat='AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|xox[abpr]-[A-Za-z0-9-]{10,}|hooks\.slack\.com/services/[A-Za-z0-9/]+|"private_key"[[:space:]]*:[[:space:]]*"-----|AIza[0-9A-Za-z_-]{35}|mongodb(\+srv)?://[^:/@]+:[^@/]+@|(password|passwd|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9/+=_-]{16,}["'"'"']'
  hits="$(printf '%s\n' "$added" | grep -nE "$pat" | grep -viE 'placeholder|xxx+|<[a-z_]+>|process\.env|\$\{|changeme|dummy' || true)"
  if [ -n "$hits" ]; then bad "secrets: pattern scan hit $(printf '%s\n' "$hits" | wc -l | tr -d ' ') added line(s); first: $(printf '%s\n' "$hits" | head -1 | cut -c1-120)"
  else ok "secrets: pattern scan found nothing (install gitleaks for a stronger scan)"; fi
fi

# merge dry run against the current target
if out="$(git -C "$CO" merge-tree --write-tree "$base" HEAD 2>&1)"; then ok "merge: merges cleanly into $base"
else
  files="$(printf '%s\n' "$out" | awk '/^CONFLICT/ {print}' | sed -E 's/^CONFLICT \([^)]*\): //' | head -5 | tr '\n' ';')"
  bad "merge: conflicts with $base (${files:-see git merge-tree}); dispatch a catch-up task before shipping"
fi

exit $fail
