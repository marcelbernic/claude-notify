#!/bin/bash
# notify-sound.sh — per-project sound notifications for Claude Code.
#
# Dispatches on first argument:
#   stop | notify           Hook entry points. Resolve the configured sound
#                           (or pack) for the current project and play it.
#   set <name>              Assign a single sound to the current project.
#   list                    List available sounds (plugin library + user library).
#   add <path> [as <name>]  Copy a custom sound into the user library.
#   off                     Clear the current project's assignment.
#   test                    Replay the current assignment (random pick if a pack).
#   preview <name>          Play a single sound once without changing state.
#   pause [all]             Silence this project (or all projects with `all`).
#   resume [all]            Undo pause for this project (or all with `all`).
#   status                  Show pause state, active sound, and resolution chain.
#   key                     Print the resolution chain and which key wins.
#   pack list               List available sound packs.
#   pack contents [<name>]  List sounds in a pack (current pack if omitted).
#   pack exclude <s>...     Temporarily exclude sounds from the current pack.
#   pack include <s>...     Re-include previously excluded sounds.
#   pack reset              Clear all exclusions for the current pack.
#   pack <name>             Assign a pack (anything not matching the above).
#
# Layout:
#   ${CLAUDE_PLUGIN_ROOT}/sounds/library/   stock sounds (read-only)
#   ${CLAUDE_PLUGIN_ROOT}/sounds/packs/     stock packs (read-only)
#   ~/.claude/data/notify/library/          user-added sounds
#   ~/.claude/data/notify/packs/            user-added packs
#   ~/.claude/data/notify/state/<key>.txt   single-sound assignment
#   ~/.claude/data/notify/state/<key>.json  pack assignment + per-pack excludes
#   ~/.claude/data/notify/state/<key>.stop  Stop-event override (advanced)
#   ~/.claude/data/notify/state/<key>.notify Notification-event override
#   ~/.claude/data/notify/state/<key>.paused per-project pause marker
#   ~/.claude/data/notify/state/paused       global pause marker
#   ~/.claude/data/notify/state/<key>.skip-once one-shot Stop-hook suppression
#                                              (set by preview/set/test/pack
#                                              so the trailing Stop hook
#                                              doesn't double-play)
#   ~/.claude/data/notify/cache/             converted-for-Linux audio (lazy)
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
PLUGIN_PACKS="$PLUGIN_ROOT/sounds/packs"
USER_DATA="${HOME}/.claude/data/notify"
USER_LIB="$USER_DATA/library"
USER_PACKS="$USER_DATA/packs"
STATE_DIR="$USER_DATA/state"
CACHE_DIR="$USER_DATA/cache"
DEFAULT_SOUND="default"
SUPPORTED_EXTS=(aiff mp3 wav m4a caf)

mkdir -p "$USER_LIB" "$USER_PACKS" "$STATE_DIR"

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

# Find a pack directory by name. Searches user packs first, then plugin packs.
# Echoes the full path on success, empty on failure.
find_pack_dir() {
  local name="$1"
  for dir in "$USER_PACKS" "$PLUGIN_PACKS"; do
    if [ -d "$dir/$name" ]; then
      printf '%s' "$dir/$name"
      return 0
    fi
  done
  return 1
}

# List all available pack names (one per line, sorted, deduped).
list_packs() {
  {
    [ -d "$USER_PACKS" ]   && find "$USER_PACKS"   -mindepth 1 -maxdepth 1 -type d 2>/dev/null
    [ -d "$PLUGIN_PACKS" ] && find "$PLUGIN_PACKS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null
  } | while IFS= read -r d; do
        [ -n "$d" ] && basename "$d"
      done | sort -u
}

# List sound names (no extension) in a pack directory, sorted, deduped.
pack_sounds() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  local ext
  for ext in "${SUPPORTED_EXTS[@]}"; do
    find "$dir" -mindepth 1 -maxdepth 1 -type f -name "*.$ext" 2>/dev/null \
      | while IFS= read -r f; do
          local b="${f##*/}"
          printf '%s\n' "${b%.*}"
        done
  done | sort -u
}

# Path to the JSON state file for a key.
state_json_path() {
  printf '%s/%s.json' "$STATE_DIR" "$1"
}

