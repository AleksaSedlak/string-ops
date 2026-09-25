#!/usr/bin/env bash
# Compare every REPOS.md entry's "Screened at" hash with the repo's current PR target branch
# (where new work lands first; the default branch when no PR target is recorded).
# Prints one block per repo. Read-only: fetches origin (when reachable), never checks anything out.
#
# usage: check.sh [--no-fetch] [repo ...]
set -uo pipefail
WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FETCH=1; ONLY=()
for a in "$@"; do case "$a" in --no-fetch) FETCH=0;; *) ONLY+=("$a");; esac; done

# files that back a registry entry, for any stack: manifests, docs, entry points, routes and handlers,
# types and schemas, events and topics, CI and deploy config
BACKING='(^|/)(package\.json|pyproject\.toml|setup\.py|Cargo\.toml|go\.mod|Gemfile|composer\.json|pom\.xml|build\.gradle[^/]*|[^/]*\.csproj|mix\.exs|Package\.swift|README[^/]*|readme[^/]*|CONTRIBUTING[^/]*|CLAUDE\.md|Dockerfile[^/]*|docker-compose[^/]*|Procfile|Makefile|cloudbuild[^/]*\.ya?ml|\.gitlab-ci\.yml|Jenkinsfile|vercel\.json|app\.ya?ml|serverless[^/]*\.ya?ml|fly\.toml)$|(^|/)(\.github/workflows|\.circleci|k8s|kubernetes|helm|deploy|terraform|infra)/|(controller|handler|routes?|router|\.controller|\.dto|types|schema|models?|events?|topics?|pubsub|queue|endpoints|api|app\.module)[^/]*\.(ts|js|mjs|py|go|rs|rb|java|kt|cs|php|ex|swift)$|^(src/|app/|lib/|cmd/[^/]+/)?(index|main|app|server)\.(ts|js|mjs|py|go|rs|rb|java|kt|cs|php|ex|swift)$'

entries="$(grep -E '^## ' "$WS/REPOS.md" | sed 's/^## //')"
for repo in $entries; do
  if [ ${#ONLY[@]} -gt 0 ]; then case " ${ONLY[*]} " in *" $repo "*) ;; *) continue;; esac; fi
  dir="$WS/$repo"
  block="$(awk -v r="## $repo" '$0==r{f=1;next} /^## /{f=0} f' "$WS/REPOS.md")"
  old="$(printf '%s\n' "$block" | sed -nE 's/^- Screened at: ([0-9a-f]+) .*/\1/p' | head -1)"
  def="$(printf '%s\n' "$block" | sed -nE 's/^- Branches: .*PR target ([A-Za-z0-9_\/-]+(\.[A-Za-z0-9_\/-]+)*).*/\1/p' | head -1)"
  [ -n "$def" ] || def="$(printf '%s\n' "$block" | sed -nE 's/^- Branches: default ([A-Za-z0-9_\/-]+(\.[A-Za-z0-9_\/-]+)*).*/\1/p' | head -1)"
  echo "## $repo"
  if [ ! -d "$dir/.git" ]; then echo "  MISSING: folder has no git repo; entry may be stale"; continue; fi
  [ -n "$old" ] || { echo "  no Screened at hash in entry"; continue; }
  [ -n "$def" ] || def="$(git -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD | sed 's#origin/##')"
  [ -n "$def" ] || { echo "  cannot determine default branch"; continue; }
  if [ "$FETCH" = 1 ]; then git -C "$dir" fetch -q origin "$def" 2>/dev/null || echo "  warning: fetch of origin/$def failed, using local refs"; fi
  ref="origin/$def"; git -C "$dir" show-ref --verify -q "refs/remotes/$ref" || ref="$def"
  new="$(git -C "$dir" rev-parse --short "$ref" 2>/dev/null)" || { echo "  cannot resolve $ref"; continue; }
  if ! git -C "$dir" cat-file -e "$old^{commit}" 2>/dev/null; then echo "  recorded hash $old not found locally; treat as moved"; echo "  now: $new ($ref)"; continue; fi
  if git -C "$dir" merge-base --is-ancestor "$new" "$old" 2>/dev/null; then
    echo "  unchanged: $ref at $new is at or behind the screened $old"
    continue
  fi
  base="$(git -C "$dir" merge-base "$old" "$new" 2>/dev/null || echo "$old")"
  ahead="$(git -C "$dir" rev-list --count "$base..$new")"
  echo "  moved: screened $old, $ref now $new ($ahead new commits since their merge base $base)"
  changed="$(git -C "$dir" diff --name-only "$base" "$new" 2>/dev/null | grep -v -E '(^|/)(node_modules|dist|coverage|\.claude/worktrees)/' )"
  total="$(printf '%s\n' "$changed" | grep -c . )"
  backing="$(printf '%s\n' "$changed" | grep -E "$BACKING" || true)"
  nb="$(printf '%s\n' "$backing" | grep -c . )"
  echo "  files changed: $total, of which backing the entry: $nb"
  [ "$nb" -gt 0 ] && printf '%s\n' "$backing" | sed 's/^/    /' | head -40
done

echo "## folders vs entries"
for d in "$WS"/*/; do d="${d%/}"; n="$(basename "$d")"; [ -d "$d/.git" ] || continue
  printf '%s\n' "$entries" | grep -qx "$n" || echo "  folder without entry: $n (run /add-repo)"
done
for e in $entries; do [ -d "$WS/$e/.git" ] || echo "  entry without folder: $e"; done
echo "## registry size: $(wc -l < "$WS/REPOS.md" | tr -d ' ') lines"
[ ${#ONLY[@]} -eq 0 ] && date +%F > "$WS/.claude/registry-checked"
