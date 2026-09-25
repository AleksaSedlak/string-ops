#!/usr/bin/env bash
# The one place that knows how workers are opened, prompted, watched, read and closed.
# Three backends: herdr (its agent API), tmux (a window per worker in one detached session; the
# worker's own hooks report its state through state.sh), and headless (a background `claude -p`
# process with no window: the fastest way to get a read-only answer; its pane id is "headless:<dir>",
# and every function below recognises that prefix, so a later process needs no other hint). Everything
# else calls these functions or the command form below and never touches herdr or tmux directly.
#
# Sourced:   . backend.sh; be_open ...; be_status ...
# Command:   backend.sh name | status <name> <pane> <state-file> | read <name> <pane> [lines]
#                     | prompt <name> <pane> "<text>" | keys <name> <pane> esc | close <id> | attach
#
# WORKER_BACKEND in workflow.conf: herdr, tmux, or auto (herdr when installed, else tmux). start-worker
# sets it to headless for a read-only worker when LOOKUP_BACKEND says so.
# TMUX_SESSION: the tmux session that holds every worker window (default: workers).
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

be_name() {
  case "${WORKER_BACKEND:-auto}" in
    herdr|tmux|headless) printf '%s' "$WORKER_BACKEND";;
    *) if command -v herdr >/dev/null 2>&1; then printf 'herdr'; elif command -v tmux >/dev/null 2>&1; then printf 'tmux'; else printf 'none'; fi;;
  esac
}
# the backend a given pane belongs to: a headless pane says so in its id, anything else is the window backend
_be_of() { case "${1:-}" in headless:*) printf 'headless';; *) be_name;; esac; }
be_require() { local b; b="$(be_name)"; [ "$b" != none ] || { echo "no worker backend: install herdr or tmux" >&2; return 1; }
  case "$b" in headless) command -v claude >/dev/null 2>&1 || { echo "claude is not installed" >&2; return 1; };;
    *) command -v "$b" >/dev/null 2>&1 || { echo "worker backend $b is not installed" >&2; return 1; };; esac; }
# headless run dir helpers: <dir>/cwd, env, run.sh, out.md, err.log, pid, exit
_hl_dir() { printf '%s' "${1#headless:}"; }
_hl_alive() { local pid; pid="$(cat "$1/pid" 2>/dev/null)"; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }

# be_open <label> <cwd> [KEY=VAL ...]  ->  prints "<id>\t<pane>"
be_open() {
  local label="$1" cwd="$2"; shift 2
  case "$(be_name)" in
    headless)
      local dir e; dir="${BE_LAUNCH_DIR:?BE_LAUNCH_DIR is needed for a headless worker}/headless/$(printf '%s' "$label" | tr -c 'A-Za-z0-9_-' '-')"
      rm -rf "$dir"; mkdir -p "$dir"; printf '%s' "$cwd" > "$dir/cwd"; : > "$dir/env"
      for e in "$@"; do printf '%s\n' "$e" >> "$dir/env"; done
      printf 'headless:%s\theadless:%s' "$dir" "$dir";;
    herdr)
      local args=(--cwd "$cwd" --label "$label" --no-focus) e created
      for e in "$@"; do args+=(--env "$e"); done
      created="$(herdr workspace create "${args[@]}")" || return 1
      printf '%s\t%s' "$(printf '%s' "$created" | jq -r '.result.workspace.workspace_id')" "$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id')";;
    tmux)
      local s="${TMUX_SESSION:-workers}" win e envs=()
      for e in "$@"; do envs+=(-e "$e"); done
      # two parallel opens may both try to create the session; the loser's error is harmless
      tmux has-session -t "$s" 2>/dev/null || tmux new-session -d -s "$s" -c "$cwd" -x 200 -y 50 2>/dev/null || true
      win="$(printf '%s' "$label" | tr -c 'A-Za-z0-9_-' '-' | cut -c1-40)"
      tmux new-window -d -t "$s" -n "$win" -c "$cwd" "${envs[@]}" -P -F '#{session_name}:#{window_id}' 2>/dev/null | { read -r id; printf '%s\t%s' "$id" "$id"; };;
  esac
}

