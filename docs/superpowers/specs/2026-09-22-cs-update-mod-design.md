# cs-update mod: release notes pane with an update button — design

Date: 2026-09-22
Status: pending spec review
Decision trail: Alex, 2026-09-22: "display a beautiful mod pane with the
release notes when a new cs version is available and maybe a button to
update cs"; cadence "once per session"; "add a setting in /config to
disable this".

## Context and goal

When a newer cs exists, the launch banner already prints one yellow line
and a compact card of one-line summaries per pending version
(`lib/75-launch.sh:449`), built from `~/.cache/cs/update-notes-<version>`
by `check_update_notify` (`lib/20-update.sh:409`). The card scrolls off
with the banner, and acting on it means leaving Claude Code to run
`cs -update`. The goal: inside the session, once per launch, a pane that
shows the full notes for every pending version and offers the update as
one key, with a `/config` toggle to turn the pane off.

## Decisions

1. **A second mod, `cs-update`**, a Claude Code function-hooks plugin
   deployed exactly as `cs-rotate` is (`CS_MOD_FILES` in
   `lib/01-manifests.sh`, `~/.claude/skills/cs-update/`, doctor's
   `_doctor_check_mod`, the heartbeat). Nothing is added to `cs-rotate`:
   the two have no shared state, and a person may want one without the
   other.
2. **No network and no version logic in the mod.** Launch already knows
   whether an update is pending and which version. It exports
   `CS_UPDATE_AVAILABLE=<version>` into the claude process when
   `UPDATE_AVAILABLE` is set, and nothing otherwise. The mod reads that
   with `$.env.get` and stays silent when it is absent, so a mod loaded
   in a session launched outside cs, or with the check disabled, never
   opens. `version_greater` stays in bash.
3. **Full notes, cached beside the summaries.** `check_update_notify`
   writes a second file, `~/.cache/cs/update-notes-full-<version>`: the
   raw `CHANGELOG.md` span from `changelog_span` (every `## X.Y.Z`
   section above the installed version, newest first, markdown intact).
   It is built from the same single fetch that builds the summaries,
   pruned by the same stale loop, and an empty file records a failed
   fetch as the summaries file does. The mod reads it with `$.fs.read`
   and renders it itself; the launch card keeps the summaries file and is
   unchanged.
4. **Once per session** means once per load of the mod: module state,
   as the rotate mod's handoff pane does. A `/clear` in the same process
   does not reopen it. A dismissed pane stays dismissed; `/cs-update`
   (registered with `$.command.register`) reopens it on demand, and is
   the only way to see it again without relaunching.
5. **Lead only.** `session.start` carries no agent id (a teammate is
   its own process with its own start), so the mod opens only when
   `$.session.id()` equals the `claude_session_id` cs recorded in
   `.cs/local/state` before the launch, as the rotate mod judges
   ownership. Teammate panes in the same directory share the settings
   and the cache, and each would otherwise pop its own copy.
6. **The button runs the real update.** `1` runs
   `$.process.run([csBin, "-update"], { timeoutMs: 600000 })`, where
   `csBin` is `CS_UPDATE_BIN`, the absolute path of the running cs
   (`$0` resolved), exported by launch beside `CS_UPDATE_AVAILABLE`.
   No `cs` on PATH is assumed: `$.process.run` takes no shell, and the
   claude process's PATH is not the launching shell's. The pane
   shows `updating…` while it runs, then the exit: on 0, `Update
   finished. Takes effect on your next launch.` (version-neutral, since
   `cs -update` resolves the latest release when it runs, which may be
   newer than the one the launch saw); on non-zero, the last lines of
   stderr. Either way the pane stays open until dismissed, so
   the outcome is read, not flashed. `cs -update` never prompts, so no
   stdin is needed.
7. **What an in-place update does to the running session.** The update
   overwrites `bin/cs`, the hooks, the skills and both mods under
   `~/.claude/skills`. Hooks and `cs -*` calls read the new files on
   their next run; the loaded mods and this claude keep the old code
   until the next launch. The pane says so. Measured before merge (see
   Testing): the mod overwriting its own module while its pane is open
   must neither crash the engine nor reload the module mid-pane.
8. **`/config` toggle.** `plugin.json` declares
   `userConfig.showReleaseNotes` (`boolean`, default `true`, title
   "Release notes pane", description naming `/cs-update`). Claude Code
   draws it as `cs-update.showReleaseNotes` in `/config` and hands the
   value to `register(on, options)`; `false` skips the `session.start`
   open and leaves `/cs-update` working. No cs verb, no env var, no
   marker file: the engine owns the row, and `cs -doctor` need not
   know it.
