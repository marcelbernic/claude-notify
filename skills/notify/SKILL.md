---
name: notify
description: >
  Configure the per-pane notification sound for the current Claude Code
  session. Use when the user invokes /notify with a sound name, or with one
  of the subcommands: list, off, test, add. Sets which sound fires on Stop
  and Notification hooks for the current tmux pane (or "default" key when
  not in tmux).
argument-hint: <sound> | list | off | test | add <path> [as <name>]
---

## Purpose

Thin wrapper around `${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh`.
The script implements all logic; this skill parses the user's argument
string and calls the appropriate subcommand.

## How to handle the user's arguments

Let `$ARGS` be the user-provided argument string (may be empty or have
multiple words). The first word selects the action:

| First word | Action |
|---|---|
| `list` | Run `notify-sound.sh list` |
| `off`  | Run `notify-sound.sh off` |
| `test` | Run `notify-sound.sh test` |
| `add`  | Parse `add <path> [as <name>]`, run `notify-sound.sh add <path> [<name>]` |
| anything else (single word) | Treat as a sound name; run `notify-sound.sh set <word>` |
| empty | Show help: run `notify-sound.sh help` |

Always invoke the script via:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" <subcommand> <args...>
```

so the script resolves its own paths from the plugin root.

### `add` parsing detail

Input shape: `add <path> [as <name>]`

- If the words after `<path>` are exactly `as <name>`, pass `<path>` and
  `<name>` as two positional arguments to the script.
- If the path contains `~`, leave it — the script expands it.
- If only `<path>` is given, pass just `<path>`; the script derives the
  name from the basename without extension.

### Examples

User: `/notify cow` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" set cow`

User: `/notify list` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" list`

User: `/notify add ~/Downloads/moo.wav` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" add ~/Downloads/moo.wav`

User: `/notify add ~/Downloads/moo.wav as cow` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" add ~/Downloads/moo.wav cow`

User: `/notify off` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" off`

User: `/notify test` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" test`

## Edge cases

- **Sound name with slashes, spaces, or leading dot**: the script rejects
  these. Surface the script's stderr to the user verbatim.
- **`add` source path not readable**: the script exits non-zero with a
  clear message; surface it.
- **Not in tmux**: `$TMUX_PANE` is empty, the resolved key becomes
  `default`. The skill should mention this in the output: "Note: not
  inside tmux — this sound will apply to all non-tmux Claude sessions."

## Per-event sounds (advanced)

To set different sounds for "Claude finished" vs "Claude needs input",
the user can write directly to the state files:

```bash
echo morse     > ~/.claude/data/notify/state/<key>.stop
echo submarine > ~/.claude/data/notify/state/<key>.notify
```

The skill does not expose this directly; only mention if asked. The script
prefers `<key>.stop`/`<key>.notify` over the generic `<key>.txt`.
