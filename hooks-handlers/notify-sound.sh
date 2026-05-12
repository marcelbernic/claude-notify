#!/bin/bash
# notify-sound.sh — per-project sound notifications for Claude Code.
#
# Dispatches on first argument:
#   stop | notify           Hook entry points. Resolve the configured sound
#                           for the current project and play it (detached).
#   set <name>              Assign a sound to the current project.
#   list                    List available sounds (plugin library + user library).
#   add <path> [as <name>]  Copy a custom sound into the user library.
#   off                     Clear the current project's sound (revert to default).
#   test                    Replay the currently configured sound.
#   pause [all]             Silence this project (or all projects with `all`).
#   resume [all]            Undo pause for this project (or all with `all`).
#   status                  Show pause state, active sound, and resolution chain.
#   key                     Print the resolution chain and which key wins.
#
# Layout:
#   ${CLAUDE_PLUGIN_ROOT}/sounds/library/   stock sounds (read-only)
#   ~/.claude/data/notify/library/          user-added sounds
#   ~/.claude/data/notify/state/<key>.txt   sound assignment
#   ~/.claude/data/notify/state/<key>.stop  Stop-event override (advanced)
#   ~/.claude/data/notify/state/<key>.notify Notification-event override
#   ~/.claude/data/notify/state/<key>.paused per-project pause marker
#   ~/.claude/data/notify/state/paused       global pause marker
#
# Key resolution chain (first match wins):
#   1. project-<slug>     slug = basename of cwd's git-root (or cwd if not a repo)
#   2. pane-<id>          legacy. Read for backward compat; never written.
#   3. default
# ----------------------------------------------------------------------------

set -u

# Resolve plugin root: trust ${CLAUDE_PLUGIN_ROOT} if set, else derive from $0
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

PLUGIN_LIB="$PLUGIN_ROOT/sounds/library"
USER_DATA="${HOME}/.claude/data/notify"
USER_LIB="$USER_DATA/library"
STATE_DIR="$USER_DATA/state"
DEFAULT_SOUND="default"
SUPPORTED_EXTS=(aiff mp3 wav m4a caf)

mkdir -p "$USER_LIB" "$STATE_DIR"

# --- helpers -----------------------------------------------------------------

# Resolve the project root from a cwd hint, then $CLAUDE_PROJECT_DIR, then $PWD.
# If the result is inside a git repo, prefer the toplevel.
# $1 (optional) = cwd hint (e.g. parsed from hook stdin)
resolve_project_root() {
  local hint="${1:-}"
  local root="$hint"
  [ -z "$root" ] && root="${CLAUDE_PROJECT_DIR:-}"
  [ -z "$root" ] && root="$PWD"
  [ -z "$root" ] && return 0
  if command -v git >/dev/null 2>&1; then
    local toplevel
    toplevel="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$toplevel" ] && root="$toplevel"
  fi
  printf '%s' "$root"
}

# Slugify: lowercase, collapse non-alnum runs to '-', trim leading/trailing '-'.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//'
}

# Resolve "project-<slug>" from a cwd hint. Empty if not derivable.
resolve_project_key() {
  local cwd_hint="${1:-}"
  local root slug
  root="$(resolve_project_root "$cwd_hint")"
  [ -z "$root" ] && return 0
  slug="$(slugify "$(basename "$root")")"
  [ -z "$slug" ] && return 0
  printf 'project-%s' "$slug"
}

# Print ordered candidate keys, one per line.
# $1 (optional) = cwd hint (parsed from hook stdin)
resolve_keys() {
  local cwd_hint="${1:-}"
  local pkey
  pkey="$(resolve_project_key "$cwd_hint")"
  [ -n "$pkey" ] && printf '%s\n' "$pkey"
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'pane-%s\n' "${TMUX_PANE#%}"
  fi
  printf 'default\n'
}

