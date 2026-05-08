# claude-notify

Per-pane sound notifications for Claude Code. Plays a configurable sound
when Claude finishes a turn or needs your attention. Built for tmux users
running multiple Claude sessions in parallel — each pane plays a different
sound, so you can tell which one needs you without looking.

> Status: v0.1 — works on macOS, single-author, no Linux/Windows support
> yet. Friends-and-family release. Bug reports and PRs welcome.

---

## Install

```
/plugin marketplace add <git-url-of-this-repo>
/plugin install notify@claude-notify
```

Restart Claude Code after install (hooks are loaded once at startup).

## Usage

In any Claude Code session inside a tmux pane:

```
/notify list           # see available sounds
/notify frog           # this pane plays frog from now on
/notify test           # replay the currently set sound
/notify off            # clear this pane (revert to default)
/notify add ~/Downloads/cow.wav         # copy a custom sound into your library
/notify add ~/Downloads/cow.wav as moo  # …and rename it on the way in
```

After `/notify frog`, you'll hear the frog sound when:
- Claude finishes a turn (`Stop` event)
- Claude needs your input — permission prompts, idle waits, MCP elicitations (`Notification` event)

Open more tmux panes, give each a different sound, run Claude in each.
You'll always know which pane is calling for you.

## How it works

Two hooks register on install:

| Hook event | Fires on | Action |
|---|---|---|
| `Stop` | Claude finishes its response | Play the pane's configured sound |
| `Notification` | Claude needs user attention | Same script, same sound |

State lives outside the plugin so it survives upgrades and uninstalls
cleanly:

```
~/.claude/data/notify/
├── library/          # your custom-added sounds
└── state/
    ├── pane-40.txt   # contents: "frog"   (set via /notify frog in pane %40)
    ├── pane-41.txt   # contents: "morse"
    └── default.txt   # used when not in tmux
```

The plugin's bundled sounds live in `${CLAUDE_PLUGIN_ROOT}/sounds/library/`
and are read-only. The script searches your user library first, then the
bundled library — so a custom `frog.wav` in user lib overrides the
bundled `frog.aiff`.

## Per-event sounds (advanced)

Want different sounds for "Claude finished" vs "Claude needs input"?
Bypass `/notify` and write directly:

```bash
echo morse     > ~/.claude/data/notify/state/pane-40.stop
echo submarine > ~/.claude/data/notify/state/pane-40.notify
```

These take precedence over the generic `pane-40.txt`.

## Caveats

**1. macOS only (today).** Uses `afplay`. Linux support would need
swapping for `paplay`/`aplay`. PRs welcome.

**2. New sessions only.** `settings.json` and plugin hooks are read once
at Claude Code startup. The session you installed from won't fire hooks
until you restart it.

**3. `$TMUX_PANE` must propagate.** The pane key relies on `$TMUX_PANE`
being in Claude Code's environment, which requires you launched `claude`
from inside a tmux pane (the standard way). Outside tmux, all sessions
share the `default` key.

**4. Sounds overlap on rapid events.** If Claude finishes a turn and
immediately needs input on the next tool call, both hooks fire — you'll
hear two sounds nearly simultaneously. Keep custom sounds short (<2s) to
minimize this.

**5. macOS `Downloads`/`Documents` are sandboxed.** Adding a sound from
`~/Downloads/` may fail with "Operation not permitted" — macOS TCC
blocking. Either move the file to `/tmp` first, or grant Claude Code's
parent terminal "Files & Folders → Downloads" in System Settings →
Privacy & Security.

**6. The `Notification` event has subtypes.** It fires for several
reasons (`permission_prompt`, `idle_prompt`, `auth_success`,
`elicitation_dialog`). The plugin doesn't distinguish — same sound for
any. Filtering by subtype would require extending the script to inspect
the JSON payload.

## Troubleshooting

```bash
# Verify the script works in isolation
bash "${CLAUDE_PLUGIN_ROOT:-$(dirname $0)}/hooks-handlers/notify-sound.sh" help

# Check what key your current pane resolves to
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" key

# Check what sound is configured
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" test
```

If sounds don't play after install:
1. Restart Claude Code (caveat 2).
2. Run `/plugin list` and confirm `notify@claude-notify` is enabled.
3. Run the script manually with a fake event payload:
   ```
   echo '{}' | bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" stop
   ```

## Bundled sounds and licensing

The 15 `.aiff` files in `sounds/library/` (basso, blow, bottle, default,
frog, funk, glass, hero, morse, ping, pop, purr, sosumi, submarine, tink)
are copies of macOS system sounds from `/System/Library/Sounds/`. They are
**Apple's intellectual property** and are bundled here for personal-use
convenience only. If you fork or redistribute this plugin publicly, you
should remove them and have the plugin copy from the user's local
`/System/Library/Sounds/` at install time, or substitute CC0/permissively
licensed sounds.

`cow.wav` is a placeholder example. Replace with your own.

The plugin code (everything except the `.aiff`/`.wav` files) is MIT
licensed. See `LICENSE`.

## Roadmap

- [ ] Linux support (paplay/aplay branch in the script)
- [ ] Volume control: `/notify volume 0.3` per pane
- [ ] Optional spoken project name via `say` on Stop
- [ ] Subtype filtering for `Notification` (silence `auth_success`)
- [ ] Per-event sounds via skill (no manual file editing)
- [ ] Rate limit: max one sound per N seconds per pane
- [ ] Cross-platform sound seeding on first run
- [ ] Replace bundled Apple sounds with CC0 alternatives

## Contributing

Issues and PRs welcome. Test changes locally with:

```
/plugin marketplace remove claude-notify    # if previously installed
cd /path/to/claude-notify
git switch -c my-change
# edit
/plugin marketplace add /path/to/claude-notify    # local file path works
/plugin install notify@claude-notify
```

## Credits

Built by [Marcel Bernic](mailto:marcel@numa.com) with help from Claude.