# Read the active pack name from <key>.json. Empty if no pack assigned.
state_read_pack() {
  local key="$1" path
  path="$(state_json_path "$key")"
  [ -r "$path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.pack // empty' "$path" 2>/dev/null
}

# Read the exclude list for (key, pack), one name per line.
state_read_excludes() {
  local key="$1" pack="$2" path
  path="$(state_json_path "$key")"
  [ -r "$path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg p "$pack" '.excludeByPack[$p] // [] | .[]' "$path" 2>/dev/null
}

# Apply a jq filter (with optional --arg / --argjson args) to <key>.json.
# Creates the file from {} if missing.
state_update_json() {
  local key="$1"; shift
  if ! command -v jq >/dev/null 2>&1; then
    echo "[notify-sound] jq is required to manage pack state" >&2
    return 1
  fi
  local path tmp
  path="$(state_json_path "$key")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/notify-state.XXXXXX")"
  if [ -r "$path" ]; then
    if ! jq "$@" "$path" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      echo "[notify-sound] failed to update $path" >&2
      return 1
    fi
  else
    if ! printf '{}' | jq "$@" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      return 1
    fi
  fi
  mv "$tmp" "$path"
}

state_set_pack() {
  local key="$1" pack="$2"
  state_update_json "$key" --arg p "$pack" \
    '.pack = $p | .excludeByPack //= {} | .excludeByPack[$p] //= []'
}

state_clear_pack() {
  local key="$1" path
  path="$(state_json_path "$key")"
  [ -r "$path" ] || return 0
  state_update_json "$key" '.pack = null'
}

state_add_excludes() {
  local key="$1" pack="$2"; shift 2
  local arr
  arr="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  state_update_json "$key" --arg p "$pack" --argjson new "$arr" \
    '.excludeByPack //= {} |
     .excludeByPack[$p] = ((.excludeByPack[$p] // []) + $new | unique)'
}

state_remove_excludes() {
  local key="$1" pack="$2"; shift 2
  local arr
  arr="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  state_update_json "$key" --arg p "$pack" --argjson rem "$arr" \
    '.excludeByPack //= {} |
     .excludeByPack[$p] = ((.excludeByPack[$p] // []) - $rem)'
}

state_reset_excludes() {
  local key="$1" pack="$2"
  state_update_json "$key" --arg p "$pack" \
    '.excludeByPack //= {} | .excludeByPack[$p] = []'
}

# Pick a random sound from a pack, honoring an exclude list.
# $1 = pack dir; $2.. = excluded sound names.
# On success, prints "<name><TAB><file_path>" and returns 0.
pick_random_pack_sound() {
  local dir="$1"; shift
  local excludes=("$@")

  local sounds=()
  local s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    local skip=0 x
    for x in ${excludes[@]+"${excludes[@]}"}; do
      if [ "$s" = "$x" ]; then skip=1; break; fi
    done
    [ "$skip" -eq 0 ] && sounds+=("$s")
  done < <(pack_sounds "$dir")

  local count="${#sounds[@]}"
  [ "$count" -eq 0 ] && return 1

  local idx=$(( RANDOM % count ))
  local name="${sounds[$idx]}"

  local ext
  for ext in "${SUPPORTED_EXTS[@]}"; do
    if [ -r "$dir/$name.$ext" ]; then
      printf '%s\t%s' "$name" "$dir/$name.$ext"
      return 0
    fi
  done
  return 1
}

# --- audio playback (cross-platform) ----------------------------------------

# Player probe order: macOS first, then common Linux options. Players later in
# the list (aplay) handle fewer formats; we lean on prepare_playable_file to
# bridge the gap via conversion.
AUDIO_PLAYERS=(afplay paplay pw-play ffplay play mpv aplay)
_AUDIO_PLAYER=""
_AUDIO_PLAYER_PROBED=0
_WARNED_NO_PLAYER=0
_WARNED_CONVERT=0

# Echo the first available audio player (or empty); cache after first probe.
select_audio_player() {
  if [ "$_AUDIO_PLAYER_PROBED" -eq 1 ]; then
    printf '%s' "$_AUDIO_PLAYER"
    return 0
  fi
  _AUDIO_PLAYER_PROBED=1
  local p
  for p in "${AUDIO_PLAYERS[@]}"; do
    if command -v "$p" >/dev/null 2>&1; then
      _AUDIO_PLAYER="$p"
      break
    fi
  done
  printf '%s' "$_AUDIO_PLAYER"
}

# Invoke <player> on <file>. mode = "detached" (background) or "blocking".
play_with() {
  local player="$1" file="$2" mode="$3"
  local cmd=()
  case "$player" in
    afplay)               cmd=(afplay "$file") ;;
    paplay|pw-play)       cmd=("$player" "$file") ;;
    aplay)                cmd=(aplay -q "$file") ;;
    ffplay)               cmd=(ffplay -nodisp -autoexit -loglevel quiet "$file") ;;
    play)                 cmd=(play -q "$file") ;;
    mpv)                  cmd=(mpv --really-quiet --no-video "$file") ;;
    *) return 127 ;;
  esac
  if [ "$mode" = "detached" ]; then
    ( "${cmd[@]}" >/dev/null 2>&1 & ) >/dev/null 2>&1
  else
    "${cmd[@]}" >/dev/null 2>&1
  fi
}