# Read hook stdin payload and extract `cwd`. Empty on failure.
# Drains stdin even when jq is missing so the hook doesn't block.
read_hook_cwd() {
  if [ -t 0 ]; then return 0; fi
  local stdin_json cwd
  stdin_json="$(cat 2>/dev/null || true)"
  [ -z "$stdin_json" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  cwd="$(printf '%s' "$stdin_json" | jq -r '.cwd // empty' 2>/dev/null)"
  [ -n "$cwd" ] && printf '%s' "$cwd"
}

# Find a sound file by name. Searches user lib first, then plugin lib.
# Echoes the full path on success, empty on failure.
find_sound_file() {
  local name="$1"
  for dir in "$USER_LIB" "$PLUGIN_LIB"; do
    for ext in "${SUPPORTED_EXTS[@]}"; do
      if [ -r "$dir/$name.$ext" ]; then
        printf '%s' "$dir/$name.$ext"
        return 0
      fi
    done
  done
  return 1
}

play_detached() {
  local file="$1"
  if ! command -v afplay >/dev/null 2>&1; then
    printf '[notify-sound] afplay not found (macOS only); cannot play %s\n' "$file" >&2
    return 1
  fi
  ( afplay "$file" >/dev/null 2>&1 & ) >/dev/null 2>&1
}

play_blocking() {
  local file="$1"
  if ! command -v afplay >/dev/null 2>&1; then
    printf '[notify-sound] afplay not found (macOS only)\n' >&2
    return 1
  fi
  afplay "$file"
}

# --- subcommands -------------------------------------------------------------

cmd_play() {
  local event="$1"
  local cwd_hint
  cwd_hint="$(read_hook_cwd)"

  [ -e "$STATE_DIR/paused" ] && exit 0
  local pkey
  pkey="$(resolve_project_key "$cwd_hint")"
  [ -n "$pkey" ] && [ -e "$STATE_DIR/$pkey.paused" ] && exit 0

  local sound="" winning_key=""
  while IFS= read -r key; do
    if [ -r "$STATE_DIR/$key.$event" ]; then
      sound="$(head -n1 "$STATE_DIR/$key.$event" | tr -d '[:space:]')"
      winning_key="$key"
      break
    elif [ -r "$STATE_DIR/$key.txt" ]; then
      sound="$(head -n1 "$STATE_DIR/$key.txt" | tr -d '[:space:]')"
      winning_key="$key"
      break
    fi
  done < <(resolve_keys "$cwd_hint")

  if [ -z "$sound" ]; then
    sound="$DEFAULT_SOUND"
    winning_key="default"
  fi

  local file
  file="$(find_sound_file "$sound" || true)"
  if [ -z "$file" ]; then
    printf '[notify-sound] missing sound "%s" (key=%s event=%s)\n' "$sound" "$winning_key" "$event" >&2
    exit 0
  fi
  play_detached "$file"
  exit 0
}

cmd_set() {
  local sound="${1:-}"
  if [ -z "$sound" ]; then
    echo "Usage: notify-sound.sh set <sound>" >&2
    exit 1
  fi
  case "$sound" in
    */*|*' '*|.*) echo "Invalid sound name: $sound" >&2; exit 1 ;;
  esac

  local file
  file="$(find_sound_file "$sound" || true)"
  if [ -z "$file" ]; then
    echo "Sound '$sound' not in library. Try: notify-sound.sh list" >&2
    exit 1
  fi

  local key
  key="$(resolve_project_key)"
  if [ -z "$key" ]; then
    echo "Cannot determine project. Run /notify from inside a project directory." >&2
    exit 1
  fi
  printf '%s\n' "$sound" > "$STATE_DIR/$key.txt"
  printf '%s will now play: %s\n' "$key" "$sound"
  play_blocking "$file" || true
}

cmd_list() {
  {
    [ -d "$USER_LIB" ]   && ls "$USER_LIB"   2>/dev/null
    [ -d "$PLUGIN_LIB" ] && ls "$PLUGIN_LIB" 2>/dev/null
  } | sed 's/\.[^.]*$//' | sort -u
}

cmd_add() {
  local src="${1:-}"
  local rename_to=""
  # Accept both:  add <path> <name>   and   add <path> as <name>
  if [ "${2:-}" = "as" ]; then
    rename_to="${3:-}"
  else
    rename_to="${2:-}"
  fi
  if [ -z "$src" ]; then
    echo "Usage: notify-sound.sh add <path> [as <name>]" >&2
    exit 1
  fi
  case "$src" in "~"*) src="${HOME}${src#~}";; esac

  if [ ! -r "$src" ]; then
    echo "File not readable: $src" >&2
    exit 1
  fi

  local ext name
  ext="${src##*.}"
  local ext_lc valid=0 e
  ext_lc="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  for e in "${SUPPORTED_EXTS[@]}"; do
    [ "$ext_lc" = "$e" ] && valid=1 && break
  done
  if [ "$valid" -ne 1 ]; then
    echo "Unsupported extension: .$ext (allowed: ${SUPPORTED_EXTS[*]})" >&2
    exit 1
  fi

  if [ -n "$rename_to" ]; then
    name="$rename_to"
  else
    name="$(basename "$src")"
    name="${name%.*}"
  fi
  case "$name" in
    ""|*/*|*' '*|.*) echo "Invalid name: '$name'" >&2; exit 1 ;;
  esac

  local dst="$USER_LIB/$name.$ext"
  local existed=0
  [ -e "$dst" ] && existed=1
  cp "$src" "$dst"
  if [ "$existed" -eq 1 ]; then
    printf 'Replaced: %s (from %s)\n' "$name" "$src"
  else
    printf 'Added: %s (from %s)\n' "$name" "$src"
  fi
}

