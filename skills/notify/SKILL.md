---
name: notify
description: >
  Configure the per-project notification sound for the current Claude Code
  session. Use when the user invokes /notify with a sound name, or with one
  of the subcommands: list, off, test, add, pause, resume, status. Sets
  which sound fires on Stop and Notification hooks for the current project
  (keyed by git-root / cwd basename), and toggles pause state per-project
  or globally.
argument-hint: <sound> | list | off | test | add <path> [as <name>] | pause [all] | resume [all] | status
---

## Purpose

Thin wrapper around `${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh`.
The script implements all logic; this skill parses the user's argument
string and calls the appropriate subcommand.

The sound is bound to the **project** (the current cwd's git-root, or the
cwd's basename when not in a git repo). All Claude panes/sessions
operating in the same project share the same sound.

## How to handle the user's arguments

Let `$ARGS` be the user-provided argument string (may be empty or have
multiple words). The first word selects the action:

| First word | Action |
|---|---|
| `list`   | Run `notify-sound.sh list` |
| `off`    | Run `notify-sound.sh off` |
| `test`   | Run `notify-sound.sh test` |
| `add`    | Parse `add <path> [as <name>]`, run `notify-sound.sh add <path> [<name>]` |
| `pause`  | Run `notify-sound.sh pause` (or `notify-sound.sh pause all` if `all` follows) |
| `resume` | Run `notify-sound.sh resume` (or `notify-sound.sh resume all` if `all` follows) |
| `status` | Run `notify-sound.sh status` |
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

User: `/notify pause` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" pause`

User: `/notify pause all` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" pause all`

User: `/notify resume` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" resume`

User: `/notify status` → `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" status`

## Edge cases

- **Sound name with slashes, spaces, or leading dot**: the script rejects
  these. Surface the script's stderr to the user verbatim.
- **`add` source path not readable**: the script exits non-zero with a
  clear message; surface it.
- **No project resolvable**: `set` and `off` refuse with "Cannot
  determine project. Run /notify from inside a project directory."
  Surface the script's error verbatim.
- **Legacy `pane-<id>` state files**: still read as a fallback for users
  upgrading from v0.1's pane-keyed scheme. Once the user runs `/notify`
  in that project, the project-keyed file takes over and the legacy
  pane file is shadowed.

## Per-event sounds (advanced)

To set different sounds for "Claude finished" vs "Claude needs input",
the user can write directly to the state files:

```bash
echo morse     > ~/.claude/data/notify/state/project-<slug>.stop
echo submarine > ~/.claude/data/notify/state/project-<slug>.notify
```

Run `notify-sound.sh key` from the project to see the exact slug. The
script prefers `<key>.stop`/`<key>.notify` over the generic `<key>.txt`.
