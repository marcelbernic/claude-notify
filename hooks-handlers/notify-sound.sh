#!/bin/bash
# notify-sound.sh — per-pane sound notifications for Claude Code.
#
# Dispatches on first argument:
#   stop | notify           Hook entry points. Resolves the configured sound
#                           for the current pane and plays it (detached).
#   set <name>              Assign a sound to the current pane.
#   list                    List available sounds (plugin library + user library).
#   add <path> [as <name>]  Copy a custom sound into the user library.
#   off                     Clear pane override (revert to default).
#   test                    Replay the currently configured sound.
#   key                     Print the resolved state key for the current pane.
#
# Layout:
#   ${CLAUDE_PLUGIN_ROOT}/sounds/library/   stock sounds (read-only)
#   ~/.claude/data/notify/library/          user-added sounds
#   ~/.claude/data/notify/state/<key>.txt   per-pane sound assignment
#   ~/.claude/data/notify/state/<key>.stop  Stop-event override (advanced)
#   ~/.claude/data/notify/state/<key>.notify Notification-event override

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

mkdir -p "$USER_LIB" "$STATE_DIR" 2>/dev/null

# --- helpers -----------------------------------------------------------------

resolve_key() {
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'pane-%s' "${TMUX_PANE#%}"
    return
  fi
  if [ ! -t 0 ]; then
    local stdin_json
    stdin_json="$(cat 2>/dev/null || true)"
    if [ -n "$stdin_json" ] && command -v jq >/dev/null 2>&1; then
      local sid
      sid="$(printf '%s' "$stdin_json" | jq -r '.session_id // empty' 2>/dev/null)"
      if [ -n "$sid" ]; then
        printf 'session-%s' "$sid"
        return
      fi
    fi
  fi
  printf 'default'
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
  local key
  key="$(resolve_key)"

  local sound=""
  if [ -r "$STATE_DIR/$key.$event" ]; then
    sound="$(head -n1 "$STATE_DIR/$key.$event" | tr -d '[:space:]')"
  elif [ -r "$STATE_DIR/$key.txt" ]; then
    sound="$(head -n1 "$STATE_DIR/$key.txt" | tr -d '[:space:]')"
  fi
  [ -z "$sound" ] && sound="$DEFAULT_SOUND"

  local file
  file="$(find_sound_file "$sound" || true)"
  if [ -z "$file" ]; then
    printf '[notify-sound] missing sound "%s" (key=%s event=%s)\n' "$sound" "$key" "$event" >&2
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
  key="$(resolve_key)"
  printf '%s\n' "$sound" > "$STATE_DIR/$key.txt"
  play_blocking "$file" || true
  printf 'Pane %s will now play: %s\n' "$key" "$sound"
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
  # Expand ~ if present
  case "$src" in "~"*) src="${HOME}${src#~}";; esac

  if [ ! -r "$src" ]; then
    echo "File not readable: $src" >&2
    exit 1
  fi

  local ext name
  ext="${src##*.}"
  if [ -n "$rename_to" ]; then
    name="$rename_to"
  else
    name="$(basename "$src")"
    name="${name%.*}"
  fi
  case "$name" in
    */*|*' '*|.*) echo "Invalid name: $name" >&2; exit 1 ;;
  esac

  local dst="$USER_LIB/$name.$ext"
  cp "$src" "$dst"
  printf 'Added: %s (from %s)\n' "$name" "$src"
}

cmd_off() {
  local key
  key="$(resolve_key)"
  rm -f "$STATE_DIR/$key.txt" "$STATE_DIR/$key.stop" "$STATE_DIR/$key.notify"
  printf 'Pane %s reset to default sound.\n' "$key"
}

cmd_test() {
  local key sound file
  key="$(resolve_key)"
  sound="$DEFAULT_SOUND"
  [ -r "$STATE_DIR/$key.txt" ] && sound="$(head -n1 "$STATE_DIR/$key.txt" | tr -d '[:space:]')"
  file="$(find_sound_file "$sound" || true)"
  if [ -z "$file" ]; then
    printf 'Sound "%s" not in library.\n' "$sound" >&2
    exit 1
  fi
  printf 'Pane %s → %s\n' "$key" "$sound"
  play_blocking "$file"
}

cmd_key() {
  resolve_key
  echo
}

# --- dispatch ----------------------------------------------------------------

cmd="${1:-}"
shift || true

case "$cmd" in
  stop|notify) cmd_play "$cmd" ;;
  set)         cmd_set  "$@" ;;
  list)        cmd_list ;;
  add)         cmd_add  "$@" ;;
  off)         cmd_off ;;
  test)        cmd_test ;;
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