cmd_off() {
  local key
  key="$(resolve_project_key)"
  if [ -z "$key" ]; then
    echo "Cannot determine project. Run /notify off from inside a project directory." >&2
    exit 1
  fi
  rm -f "$STATE_DIR/$key.txt" "$STATE_DIR/$key.stop" "$STATE_DIR/$key.notify"
  printf '%s reset to default sound.\n' "$key"
}

# Resolve which key wins and which sounds will fire for Stop/Notification.
# Echoes three lines: winning_key, stop_sound, notify_sound.
resolve_active_sound() {
  local winning_key=""
  while IFS= read -r key; do
    if [ -r "$STATE_DIR/$key.txt" ] \
       || [ -r "$STATE_DIR/$key.stop" ] \
       || [ -r "$STATE_DIR/$key.notify" ]; then
      winning_key="$key"
      break
    fi
  done < <(resolve_keys)
  [ -z "$winning_key" ] && winning_key="default"

  local generic stop_sound notify_sound
  generic="$DEFAULT_SOUND"
  [ -r "$STATE_DIR/$winning_key.txt" ] && generic="$(head -n1 "$STATE_DIR/$winning_key.txt" | tr -d '[:space:]')"
  stop_sound="$generic"
  notify_sound="$generic"
  [ -r "$STATE_DIR/$winning_key.stop" ]   && stop_sound="$(head -n1 "$STATE_DIR/$winning_key.stop"   | tr -d '[:space:]')"
  [ -r "$STATE_DIR/$winning_key.notify" ] && notify_sound="$(head -n1 "$STATE_DIR/$winning_key.notify" | tr -d '[:space:]')"

  printf '%s\n%s\n%s\n' "$winning_key" "$stop_sound" "$notify_sound"
}

cmd_test() {
  local winning_key stop_sound notify_sound
  { read -r winning_key; read -r stop_sound; read -r notify_sound; } < <(resolve_active_sound)

  printf 'Resolved: %s\n' "$winning_key"
  printf '  Stop:         %s\n' "$stop_sound"
  printf '  Notification: %s\n' "$notify_sound"

  local stop_file notify_file
  stop_file="$(find_sound_file "$stop_sound" || true)"
  if [ -z "$stop_file" ]; then
    printf 'Sound "%s" not in library (Stop).\n' "$stop_sound" >&2
    exit 1
  fi
  play_blocking "$stop_file"

  if [ "$notify_sound" != "$stop_sound" ]; then
    notify_file="$(find_sound_file "$notify_sound" || true)"
    if [ -z "$notify_file" ]; then
      printf 'Sound "%s" not in library (Notification).\n' "$notify_sound" >&2
      exit 1
    fi
    play_blocking "$notify_file"
  fi
}

