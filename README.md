# claude-notify

Per-project sound notifications for Claude Code. Plays a configurable
sound when Claude finishes a turn or needs your attention. Each project
(repo / working directory) plays its own sound, no matter which tmux
pane or terminal window it's in — open ten panes against the same repo,
they all share the same sound; switch to a different repo, you hear a
different one.

> Status: v0.3 — macOS and Linux. Friends-and-family release. Bug
> reports and PRs welcome.

---

## Install

```
/plugin marketplace add <git-url-of-this-repo>
/plugin install notify@claude-notify
```

Restart Claude Code after install (hooks are loaded once at startup).

## Usage

From inside any project directory:

```
/notify <name>            # set this project's sound (e.g. /notify frog)
/notify list              # list available sounds
/notify test              # replay the current sound
/notify off               # clear assignment (revert to default)
/notify status            # show current sound, pause state, resolution
/notify pause [all]       # silence this project (or every project)
/notify resume [all]      # un-pause
/notify pack <name>       # play random sounds from a pack
/notify add <path> [as <name>]   # copy a custom sound into your library
```

After `/notify frog`, the frog sound plays when Claude finishes a turn
(`Stop`) or needs your attention (`Notification`). Different repos →
different sounds; you always know which project is calling.

## Sound packs

A *pack* is a folder of audio files; each notification picks one at
random.

```
/notify pack list                    # available packs
/notify pack <name>                  # assign a pack to this project
/notify pack contents                # list sounds in the current pack
/notify pack exclude <name>...       # mute one or more sounds
/notify pack include <name>...       # bring them back
/notify pack reset                   # clear all exclusions
```

Packs live in two locations, user-first:

```
~/.claude/data/notify/packs/<Name>/         # your own packs
${CLAUDE_PLUGIN_ROOT}/sounds/packs/<Name>/  # bundled
```

Drop `.aiff`, `.mp3`, `.wav`, `.m4a`, or `.caf` files into a folder under
either location — the folder name *is* the pack name. Exclusions are
tracked per project per pack and persist across pack switches; clear
them with `/notify pack reset` or `/notify off`.

## Pause

Silence a project without losing its sound assignment.

```
/notify pause       # this project (until /notify resume)
/notify pause all   # every project (until /notify resume all)
```

Project pause and global pause are independent. Unlike `/notify off`,
pause preserves the assignment — `/notify resume` brings back the same
sound.

## How it works

Two hooks register on install:

| Hook event | Fires on | Action |
|---|---|---|
| `Stop` | Claude finishes its response | Play the project's sound |
| `Notification` | Claude needs user attention | Same script, same sound |

The sound is keyed by **project**, derived from `cwd`:
1. Inside a git repo: slug = basename of `git rev-parse --show-toplevel`.
2. Otherwise: slug = basename of `cwd`.
3. Slug is lowercased; non-alphanumeric runs collapse to `-`.

State lives outside the plugin so it survives upgrades cleanly:

```
~/.claude/data/notify/
├── library/                         # your custom sounds
├── packs/                           # your custom packs
├── cache/                           # auto-converted WAVs (Linux fallback)
└── state/
    ├── project-<slug>.txt           # single-sound assignment
    ├── project-<slug>.json          # pack assignment + per-pack excludes
    └── default.txt                  # fallback when no project resolves
```

When both `.json` (with a non-null `pack`) and `.txt` exist, the pack
wins. Setting a single sound clears `pack` but preserves
`excludeByPack`; `/notify off` removes both files.

### Resolution chain

On each hook the script checks for pause markers (`paused` global,
`<project-key>.paused` per-project) and exits silently if either exists.
Otherwise it walks candidate keys (`project-<slug>` → legacy `pane-<id>`
→ `default`) and for each key checks state in order — first match wins:

1. `<key>.<event>` (`.stop` or `.notify`) — per-event override.
2. `<key>.json` with a non-null `pack` — random sound from the pack.
3. `<key>.txt` — single-sound assignment.

Run `/notify status` to see the chain and what would play.

## Per-event sounds (advanced)

Different sounds for "Claude finished" vs "needs input"? Write directly:

```bash
echo morse     > ~/.claude/data/notify/state/project-<slug>.stop
echo submarine > ~/.claude/data/notify/state/project-<slug>.notify
```

These take precedence over `project-<slug>.txt`.

## Caveats

1. **Audio player required.** Picks the first available of `afplay`,
   `paplay`, `pw-play`, `ffplay`, `play` (sox), `mpv`, `aplay`. With no
   player installed, hooks log a warning to stderr and exit silently.
   Players that don't handle every shipped format (`aplay` → WAV only;
   `paplay`/`pw-play` → no `.mp3`/`.m4a`) trigger lazy conversion to WAV
   via `ffmpeg` or `sox`; converted files are cached under
   `~/.claude/data/notify/cache/`. If neither converter is installed,
   the warning fires once per hook fire and playback falls through to
   the original file (which may not play).
2. **New sessions only.** Hooks are read once at Claude Code startup —
   the session you installed from won't fire hooks until you restart.
3. **Same-named projects collide.** Two unrelated repos both named
   `foo` share the slug `project-foo`. Rename one of the directories.
4. **Overlapping events.** If `Stop` and `Notification` fire back-to-back
   you'll hear two sounds. Keep custom sounds short (<2s).
5. **macOS sandbox.** Adding sounds from `~/Downloads` may fail with
   "Operation not permitted" — move to `/tmp` first, or grant the
   terminal "Files & Folders → Downloads" in System Settings.

## Roadmap

- [ ] Windows support
- [ ] Volume control per project
- [ ] Subtype filtering for `Notification` (silence `auth_success`)
- [ ] Per-event sounds via skill (no manual file editing)
- [ ] Rate limit: max one sound per N seconds per project

## Contributing

Issues and PRs welcome. Test locally:

```
/plugin marketplace remove claude-notify    # if previously installed
/plugin marketplace add /path/to/claude-notify
/plugin install notify@claude-notify
```