# 0 if the file should be converted to WAV before passing to <player>.
needs_conversion() {
  local player="$1" file="$2" ext
  ext="${file##*.}"
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  case "$player" in
    afplay|ffplay|mpv|play) return 1 ;;       # handle ~everything we ship
    paplay|pw-play)
      case "$ext" in
        wav|aiff|aif|aifc|flac|ogg|oga|au) return 1 ;;
        *) return 0 ;;
      esac ;;
    aplay)
      case "$ext" in wav) return 1 ;; *) return 0 ;; esac ;;
  esac
  return 1
}

# Short stable hash of a string. shasum is on macOS; sha1sum on Linux.
hash_path() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum | cut -c1-12
  elif command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -c1-12
  else
    printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'
  fi
}

# Convert <src> to <dst> as WAV using whichever tool is available. 0 on success.
convert_to_wav() {
  local src="$1" dst="$2" tmp
  mkdir -p "$(dirname "$dst")"
  tmp="${dst}.tmp.$$.wav"
  if command -v ffmpeg >/dev/null 2>&1; then
    if ffmpeg -y -loglevel error -i "$src" -f wav "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$dst" && return 0
    fi
  elif command -v sox >/dev/null 2>&1; then
    if sox "$src" -t wav "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$dst" && return 0
    fi
  elif command -v afconvert >/dev/null 2>&1; then
    if afconvert -f WAVE -d LEI16 "$src" "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$dst" && return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

# Return a path the selected player can play. Lazily converts and caches.
# Falls back to the original path with a warning if conversion isn't possible.
prepare_playable_file() {
  local file="$1" player
  player="$(select_audio_player)"
  if [ -z "$player" ] || ! needs_conversion "$player" "$file"; then
    printf '%s' "$file"
    return 0
  fi
  local base hash cached
  base="$(basename "$file")"
  base="${base%.*}"
  hash="$(hash_path "$file")"
  cached="$CACHE_DIR/${base}-${hash}.wav"
  if [ -r "$cached" ]; then
    printf '%s' "$cached"
    return 0
  fi
  if convert_to_wav "$file" "$cached"; then
    printf '%s' "$cached"
    return 0
  fi
  if [ "$_WARNED_CONVERT" -eq 0 ]; then
    printf '[notify-sound] cannot convert %s for player %s — install ffmpeg or sox; playback may fail\n' \
      "$file" "$player" >&2
    _WARNED_CONVERT=1
  fi
  printf '%s' "$file"
}

_warn_no_player() {
  if [ "$_WARNED_NO_PLAYER" -eq 0 ]; then
    printf '[notify-sound] no audio player found (looked for: %s)\n' "${AUDIO_PLAYERS[*]}" >&2
    _WARNED_NO_PLAYER=1
  fi
}

play_detached() {
  local file="$1" player playable
  player="$(select_audio_player)"
  if [ -z "$player" ]; then _warn_no_player; return 1; fi
  playable="$(prepare_playable_file "$file")"
  play_with "$player" "$playable" detached
}

play_blocking() {
  local file="$1" player playable
  player="$(select_audio_player)"
  if [ -z "$player" ]; then _warn_no_player; return 1; fi
  playable="$(prepare_playable_file "$file")"
  if ! play_with "$player" "$playable" blocking; then
    printf '[notify-sound] %s failed to play %s\n' "$player" "$playable" >&2
    return 1
  fi
}

# Suppress the next sound-playing hook fire for this project. User-facing
# commands (preview, set, test, pack <name>) call this so the Stop hook that
# fires when Claude echoes the slash-command output doesn't double-play.
mark_skip_next() {
  local key
  key="$(resolve_project_key)"
  [ -n "$key" ] && : > "$STATE_DIR/$key.skip-once"
}

# Validate a name token (sound or pack) — no slashes, spaces, or leading dot.
validate_name() {
  case "${1:-}" in
    ""|*/*|*' '*|.*)
      echo "Invalid name: '${1:-}'" >&2
      return 1
      ;;
  esac
  return 0
}

# --- subcommands -------------------------------------------------------------

cmd_play() {
  local event="$1"
  local cwd_hint
  cwd_hint="$(read_hook_cwd)"

  local pkey
  pkey="$(resolve_project_key "$cwd_hint")"

  # One-shot skip: a user-facing command just played a sound and doesn't want
  # the trailing Stop hook to double-play. Consume the marker before the pause
  # checks so previewing while paused doesn't leave the marker orphaned.
  if [ -n "$pkey" ] && [ -e "$STATE_DIR/$pkey.skip-once" ]; then
    rm -f "$STATE_DIR/$pkey.skip-once"
    exit 0
  fi

  [ -e "$STATE_DIR/paused" ] && exit 0
  [ -n "$pkey" ] && [ -e "$STATE_DIR/$pkey.paused" ] && exit 0

  local sound="" file="" winning_key=""
  while IFS= read -r key; do
    # 1. Per-event single-sound override (highest priority).
    if [ -r "$STATE_DIR/$key.$event" ]; then
      sound="$(head -n1 "$STATE_DIR/$key.$event" | tr -d '[:space:]')"
      winning_key="$key"
      break
    fi

    # 2. Pack assignment via JSON state.
    local pack
    pack="$(state_read_pack "$key")"
    if [ -n "$pack" ]; then
      local pack_dir
      pack_dir="$(find_pack_dir "$pack" || true)"
      if [ -z "$pack_dir" ]; then
        printf '[notify-sound] pack "%s" not found (key=%s)\n' "$pack" "$key" >&2
      else
        local excludes=()
        local ex
        while IFS= read -r ex; do
          [ -n "$ex" ] && excludes+=("$ex")
        done < <(state_read_excludes "$key" "$pack")

        local picked
        picked="$(pick_random_pack_sound "$pack_dir" ${excludes[@]+"${excludes[@]}"} 2>/dev/null || true)"
        if [ -n "$picked" ]; then
          sound="${picked%%$'\t'*}"
          file="${picked#*$'\t'}"
          winning_key="$key (pack:$pack)"
          break
        else
          printf '[notify-sound] pack "%s" empty after exclusions (key=%s)\n' "$pack" "$key" >&2
        fi
      fi
    fi

    # 3. Legacy single-sound assignment.
    if [ -r "$STATE_DIR/$key.txt" ]; then
      sound="$(head -n1 "$STATE_DIR/$key.txt" | tr -d '[:space:]')"
      winning_key="$key"
      break
    fi
  done < <(resolve_keys "$cwd_hint")

  if [ -z "$sound" ]; then
    sound="$DEFAULT_SOUND"
    winning_key="default"
  fi

  if [ -z "$file" ]; then
    file="$(find_sound_file "$sound" || true)"
  fi
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
  validate_name "$sound" || exit 1

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
  # Single-sound assignment supersedes any pack assignment, but per-pack
  # exclusions are preserved for if/when the user comes back.
  state_clear_pack "$key" || true
  printf '%s will now play: %s\n' "$key" "$sound"
  mark_skip_next
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
  validate_name "$name" || exit 1

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
  rm -f "$STATE_DIR/$key.txt" "$STATE_DIR/$key.stop" "$STATE_DIR/$key.notify" \
        "$STATE_DIR/$key.json" "$STATE_DIR/$key.skip-once"
  printf '%s reset to default sound.\n' "$key"
}

# Resolve which key wins and which sounds will fire for Stop/Notification.
# Echoes five lines (file paths are empty when the caller should look them up
# via find_sound_file — i.e. single-sound mode):
#   winning_key      (annotated with " (pack: <name>)" in pack mode)
#   stop_sound
#   stop_file        (set in pack mode, empty otherwise)
#   notify_sound
#   notify_file      (set in pack mode, empty otherwise)
resolve_active_sound() {
  local winning_key=""
  while IFS= read -r key; do
    if [ -r "$STATE_DIR/$key.txt" ] \
       || [ -r "$STATE_DIR/$key.stop" ] \
       || [ -r "$STATE_DIR/$key.notify" ] \
       || [ -n "$(state_read_pack "$key")" ]; then
      winning_key="$key"
      break
    fi
  done < <(resolve_keys)
  [ -z "$winning_key" ] && winning_key="default"

  local pack
  pack="$(state_read_pack "$winning_key")"

  if [ -n "$pack" ] \
     && [ ! -r "$STATE_DIR/$winning_key.stop" ] \
     && [ ! -r "$STATE_DIR/$winning_key.notify" ]; then
    # Pure pack mode: pick one random sound; same for both events.
    local pack_dir
    pack_dir="$(find_pack_dir "$pack" || true)"
    if [ -z "$pack_dir" ]; then
      printf 'Pack "%s" not found.\n' "$pack" >&2
      exit 1
    fi
    local excludes=() ex
    while IFS= read -r ex; do
      [ -n "$ex" ] && excludes+=("$ex")
    done < <(state_read_excludes "$winning_key" "$pack")

    local picked
    picked="$(pick_random_pack_sound "$pack_dir" ${excludes[@]+"${excludes[@]}"} 2>/dev/null || true)"
    if [ -z "$picked" ]; then
      printf 'Pack "%s" has no playable sounds (after exclusions).\n' "$pack" >&2
      exit 1
    fi
    local sound="${picked%%$'\t'*}"
    local file="${picked#*$'\t'}"
    printf '%s (pack: %s)\n%s\n%s\n%s\n%s\n' \
      "$winning_key" "$pack" "$sound" "$file" "$sound" "$file"
    return
  fi

  # Single-sound mode (with optional per-event overrides).
  local generic stop_sound notify_sound
  generic="$DEFAULT_SOUND"
  [ -r "$STATE_DIR/$winning_key.txt" ] && generic="$(head -n1 "$STATE_DIR/$winning_key.txt" | tr -d '[:space:]')"
  stop_sound="$generic"
  notify_sound="$generic"
  [ -r "$STATE_DIR/$winning_key.stop" ]   && stop_sound="$(head -n1 "$STATE_DIR/$winning_key.stop"   | tr -d '[:space:]')"
  [ -r "$STATE_DIR/$winning_key.notify" ] && notify_sound="$(head -n1 "$STATE_DIR/$winning_key.notify" | tr -d '[:space:]')"

  printf '%s\n%s\n\n%s\n\n' "$winning_key" "$stop_sound" "$notify_sound"
}

cmd_preview() {
  local sound="${1:-}"
  if [ -z "$sound" ]; then
    echo "Usage: notify-sound.sh preview <sound>" >&2
    exit 1
  fi
  validate_name "$sound" || exit 1
  local file
  file="$(find_sound_file "$sound" || true)"
  if [ -z "$file" ]; then
    echo "Sound '$sound' not in library. Try: notify-sound.sh list" >&2
    exit 1
  fi
  printf 'Previewing: %s\n' "$sound"
  mark_skip_next
  play_blocking "$file" || true
}

cmd_test() {
  local winning_key stop_sound stop_file notify_sound notify_file
  { read -r winning_key
    read -r stop_sound
    read -r stop_file
    read -r notify_sound
    read -r notify_file
  } < <(resolve_active_sound)

  printf 'Resolved: %s\n' "$winning_key"
  printf '  Stop:         %s\n' "$stop_sound"
  printf '  Notification: %s\n' "$notify_sound"

  [ -z "$stop_file" ] && stop_file="$(find_sound_file "$stop_sound" || true)"
  if [ -z "$stop_file" ]; then
    printf 'Sound "%s" not in library (Stop).\n' "$stop_sound" >&2
    exit 1
  fi
  mark_skip_next
  play_blocking "$stop_file"

  if [ "$notify_sound" != "$stop_sound" ] || [ "$notify_file" != "$stop_file" ]; then
    [ -z "$notify_file" ] && notify_file="$(find_sound_file "$notify_sound" || true)"
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
    local marker=" " kind=""
    if [ "$found" -eq 0 ]; then
      if [ -r "$STATE_DIR/$key.stop" ] || [ -r "$STATE_DIR/$key.notify" ]; then
        marker="*"
        kind=" (per-event override)"
        found=1
      elif [ -n "$(state_read_pack "$key")" ]; then
        marker="*"
        kind=" (pack: $(state_read_pack "$key"))"
        found=1
      elif [ -r "$STATE_DIR/$key.txt" ]; then
        marker="*"
        kind=" (sound: $(head -n1 "$STATE_DIR/$key.txt" | tr -d '[:space:]'))"
        found=1
      fi
    fi
    printf '  %s %s%s\n' "$marker" "$key" "$kind"
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

  local winning_key stop_sound stop_file notify_sound notify_file
  { read -r winning_key
    read -r stop_sound
    read -r stop_file
    read -r notify_sound
    read -r notify_file
  } < <(resolve_active_sound)

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

# --- pack subcommands --------------------------------------------------------

cmd_pack_list() {
  local any=0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    any=1
    local dir count
    dir="$(find_pack_dir "$p" || true)"
    count="$(pack_sounds "$dir" | wc -l | tr -d '[:space:]')"
    printf '  %s  (%s sounds)\n' "$p" "$count"
  done < <(list_packs)
  if [ "$any" -eq 0 ]; then
    echo "(no packs found)"
    echo "Add audio files under:"
    echo "  $PLUGIN_PACKS/<PackName>/   (bundled with plugin)"
    echo "  $USER_PACKS/<PackName>/   (user)"
  fi
}

cmd_pack_set() {
  local pack="${1:-}"
  if [ -z "$pack" ]; then
    echo "Usage: notify-sound.sh pack <name>" >&2
    exit 1
  fi
  validate_name "$pack" || exit 1

  local pack_dir
  pack_dir="$(find_pack_dir "$pack" || true)"
  if [ -z "$pack_dir" ]; then
    echo "Pack '$pack' not found. Try: notify-sound.sh pack list" >&2
    exit 1
  fi

  local sound_count
  sound_count="$(pack_sounds "$pack_dir" | wc -l | tr -d '[:space:]')"
  if [ "$sound_count" -eq 0 ]; then
    printf "Pack '%s' has no sound files (looked in %s).\n" "$pack" "$pack_dir" >&2
    printf "Drop %s files into the folder and try again.\n" "${SUPPORTED_EXTS[*]}" >&2
    exit 1
  fi

  local key
  key="$(resolve_project_key)"
  if [ -z "$key" ]; then
    echo "Cannot determine project. Run /notify pack from inside a project directory." >&2
    exit 1
  fi

  state_set_pack "$key" "$pack" || exit 1
  rm -f "$STATE_DIR/$key.txt"

  local excludes=() ex
  while IFS= read -r ex; do
    [ -n "$ex" ] && excludes+=("$ex")
  done < <(state_read_excludes "$key" "$pack")

  local excl_count="${#excludes[@]}"
  printf '%s will now play random sounds from pack: %s (%s sounds' "$key" "$pack" "$sound_count"
  if [ "$excl_count" -gt 0 ]; then
    printf ', %s excluded' "$excl_count"
  fi
  printf ')\n'

  local picked
  picked="$(pick_random_pack_sound "$pack_dir" ${excludes[@]+"${excludes[@]}"} 2>/dev/null || true)"
  if [ -n "$picked" ]; then
    local sound="${picked%%$'\t'*}"
    local file="${picked#*$'\t'}"
    printf '  Preview: %s\n' "$sound"
    mark_skip_next
    play_blocking "$file" || true
  fi
}

cmd_pack_contents() {
  local pack="${1:-}"
  local key
  key="$(resolve_project_key)"
  if [ -z "$pack" ]; then
    [ -n "$key" ] && pack="$(state_read_pack "$key")"
    if [ -z "$pack" ]; then
      echo "Usage: notify-sound.sh pack contents [<name>]" >&2
      echo "(no pack assigned to this project; pass a pack name)" >&2
      exit 1
    fi
  fi
  validate_name "$pack" || exit 1

  local pack_dir
  pack_dir="$(find_pack_dir "$pack" || true)"
  if [ -z "$pack_dir" ]; then
    echo "Pack '$pack' not found." >&2
    exit 1
  fi

  local excludes=() ex
  if [ -n "$key" ]; then
    while IFS= read -r ex; do
      [ -n "$ex" ] && excludes+=("$ex")
    done < <(state_read_excludes "$key" "$pack")
  fi

  printf '%s  (%s)\n' "$pack" "$pack_dir"
  local total=0 excluded=0
  local s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    total=$((total+1))
    local marker=""
    local x
    for x in ${excludes[@]+"${excludes[@]}"}; do
      if [ "$s" = "$x" ]; then marker="  [excluded]"; excluded=$((excluded+1)); break; fi
    done
    printf '  %s%s\n' "$s" "$marker"
  done < <(pack_sounds "$pack_dir")

  if [ "$total" -eq 0 ]; then
    printf '  (empty — drop %s files into %s)\n' "${SUPPORTED_EXTS[*]}" "$pack_dir"
  else
    printf '%s sounds total, %s excluded\n' "$total" "$excluded"
  fi
}

# Common helper for cmd_pack_exclude / cmd_pack_include.
_pack_mutate_excludes() {
  local mode="$1"; shift
  if [ "$#" -eq 0 ]; then
    echo "Usage: notify-sound.sh pack $mode <sound>..." >&2
    exit 1
  fi

  local key
  key="$(resolve_project_key)"
  if [ -z "$key" ]; then
    echo "Cannot determine project. Run /notify pack $mode from inside a project directory." >&2
    exit 1
  fi

  local pack
  pack="$(state_read_pack "$key")"
  if [ -z "$pack" ]; then
    echo "No pack assigned to $key. Run /notify pack <name> first." >&2
    exit 1
  fi

  local pack_dir
  pack_dir="$(find_pack_dir "$pack" || true)"
  if [ -z "$pack_dir" ]; then
    echo "Pack '$pack' not found (referenced by $key state)." >&2
    exit 1
  fi

  # Validate each name exists in the pack.
  local available=() s
  while IFS= read -r s; do
    [ -n "$s" ] && available+=("$s")
  done < <(pack_sounds "$pack_dir")

  local arg
  for arg in "$@"; do
    validate_name "$arg" || exit 1
    local found=0 a
    for a in ${available[@]+"${available[@]}"}; do
      if [ "$a" = "$arg" ]; then found=1; break; fi
    done
    if [ "$found" -eq 0 ]; then
      printf "Sound '%s' is not in pack '%s'.\n" "$arg" "$pack" >&2
      printf 'Available: %s\n' "${available[*]}" >&2
      exit 1
    fi
  done

  if [ "$mode" = "exclude" ]; then
    state_add_excludes "$key" "$pack" "$@" || exit 1
    printf 'Excluded from %s: %s\n' "$pack" "$*"
  else
    state_remove_excludes "$key" "$pack" "$@" || exit 1
    printf 'Re-included in %s: %s\n' "$pack" "$*"
  fi
}

cmd_pack_exclude() { _pack_mutate_excludes exclude "$@"; }
cmd_pack_include() { _pack_mutate_excludes include "$@"; }

cmd_pack_reset() {
  local key
  key="$(resolve_project_key)"
  if [ -z "$key" ]; then
    echo "Cannot determine project. Run /notify pack reset from inside a project directory." >&2
    exit 1
  fi
  local pack
  pack="$(state_read_pack "$key")"
  if [ -z "$pack" ]; then
    echo "No pack assigned to $key." >&2
    exit 1
  fi
  state_reset_excludes "$key" "$pack" || exit 1
  printf 'Cleared exclusions for %s on pack %s.\n' "$key" "$pack"
}

cmd_pack() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    "")         echo "Usage: notify-sound.sh pack <list|contents|exclude|include|reset|name>" >&2; exit 1 ;;
    list)       cmd_pack_list ;;
    contents)   cmd_pack_contents "$@" ;;
    exclude)    cmd_pack_exclude  "$@" ;;
    include)    cmd_pack_include  "$@" ;;
    reset)      cmd_pack_reset ;;
    *)          cmd_pack_set     "$sub" ;;
  esac
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
  preview)     cmd_preview "$@" ;;
  pause)       cmd_pause  "$@" ;;
  resume)      cmd_resume "$@" ;;
  status)      cmd_status ;;
  key)         cmd_key ;;
  pack)        cmd_pack "$@" ;;
  ""|help|-h|--help)
    sed -n '/^# notify-sound.sh/,/^# ----/p' "$0" | sed 's/^# \{0,1\}//' | sed '/^----/d'
    ;;
  *)
    echo "Unknown subcommand: $cmd" >&2
    echo "Run: notify-sound.sh help" >&2
    exit 1
    ;;
esac