9. **Look.** One pane, opened with `focus: true` (a request the surface
   grants over an idle, empty composer; without it the keys stay with
   the prompt) and `closeOnEscape`. A lone pane draws no tab title, so
   the body opens with `cs <version> is available` in bold. Then, for
   each pending version, a heading line (the version, bold, in the
   session colour cs recorded in `.cs/local/state`, as the status bar's
   name is), then its prose and bullets as the changelog authored them
   with `_md_strip_inline`'s job done in TypeScript (links, bold and
   code marks stripped); a continuation line hangs indented under its
   bullet. Sections are separated by one blank line. Footer:
   `1: update now   Esc: later`, rendered as the rotate band renders its
   keys (Button inside a Box, never inside a Text). No fill colour: the
   pane is the engine's surface, and text on it reads on light and dark
   alike. Whether the Pane scrolls past its height is measured live; if
   it does not, a follow-up caps the body to the newest versions that
   fit, as the launch card does.

## Components

- `mods/cs-update/.claude-plugin/plugin.json`: name, version,
  description, `userConfig.showReleaseNotes`.
- `mods/cs-update/hooks/hooks.json`: `{"modules":["./register.tsx"]}`.
- `mods/cs-update/hooks/register.tsx`: `register(on, options)`;
  `session.start` (lead, once, option on, `CS_UPDATE_AVAILABLE` set,
  notes file non-empty) opens the pane; `ui.render` for
  `{ component: 'Pane' }` draws it; `command.run` for `/cs-update`
  reopens it; the `1` press runs the update and redraws; Esc closes.
  Exported for tests: the notes parser (`parseSpan(text)` to
  `{version, bullets[]}[]`), the pane id, the option name.
- `mods/cs-update/test/register.test.ts`: bun tests against the same
  fake engine shape `cs-rotate` uses.
- `lib/20-update.sh`: `check_update_notify` also writes
  `update-notes-full-<version>` from `changelog_span`.
- `lib/75-launch.sh`: exports `CS_UPDATE_AVAILABLE` and
  `CS_UPDATE_BIN` beside the other `CS_*` exports when
  `UPDATE_AVAILABLE` is set.
- `lib/01-manifests.sh`: three `cs-update/...` entries in
  `CS_MOD_FILES`; `lib/60-doctor.sh`: `_doctor_check_mod cs-update`.
- Docs: README mods section, `docs/configuration.md` (the `/config`
  row, `/cs-update`), CHANGELOG.

## Data flow

```
cs <name>  ──check_update_notify──▶ ~/.cache/cs/update-notes-<v>       (summaries; launch card)
                                    ~/.cache/cs/update-notes-full-<v>  (span; the pane)
           ──export CS_UPDATE_AVAILABLE=<v> CS_UPDATE_BIN=<path>──▶ claude
claude loads cs-update ──session.start (lead, once, option on)──▶ $.fs.read(full-<v>) ──▶ $.ui.open
pane: 1 ──▶ $.process.run([CS_UPDATE_BIN, "-update"]) ──▶ exit line in the pane
      Esc ──▶ $.ui.close
/cs-update ──▶ reopen from the same file
```

## Error handling

- `CS_UPDATE_AVAILABLE` unset, option off, teammate, or already shown:
  nothing happens, no toast.
- Notes file missing or empty (fetch failed at launch): the pane still
  opens, body `Release notes could not be fetched at launch; the update
  is <version>.`, button intact. The update itself does not need the
  notes.
- `$.process.run` rejects (cannot start, timeout at ten minutes): the
  pane shows the rejection text; no retry.
- Non-zero exit: the pane shows the last five stderr lines; cs's own
  messages (checksum, signature) are what the person reads.
- A second press of `1` while a run is in flight is ignored.

## Testing

- **bun, `mods/cs-update/test`**: `parseSpan` on a fixture span with
  two versions (headings, bullets, a link and bold mark, a
  continuation line); `session.start` opens once and not on a second
  start; not for `agentId` set; not with the option `false`; not with
  the env unset; `/cs-update` reopens after a dismiss; the `1` press
  calls `process.run` with `[CS_UPDATE_BIN, "-update"]` and a ten-minute
  timeout, exactly once across a double press; exit 0 and exit 1
  bodies; an empty notes file gives the fallback body.
- **bash, `tests/test_auto_update.sh`**: `check_update_notify` writes
  the full file from a stubbed fetch; both files pruned together; an
  empty full file on fetch failure. `tests/test_launch.sh` (or the
  suite that pins the exports): `CS_UPDATE_AVAILABLE` exported only
  when an update is pending. Manifest and doctor tests follow the
  `cs-rotate` entries.
- **Live, before merge** (the part no unit test reaches): a throwaway
  cs session with a seeded cache and `CS_UPDATE_AVAILABLE` faked, the
  pane opened and screenshotted on the light terminal; then a real
  update from an older installed cs, watching whether the engine
  survives the mod's own file being replaced with the pane open.
  Evidence under `scratchpad/`, findings in the narrative.

## Out of scope

- Restarting Claude Code after the update. The pane says a relaunch is
  needed; automating it is a separate decision.
- A mid-session check for a version that appears after launch. The
  hourly cache refresh keeps feeding the launch banner; this pane reads
  the launch's verdict only.
- Moving the launch card into the mod. A cs launch without function
  hooks (`CS_NO_FUNCTION_HOOKS=1`, or a Claude Code without the
  early-access flag) still needs the card.
