#!/usr/bin/env bash
# Shared helpers for every script in .claude/skills. Source it; never run it.
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
# Portable across macOS (BSD userland, bash 3.2) and Linux (GNU userland). Loads workflow.conf.

# Workspace root: the folder that holds .claude/, REPOS.md and the repos. WORKSPACE_ROOT overrides
# (tests point it at a fixture workspace).
ws_root() { printf '%s' "${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"; }

# workflow.conf: plain KEY=value lines written by /start. Every key has a default here so a missing
# file is fine.
# Precedence: a value set in the environment (tests, one-off overrides) beats workflow.conf, which
# beats these defaults.
_CONF_KEYS="PROTECTED_BRANCHES WORKER_CAP LEARNINGS_CAP MODEL_PLAN MODEL_CODE MODEL_LOOKUP MODEL_REVIEW EFFORT_PLAN EFFORT_CODE EFFORT_LOOKUP EFFORT_REVIEW WORKER_PERMISSION_MODE WORKER_BACKEND LOOKUP_BACKEND TMUX_SESSION"
_ENV_SET=""; for _k in $_CONF_KEYS; do eval "[ -n \"\${$_k+x}\" ]" && _ENV_SET="$_ENV_SET $_k"; done
: "${PROTECTED_BRANCHES:=main master staging develop}"
: "${WORKER_CAP:=10}"
: "${LEARNINGS_CAP:=15}"
# "default" means the model Claude Code starts with on this machine (the latest unless the user pinned one)
: "${MODEL_PLAN:=default}"
: "${MODEL_CODE:=default}"
: "${MODEL_LOOKUP:=default}"
: "${MODEL_REVIEW:=default}"
: "${EFFORT_PLAN:=xhigh}"
: "${EFFORT_CODE:=high}"
: "${EFFORT_LOOKUP:=medium}"
: "${EFFORT_REVIEW:=high}"
: "${WORKER_PERMISSION_MODE:=auto}"
: "${WORKER_BACKEND:=auto}"
: "${LOOKUP_BACKEND:=headless}"
: "${TMUX_SESSION:=workers}"
load_conf() {
  local f="$(ws_root)/workflow.conf" k v
  [ -f "$f" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue;; esac
    v="${v%\"}"; v="${v#\"}"
    case " $_CONF_KEYS " in *" $k "*) case " $_ENV_SET " in *" $k "*) ;; *) eval "$k=\"\$v\"";; esac;; esac
  done < "$f"
}
load_conf

# Is $1 a protected branch (never committed to or pushed to directly)?
is_protected() { local b; for b in $PROTECTED_BRANCHES; do [ "$1" = "$b" ] && return 0; done; return 1; }
# The same list as an alternation for grep -E: main|master|staging
protected_alt() { printf '%s' "$PROTECTED_BRANCHES" | tr ' ' '|'; }

# Modification time of a file as epoch seconds.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }  # GNU first: GNU stat accepts -f too, with other output
# "YYYY-MM-DDTHH:MM:SS" (local time) to epoch seconds.
stamp_epoch() { date -j -f %Y-%m-%dT%H:%M:%S "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null || echo 0; }
# "YYYY-MM-DD" to epoch seconds.
date_epoch() { date -j -f %Y-%m-%d "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null || echo 0; }

# Copy a directory tree cheaply: copy-on-write clone where the filesystem supports it (APFS, btrfs,
# xfs with reflinks), plain copy otherwise.
clone_dir() { cp -c -R "$1" "$2" 2>/dev/null || cp --reflink=auto -R "$1" "$2" 2>/dev/null || cp -R "$1" "$2"; }

# Desktop notification, best effort, silent when no notifier exists.
notify_desktop() {
  local title="$1" body="$2"
  if command -v osascript >/dev/null 2>&1; then osascript -e "display notification \"$body\" with title \"$title\"" >/dev/null 2>&1
  elif command -v notify-send >/dev/null 2>&1; then notify-send "$title" "$body" >/dev/null 2>&1
  fi
  return 0
}
