# claude-notify

Per-project sound notifications for Claude Code. Plays a configurable
sound when Claude finishes a turn or needs your attention. Each project
(repo / working directory) plays its own sound, no matter which tmux
pane or terminal window it's in — open ten panes against the same repo,
they all share the same sound; switch to a different repo, you hear a
different one.

> Status: v0.3 — works on macOS, single-author, no Linux/Windows support
> yet. Friends-and-family release. Bug reports and PRs welcome.

---

## Install

```
/plugin marketplace add <git-url-of-this-repo>
/plugin install notify@claude-notify
```

Restart Claude Code after install (hooks are loaded once at startup).

## Usage

In any Claude Code session, from inside a project directory:

```
/notify list           # see available sounds
/notify frog           # this project plays frog from now on
/notify pack list      # see available sound packs
/notify pack StarCraft # this project plays random sounds from the StarCraft pack
/notify test           # replay the currently set sound
/notify off            # clear this project (revert to default)
/notify pause          # silence this project (sound assignment preserved)
/notify pause all      # silence every project until /notify resume all
/notify resume         # un-pause this project
/notify status         # show pause state and active sound
/notify add ~/Downloads/cow.wav         # copy a custom sound into your library
/notify add ~/Downloads/cow.wav as moo  # …and rename it on the way in
```

After `/notify frog`, you'll hear the frog sound when:
- Claude finishes a turn (`Stop` event)
- Claude needs your input — permission prompts, idle waits, MCP elicitations (`Notification` event)

Run Claude in different repos, give each a different sound. You'll
always know which project is calling for you.

## Sound packs

A *sound pack* is a folder of audio files. Assign a pack to a project and
each notification plays a random sound from the folder — handy when one
sound on repeat starts wearing thin.

```
/notify pack list                       # available packs
/notify pack StarCraft                  # this project plays random StarCraft sounds
/notify pack contents                   # list sounds in the current pack
/notify pack exclude zergling-rush      # mute one sound (the file stays on disk)
/notify pack exclude marine-yes-sir nuclear-launch   # multiple at once
/notify pack include zergling-rush      # bring it back
/notify pack reset                      # clear all exclusions for the current pack
/notify off                             # clear pack and any exclusions
```

Packs live in two locations, searched user-first:

```
~/.claude/data/notify/packs/<Name>/        # your own packs
${CLAUDE_PLUGIN_ROOT}/sounds/packs/<Name>/ # bundled with the plugin
```

Drop any `.aiff`, `.mp3`, `.wav`, `.m4a`, or `.caf` files into a folder under
either location — the folder name *is* the pack name.

Exclusions are tracked **per project per pack**. If you exclude
`zergling-rush` while on the `StarCraft` pack, switch to `Halo`, then come
back to `StarCraft`, your exclusion is still in effect. They're cleared
only by `/notify pack reset` or `/notify off`.

## Pause

Need silence for a stretch without losing your sound assignment?

```
/notify pause       # this project goes silent until /notify resume
/notify pause all   # every project goes silent until /notify resume all
/notify resume      # un-pause this project
/notify resume all  # un-pause globally
/notify status      # check whether you're paused and which sound is active
```

Pause is a marker file (`<key>.paused` per project, `paused` for global) —
it short-circuits the hook before sound resolution, so playback skips
entirely. Project pause and global pause are independent: resuming one
doesn't clear the other.

`/notify status` reports paused-or-active, the project key, the sound
that *would* play if it weren't silenced, and the full resolution chain.

Unlike `/notify off` (which deletes the sound assignment), pause
preserves everything — `/notify resume` brings back the same sound.

## How it works

Two hooks register on install:

| Hook event | Fires on | Action |
|---|---|---|
| `Stop` | Claude finishes its response | Play the project's configured sound |
| `Notification` | Claude needs user attention | Same script, same sound |

The sound to play is keyed by **project**, derived from the working
directory:

1. If `cwd` is inside a git repo, slug = basename of `git rev-parse --show-toplevel`.
2. Otherwise, slug = basename of `cwd`.
3. Slug is lowercased; non-alphanumeric runs collapse to `-`.

State lives outside the plugin so it survives upgrades and uninstalls
cleanly:

```
~/.claude/data/notify/
├── library/                          # your custom-added sounds
├── packs/                            # your custom packs (folders)
└── state/
    ├── project-claude-notify.txt     # single-sound assignment: "frog"
    ├── project-claude-notify.json    # pack assignment + per-pack excludes
    ├── project-numa-app.txt          # contents: "cow"
    └── default.txt                   # used when no project resolves
```

The `.json` file looks like:

```json
{
  "pack": "StarCraft",
  "excludeByPack": {
    "StarCraft": ["zergling-rush"]
  }
}
```

When both `.json` (with a non-null `pack`) and `.txt` exist, the pack wins.
Setting a single sound clears `pack` but preserves `excludeByPack` for
future use; `/notify off` removes both files.

The plugin's bundled sounds live in `${CLAUDE_PLUGIN_ROOT}/sounds/library/`
and are read-only. The script searches your user library first, then the
bundled library — so a custom `frog.wav` in user lib overrides the
bundled `frog.aiff`.

### Resolution chain

When a hook fires, the script first checks for pause markers (`paused` for
global, `<project-key>.paused` for the current project) — if either exists,
the hook exits silently. Otherwise it walks each candidate key (project,
then legacy pane, then default) and for each key checks state files in this
order — first match wins:

1. **`<key>.<event>`** (`.stop` or `.notify`) — per-event single-sound
   override (advanced; see below).
2. **`<key>.json`** with a non-null `pack` — pack mode: pick a random
   sound from the pack (minus any excludes).
3. **`<key>.txt`** — single-sound assignment (what `/notify <name>` writes).

Candidate keys, in order:

1. **`project-<slug>`** — derived from cwd.
2. **`pane-<id>`** — *legacy*, kept readable so v0.1 installs don't go
   silent. Never written by v0.2+.
3. **`default`** — last-resort fallback.

Run `notify-sound.sh key` from inside a project to see the chain and
which key wins, or `notify-sound.sh status` for the full picture
including pause state.

## Per-event sounds (advanced)

Want different sounds for "Claude finished" vs "Claude needs input"?
Bypass `/notify` and write directly:

```bash
echo morse     > ~/.claude/data/notify/state/project-claude-notify.stop
echo submarine > ~/.claude/data/notify/state/project-claude-notify.notify
```

These take precedence over the generic `project-claude-notify.txt`.

## Caveats

**1. macOS only (today).** Uses `afplay`. Linux support would need
swapping for `paplay`/`aplay`. PRs welcome.

**2. New sessions only.** `settings.json` and plugin hooks are read once
at Claude Code startup. The session you installed from won't fire hooks
until you restart it.

**3. Same-named projects collide.** Two unrelated repos both named
`foo` (e.g. `~/work/foo` and `~/personal/foo`) share the same slug
`project-foo` and therefore the same sound. Workaround: rename one of
the directories. Long-term: append a short path-hash if this bites
people in practice.

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

# Show the resolution chain and which key wins for the current cwd
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" key

# Check what sound is configured (and play it)
bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" test
```

If sounds don't play after install:
1. Restart Claude Code (caveat 2).
2. Run `/plugin list` and confirm `notify@claude-notify` is enabled.
3. Run the script manually with a fake event payload:
   ```
   echo '{"cwd":"'"$PWD"'"}' | bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/notify-sound.sh" stop
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
- [ ] Volume control: `/notify volume 0.3` per project
- [ ] Optional spoken project name via `say` on Stop
- [ ] Subtype filtering for `Notification` (silence `auth_success`)
- [ ] Per-event sounds via skill (no manual file editing)
- [ ] Per-event packs (different pack for `Stop` vs `Notification`)
- [ ] Rate limit: max one sound per N seconds per project
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