# be_start <name> <pane> <prompt> <claude args...>   starts the worker and hands it its first prompt
be_start() {
  local name="$1" pane="$2" prompt="$3"; shift 3
  case "$(_be_of "$pane")" in
    headless)
      # a wrapper script runs claude -p in the background: stdout to out.md, stderr to err.log, exit code
      # to exit. If the worker ends without writing its report, its final answer becomes the report, so a
      # headless lookup never comes back empty-handed. A watchdog stops a run that passes the cap.
      local dir; dir="$(_hl_dir "$pane")"
      { echo '#!/usr/bin/env bash'
        printf 'cd %q || exit 1\n' "$(cat "$dir/cwd")"
        printf 'set -a; . %q; set +a\n' "$dir/env"
        printf 'claude -p %q ' "$prompt"; printf '%q ' "$@" --name "$name"; printf '> %q 2> %q &\n' "$dir/out.md" "$dir/err.log"
        echo 'pid=$!; ( sleep "${HEADLESS_MAX_SECONDS:-3600}"; kill "$pid" 2>/dev/null && echo "killed by the watchdog" >> err.log ) & wd=$!'
        echo 'wait "$pid"; rc=$?; kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null'
        echo 'if [ -n "${WORKER_REPORT_FILE:-}" ] && [ ! -s "$WORKER_REPORT_FILE" ] && [ -s out.md ]; then mkdir -p "$(dirname "$WORKER_REPORT_FILE")"; cp out.md "$WORKER_REPORT_FILE"; fi'
        printf 'echo $rc > %q\n' "$dir/exit"
      } > "$dir/run.sh"; chmod +x "$dir/run.sh"
      (cd "$dir" && nohup bash "$dir/run.sh" >/dev/null 2>&1 & echo $! > "$dir/pid");;
    herdr)
      herdr agent start "$name" --kind claude --pane "$pane" --timeout 120000 -- "$@" --name "$name" >/dev/null || return 1
      herdr agent prompt "$name" "$prompt" >/dev/null || return 1
      herdr agent wait "$name" --until working --until blocked --timeout 20000 >/dev/null || echo "warning: $name did not start working within 20 s; read its pane" >&2;;
    tmux)
      # the full command goes into a launch script; only a short line is typed into the window, so the
      # terminal's input limit and the shell's start-up time cannot cut it off
      local cwd launch; cwd="$(tmux display -p -t "$pane" '#{pane_current_path}')"
      launch="${BE_LAUNCH_DIR:-$cwd}/launch-$name.sh"
      { echo '#!/usr/bin/env bash'; printf 'cd %q\n' "$cwd"; printf 'exec claude '; printf '%q ' "$@" --name "$name" "$prompt"; echo; } > "$launch"
      chmod +x "$launch"
      tmux set-option -t "$pane" remain-on-exit on >/dev/null 2>&1
      sleep 1
      tmux send-keys -t "$pane" -l "exec bash $(printf '%q' "$launch")" && tmux send-keys -t "$pane" Enter
      local i=0 cur
      while [ $i -lt 20 ]; do cur="$(tmux display -p -t "$pane" '#{pane_current_command}' 2>/dev/null)"; case "$cur" in claude|node) break;; esac; sleep 1; i=$((i+1)); done
      [ $i -lt 20 ] || echo "warning: $name did not start within 20 s; read its window" >&2;;
  esac
}

# be_status <name> <pane> <state-file>  ->  working | blocked | idle | gone
be_status() {
  local name="$1" pane="$2" state="$3" st
  case "$(_be_of "$pane")" in
    headless) local dir; dir="$(_hl_dir "$pane")"
      if [ -f "$dir/exit" ]; then printf 'idle'; elif _hl_alive "$dir"; then printf 'working'; else printf 'gone'; fi;;
    herdr) st="$(herdr agent get "$name" 2>/dev/null | jq -r '.result.agent.agent_status // empty')"; printf '%s' "${st:-gone}";;
    tmux)
      local cur dead
      dead="$(tmux display -p -t "$pane" '#{pane_dead}' 2>/dev/null)" || { printf 'gone'; return 0; }
      [ "$dead" = 0 ] || { printf 'gone'; return 0; }
      cur="$(tmux display -p -t "$pane" '#{pane_current_command}' 2>/dev/null)"
      case "$cur" in claude|node) ;; *) printf 'gone'; return 0;; esac
      st="$(head -1 "$state" 2>/dev/null | cut -d' ' -f1)"; printf '%s' "${st:-working}";;
  esac
}

# be_read <name> <pane> [lines]   the tail of the worker's screen
be_read() {
  local name="$1" pane="$2" n="${3:-80}"
  case "$(_be_of "$pane")" in
    headless) local dir; dir="$(_hl_dir "$pane")"; { cat "$dir/err.log" 2>/dev/null; cat "$dir/out.md" 2>/dev/null; } | tail -n "$n";;
    herdr) herdr agent read "$name" --source recent-unwrapped --lines "$n" 2>/dev/null | jq -r '.result.text // .result.lines[]? // empty' 2>/dev/null;;
    tmux) tmux capture-pane -p -t "$pane" -S "-$n" 2>/dev/null;;
  esac
}