cmd_key() {
  local found=0
  while IFS= read -r key; do
    local marker=" "
    if [ "$found" -eq 0 ] && { [ -r "$STATE_DIR/$key.txt" ] \
                            || [ -r "$STATE_DIR/$key.stop" ] \
                            || [ -r "$STATE_DIR/$key.notify" ]; }; then
      marker="*"
      found=1
    fi
    printf '  %s %s\n' "$marker" "$key"
  done < <(resolve_keys)
  if [ "$found" -eq 0 ]; then
    echo "  (no state files found; will play bundled 'default' sound)"
  fi
}

cmd_pause() {
  if [ "${1:-}" = "all" ]; then
    : > "$STATE_DIR/paused"
    echo "Paused (global). All projects are silenced until /notify resume all."
    return
  fi
  local key
  key="$(resolve_project_key)"
  if [ -z "$key" ]; then
    echo "Cannot determine project. Run /notify pause from inside a project directory, or use /notify pause all." >&2
    exit 1
  fi
  : > "$STATE_DIR/$key.paused"
  printf 'Paused (%s). Sound assignment preserved; /notify resume to re-enable.\n' "$key"
}

cmd_resume() {
  if [ "${1:-}" = "all" ]; then
    rm -f "$STATE_DIR/paused"
    echo "Resumed (global)."
    return
  fi
  local key
  key="$(resolve_project_key)"
  if [ -z "$key" ]; then
    echo "Cannot determine project. Run /notify resume from inside a project directory, or use /notify resume all." >&2
    exit 1
  fi
  rm -f "$STATE_DIR/$key.paused"
  printf 'Resumed (%s).\n' "$key"
}

cmd_status() {
  local pkey
  pkey="$(resolve_project_key)"

  local global_paused=0 project_paused=0
  [ -e "$STATE_DIR/paused" ] && global_paused=1
  [ -n "$pkey" ] && [ -e "$STATE_DIR/$pkey.paused" ] && project_paused=1

  local state_label="active"
  if [ "$global_paused" -eq 1 ] && [ "$project_paused" -eq 1 ]; then
    state_label="PAUSED (global + project)"
  elif [ "$global_paused" -eq 1 ]; then
    state_label="PAUSED (global)"
  elif [ "$project_paused" -eq 1 ]; then
    state_label="PAUSED (project)"
  fi

  local winning_key stop_sound notify_sound
  { read -r winning_key; read -r stop_sound; read -r notify_sound; } < <(resolve_active_sound)

  local sound_line="$stop_sound"
  [ "$notify_sound" != "$stop_sound" ] && sound_line="$stop_sound / $notify_sound"
  [ "$state_label" != "active" ] && sound_line="$sound_line (silenced)"

  printf 'Project: %s\n' "${pkey:-<unknown>}"
  printf 'Status:  %s\n' "$state_label"
  printf 'Sound:   %s\n' "$sound_line"
  printf '  Stop:         %s\n' "$stop_sound"
  printf '  Notification: %s\n' "$notify_sound"
  echo
  echo "Resolution chain:"
  cmd_key
}

# --- dispatch ----------------------------------------------------------------

cmd="${1:-}"
shift || true

case "$cmd" in
  stop|notify) cmd_play "$cmd" ;;
  set)         cmd_set    "$@" ;;
  list)        cmd_list ;;
  add)         cmd_add    "$@" ;;
  off)         cmd_off ;;
  test)        cmd_test ;;
  pause)       cmd_pause  "$@" ;;
  resume)      cmd_resume "$@" ;;
  status)      cmd_status ;;
  key)         cmd_key ;;
  ""|help|-h|--help)
    sed -n '/^# notify-sound.sh/,/^# ----/p' "$0" | sed 's/^# \{0,1\}//' | sed '/^----/d'
    ;;
  *)
    echo "Unknown subcommand: $cmd" >&2
    echo "Run: notify-sound.sh help" >&2
    exit 1
    ;;
esac