# be_prompt <name> <pane> "<text>"   a follow-up message into the worker's input
be_prompt() {
  local name="$1" pane="$2" text="$3"
  case "$(_be_of "$pane")" in
    headless) echo "$name is headless and takes no input; relaunch it with the answer in --prompt" >&2; return 1;;
    herdr) herdr agent prompt "$name" "$text" >/dev/null;;
    tmux) tmux send-keys -t "$pane" -l "$text" && tmux send-keys -t "$pane" Enter;;
  esac
}

# be_keys <name> <pane> esc   interrupt the worker's current turn
be_keys() {
  local name="$1" pane="$2" key="$3"
  case "$(_be_of "$pane")" in
    headless) local dir; dir="$(_hl_dir "$pane")"; _hl_alive "$dir" && kill "$(cat "$dir/pid")" 2>/dev/null; return 0;;
    herdr) herdr agent send-keys "$name" "$key" >/dev/null;;
    tmux) case "$key" in esc) tmux send-keys -t "$pane" Escape;; *) tmux send-keys -t "$pane" "$key";; esac;;
  esac
}

# be_close <id>   close the worker's window
be_close() {
  case "$(_be_of "$1")" in
    headless) local dir; dir="$(_hl_dir "$1")"; _hl_alive "$dir" && kill "$(cat "$dir/pid")" 2>/dev/null; return 0;;
    herdr) herdr workspace close "$1" >/dev/null 2>&1;;
    tmux)
      local s="${TMUX_SESSION:-workers}"
      tmux kill-window -t "$1" 2>/dev/null
      # the session was created for workers; when only its empty first window is left, let it go too
      if [ "$(tmux list-windows -t "$s" 2>/dev/null | wc -l | tr -d ' ')" = 1 ]; then
        case "$(tmux display -p -t "$s:0" '#{pane_current_command}' 2>/dev/null)" in zsh|bash|sh|fish) tmux kill-session -t "$s" 2>/dev/null;; esac
      fi;;
  esac
}

# be_attach_hint   how a person looks at the workers
be_attach_hint() {
  case "$(be_name)" in
    headless) echo "headless workers have no window; read one with: backend.sh read <name> <pane> [lines]";;
    herdr) echo "workers are herdr workspaces; herdr shows them";;
    tmux) echo "workers are windows in tmux session ${TMUX_SESSION:-workers}; watch with: tmux attach -t ${TMUX_SESSION:-workers}";;
  esac
}

# be_rows <plans dir>   the latest row per worker name across every plan that is not finished:
#   plan \t repo \t name \t id \t pane \t stamp
# A plan with a .dispatch/finished stamp (written by finish-lookup, cleared by the next start in it) is
# skipped without asking the backend, so old lookups cost nothing.
be_rows() {
  local tsv plan
  for tsv in "$1"/*/.dispatch/workers.tsv; do
    [ -f "$tsv" ] || continue
    [ -f "$(dirname "$tsv")/finished" ] && continue
    plan="$(basename "$(dirname "$(dirname "$tsv")")")"
    awk -F'\t' -v p="$plan" '{ row[$3] = p "\t" $2 "\t" $3 "\t" $5 "\t" $6 "\t" $1 } END { for (n in row) print row[n] }' "$tsv"
  done
}
# be_live_rows <plans dir>   be_rows minus workers whose report is newer than their start: those have
# settled, whatever their window says, and are decided from the filesystem alone (no backend call)
be_live_rows() {
  local plan repo name id pane stamp
  while IFS=$'\t' read -r plan repo name id pane stamp; do
    [ -n "$name" ] || continue
    if [ -f "$1/$plan/reports/$repo.md" ] && [ "$(file_mtime "$1/$plan/reports/$repo.md")" -ge "$(stamp_epoch "$stamp")" ]; then continue; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$plan" "$repo" "$name" "$id" "$pane" "$stamp"
  done <<< "$(be_rows "$1")"
}
# be_live_count <plans dir>   workers that are working or blocked right now
be_live_count() {
  local n=0 plan repo name id pane stamp st
  while IFS=$'\t' read -r plan repo name id pane stamp; do
    [ -n "$name" ] || continue
    st="$(be_status "$name" "$pane" "$1/$plan/.dispatch/state/$repo")"
    case "$st" in working|blocked) n=$((n+1));; esac
  done <<< "$(be_live_rows "$1")"
  printf '%s' "$n"
}

# command form
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    name) be_name; echo;;
    status) be_status "$@"; echo;;
    read) be_read "$@";;
    prompt) be_prompt "$@";;
    keys) be_keys "$@";;
    close) be_close "$@";;
    attach) be_attach_hint;;
    *) echo "usage: backend.sh name | status <name> <pane> <state-file> | read <name> <pane> [lines] | prompt <name> <pane> <text> | keys <name> <pane> esc | close <id> | attach" >&2; exit 2;;
  esac
fi
