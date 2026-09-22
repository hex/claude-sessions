# cs-update mod Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Once per cs launch, when a newer cs exists, a Claude Code pane shows the full release notes for every pending version, with `1` running `cs -update` in place and a `/config` toggle to turn the pane off.

**Architecture:** Bash does the deciding (is an update pending, which version, where cs lives) and caches the changelog span at launch, exactly where it already caches the summaries; the new `cs-update` mod (a function-hooks plugin deployed like `cs-rotate`) reads two env vars and one cache file, draws the pane, and runs the update through `$.process.run`. The `/config` row is the plugin's `userConfig` field, owned by the engine.

**Tech Stack:** bash 3.2 (lib/, tests/), TypeScript + JSX under bun (mods/), Claude Code function-hooks contract at `~/.claude/plugins/marketplaces/claude-code-plugins/mods/types/claude-code.d.ts`.

**Spec:** `docs/superpowers/specs/2026-09-22-cs-update-mod-design.md`

## Global Constraints

- bash 3.2 + BSD userland in `lib/` and `tests/`: no `local -A`, no `printf %(…)T`, no GNU-only sed/awk/stat/date flags.
- Every test assertion ends with `|| return 1` (`run_test` disables errexit).
- `assert_file_contains` is a BRE regex: escape `[`, `.`, `$` when pinning literals.
- `tests/test_*.sh` run locally here; the full gate normally runs on ghost via `claude-tmux:remote-tests` (its host store is missing in claude-tmux 2026.9.1, so say "local only" in the report if that is still true).
- `install.sh` is BUILT from `install.sh.in` + `lib/01-manifests.sh`: after editing either, run `./build.sh` and commit `install.sh` and `bin/cs` with the source.
- No real names, emails or handles in fixtures.
- Mod source is `mods/cs-update/`; the installer deploys it to `~/.claude/skills/cs-update/` file by file from `CS_MOD_FILES`; the bun tests stay in the checkout.
- A Button is a block: nested inside a Text the engine drops the whole tree silently. Buttons live inside a Box.
- `$.env.get("NAME")` takes a string literal; `claude plugin validate` inventories the names.
- Commit messages end with `Claude-Session: https://claude.ai/code/session_01Vq9cY3NDp19s9ES6ALgnBD`.

---

## File structure

| File | Responsibility |
|---|---|
| `lib/20-update.sh` | `check_update_notify` also writes `update-notes-full-<v>` (the `changelog_span` text) beside the summaries |
| `lib/75-launch.sh` | exports `CS_UPDATE_AVAILABLE` and `CS_UPDATE_BIN` when an update is pending |
| `lib/01-manifests.sh` | three `cs-update/...` entries in `CS_MOD_FILES` |
| `lib/60-doctor.sh` | `_doctor_check_mod cs-update` |
| `mods/cs-update/.claude-plugin/plugin.json` | manifest with `userConfig.showReleaseNotes` |
| `mods/cs-update/hooks/hooks.json` | names the module |
| `mods/cs-update/hooks/register.tsx` | the mod: gate, pane, update key, `/cs-update` |
| `mods/cs-update/test/register.test.ts` | bun tests against a fake `$` |
| `tests/test_auto_update.sh` | full-cache and launch-export tests |
| `tests/test_mod_update.sh` | manifest, bun, validate |
| `README.md`, `docs/configuration.md`, `CHANGELOG.md` | docs |

---

### Task 1: the full-notes cache

**Files:**
- Modify: `lib/20-update.sh:409-431` (`check_update_notify`'s cache block)
- Test: `tests/test_auto_update.sh` (`test_notify_writes_notes_cache`, and one new test)

**Interfaces:**
- Produces: `~/.cache/cs/update-notes-full-<version>`: the output of `changelog_span "$notes" "$VERSION"` (every `## X.Y.Z` section above the installed version, newest first, markdown intact). Empty file when the fetch failed. Pruned by the same stale loop as `update-notes-<version>`.

- [ ] **Step 1: Extend the existing notify test to expect the full file**

In `tests/test_auto_update.sh`, inside `test_notify_writes_notes_cache`, after the `stale notes caches pruned` assertion and before `export HOME="$ORIGINAL_HOME"`, add:

```bash
    local full="$HOME/.cache/cs/update-notes-full-2026.99.3"
    assert_file_exists "$full" "notify writes the full-notes cache" || { export HOME="$ORIGINAL_HOME"; return 1; }
    assert_file_contains "$full" "^## 2026\.99\.3$" "the span starts at the newest version" || { export HOME="$ORIGINAL_HOME"; return 1; }
    assert_file_contains "$full" "Statusline: readable" "and keeps the bullets" || { export HOME="$ORIGINAL_HOME"; return 1; }
    # The fixture's every version is above the installed one (2026.99.x), so
    # the span's stop-at-installed rule is not testable here; it is pinned by
    # test_span_extracts_versions_above_installed on the function itself.
```

Also make the stale fixture two files, so the prune is proven for both names. Replace:

```bash
    printf 'stale\n' > "$HOME/.cache/cs/update-notes-2026.90.0"
```

with:

```bash
    printf 'stale\n' > "$HOME/.cache/cs/update-notes-2026.90.0"
    printf 'stale\n' > "$HOME/.cache/cs/update-notes-full-2026.90.0"
```

and after the existing `stale notes caches pruned` line add:

```bash
    assert_not_exists "$HOME/.cache/cs/update-notes-full-2026.90.0" "stale full caches pruned" || { export HOME="$ORIGINAL_HOME"; return 1; }
```

- [ ] **Step 2: Add a test for the failed-fetch tombstone**

After `test_notify_writes_notes_cache`, add:

```bash
# A failed fetch writes an empty full file, as it writes an empty summaries
# file: the next launch must not retry the network, and the mod must be able
# to tell "no notes" from "no file".
test_notify_writes_empty_full_cache_when_fetch_fails() {
    local stub="$TEST_TMPDIR/stub-bin-nofetch"
    mkdir -p "$stub"
    _make_curl_stub "$stub" ""
    export HOME="$TEST_TMPDIR/home-nofetch"
    mkdir -p "$HOME/.cache/cs"
    unset CS_NO_UPDATE_CHECK
    PATH="$stub:$PATH" "$CS_BIN" "notes-nofetch-session" < /dev/null > /dev/null 2>&1 || {
        export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"
        return 1
    }
    export CS_NO_UPDATE_CHECK=1
    local full="$HOME/.cache/cs/update-notes-full-2026.99.3"
    [ -f "$full" ] || { echo "  FAIL: no full-notes tombstone written"; export HOME="$ORIGINAL_HOME"; return 1; }
    [ ! -s "$full" ] || { echo "  FAIL: the tombstone is not empty"; export HOME="$ORIGINAL_HOME"; return 1; }
    export HOME="$ORIGINAL_HOME"
}
```

Register it in the runner block: after `run_test test_notify_writes_notes_cache` add `run_test test_notify_writes_empty_full_cache_when_fetch_fails`.

- [ ] **Step 3: Seed the full file in the two banner tests**

`check_update_notify` will now fetch whenever EITHER cache file is missing, and `test_launch_banner_shows_notes_card` and `test_launch_banner_quiet_on_empty_notes_cache` seed only the summaries file, so they would reach the network. In each, directly after the line that writes `update-notes-2026.99.3`, add:

```bash
    : > "$HOME/.cache/cs/update-notes-full-2026.99.3"
```

- [ ] **Step 4: Run the suite to see both fail**

Run: `bash tests/test_auto_update.sh 2>&1 | tail -15`
Expected: `test_notify_writes_notes_cache` FAIL at "notify writes the full-notes cache"; the new test FAIL at "no full-notes tombstone written".

- [ ] **Step 5: Write the cache block**

In `lib/20-update.sh`, replace the block that begins `if [ -n "$UPDATE_AVAILABLE" ]; then` inside `check_update_notify` (the one that builds `notes_cache`) with:

```bash
    # Build the launch card's notes cache once per pending remote version,
    # and beside it the full changelog span the cs-update mod draws; an
    # empty file records a failed fetch so launches don't retry the network
    # until the version changes (or an explicit --check/-update).
    if [ -n "$UPDATE_AVAILABLE" ]; then
        local notes_cache="$cache_dir/update-notes-$UPDATE_AVAILABLE"
        local full_cache="$cache_dir/update-notes-full-$UPDATE_AVAILABLE"
        if [ ! -f "$notes_cache" ] || [ ! -f "$full_cache" ]; then
            local notes
            if notes=$(fetch_remote_changelog); then
                changelog_summaries "$notes" "$VERSION" 5 > "$notes_cache.tmp" \
                    && mv "$notes_cache.tmp" "$notes_cache"
                changelog_span "$notes" "$VERSION" > "$full_cache.tmp" \
                    && mv "$full_cache.tmp" "$full_cache"
                rm -f "$notes"
            else
                : > "$notes_cache"
                : > "$full_cache"
            fi
            local stale
            for stale in "$cache_dir"/update-notes-*; do
                [ -e "$stale" ] || continue
                if [ "$stale" != "$notes_cache" ] && [ "$stale" != "$full_cache" ]; then
                    rm -f "$stale"
                fi
            done
        fi
    fi
```

The `|| [ ! -f "$full_cache" ]` arm is what makes an upgrade from a cs that only wrote the summaries file fetch once more; without it the mod would never see a full file until the next release.

- [ ] **Step 6: Rebuild and run the suite**

Run: `./build.sh >/dev/null && bash tests/test_auto_update.sh 2>&1 | tail -4`
Expected: `Results: N/N passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add lib/20-update.sh bin/cs tests/test_auto_update.sh
git commit -m "update: the notify check caches the full changelog span beside the summaries

Claude-Session: https://claude.ai/code/session_01Vq9cY3NDp19s9ES6ALgnBD"
```

---

### Task 2: launch exports the verdict to the mod

**Files:**
- Modify: `lib/75-launch.sh` (the export block around line 303, next to `export CS_LEAD_PID=$$`)
- Test: `tests/test_auto_update.sh`

**Interfaces:**
- Produces, in the launched claude's environment, only when an update is pending: `CS_UPDATE_AVAILABLE=<version>` and `CS_UPDATE_BIN=<absolute path of the running cs>`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_auto_update.sh` after `test_launch_banner_quiet_on_empty_notes_cache`:

```bash
# The cs-update mod reads the launch's verdict from the environment: which
# version is pending and where cs lives, since `$.process.run` takes no shell
# and the claude process's PATH is not the launching shell's. Neither name is
# exported when nothing is pending, so the mod stays silent by absence.
test_launch_exports_update_verdict_to_the_mod() {
    local stub="$TEST_TMPDIR/claude-env-stub"
    cat > "$stub" << 'SCRIPT'
#!/bin/bash
echo "UPDATE_AVAILABLE=${CS_UPDATE_AVAILABLE-unset}"
echo "UPDATE_BIN=${CS_UPDATE_BIN-unset}"
exit 0
SCRIPT
    chmod +x "$stub"
    export HOME="$TEST_TMPDIR/home-export"
    mkdir -p "$HOME/.cache/cs"
    printf '%s 2026.99.3\n' "$(date +%s)" > "$HOME/.cache/cs/update-check"
    : > "$HOME/.cache/cs/update-notes-2026.99.3"
    : > "$HOME/.cache/cs/update-notes-full-2026.99.3"
    unset CS_NO_UPDATE_CHECK
    local out
    out=$(CLAUDE_CODE_BIN="$stub" "$CS_BIN" "export-verdict-session" < /dev/null 2>&1) || {
        export CS_NO_UPDATE_CHECK=1 HOME="$ORIGINAL_HOME"; return 1
    }
    export CS_NO_UPDATE_CHECK=1
    assert_output_contains "$out" "UPDATE_AVAILABLE=2026.99.3" "the pending version is exported" || { export HOME="$ORIGINAL_HOME"; return 1; }
    local bin_line
    bin_line=$(printf '%s\n' "$out" | sed -n 's/^UPDATE_BIN=//p' | head -1)
    [ "$bin_line" != "unset" ] && [ -n "$bin_line" ] || { echo "  FAIL: CS_UPDATE_BIN not exported"; export HOME="$ORIGINAL_HOME"; return 1; }
    [ -x "$bin_line" ] || { echo "  FAIL: CS_UPDATE_BIN is not an executable path: $bin_line"; export HOME="$ORIGINAL_HOME"; return 1; }
    case "$bin_line" in /*) ;; *) echo "  FAIL: CS_UPDATE_BIN is not absolute: $bin_line"; export HOME="$ORIGINAL_HOME"; return 1 ;; esac
    # And nothing pending exports nothing, even when the launching shell
    # carries a parent launch's verdict (a nested cs): both names are cleared
    # before the conditional export. CS_NO_UPDATE_CHECK=1 is the no-network
    # way to have nothing pending: check_update_notify returns before it
    # reads the cache or asks GitHub, so UPDATE_AVAILABLE stays empty.
    export CS_NO_UPDATE_CHECK=1
    out=$(CS_UPDATE_AVAILABLE=2026.1.1 CS_UPDATE_BIN=/stale/cs CLAUDE_CODE_BIN="$stub" "$CS_BIN" "export-current-session" < /dev/null 2>&1) || {
        export HOME="$ORIGINAL_HOME"; return 1
    }
    export HOME="$ORIGINAL_HOME"
    assert_output_contains "$out" "UPDATE_AVAILABLE=unset" "an inherited version is cleared when nothing is pending" || return 1
    assert_output_contains "$out" "UPDATE_BIN=unset" "and so is an inherited path" || return 1
}
```

Register: `run_test test_launch_exports_update_verdict_to_the_mod` after the two launch-banner tests.

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/test_auto_update.sh 2>&1 | grep -A3 export_update_verdict`
Expected: FAIL at "the pending version is exported".

- [ ] **Step 3: Add the exports**

In `lib/75-launch.sh`, directly after `export CS_LEAD_PID=$$` and its comment, add:

```bash
    # The cs-update mod draws the pending release's notes and runs the update
    # from inside the session. It gets the launch's verdict, never its own:
    # the version check_update_notify found newer than this cs, and where this
    # cs is, since `$.process.run` takes no shell and the claude process's
    # PATH is not this shell's. Absent when nothing is pending, so the mod is
    # silent by absence rather than by a value it has to read; cleared first,
    # since a nested launch inherits its parent's verdict.
    unset CS_UPDATE_AVAILABLE CS_UPDATE_BIN
    if [ -n "$UPDATE_AVAILABLE" ]; then
        export CS_UPDATE_AVAILABLE="$UPDATE_AVAILABLE"
        local self_bin
        self_bin="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
        export CS_UPDATE_BIN="$self_bin"
    fi
```

`$0` is the assembled `bin/cs` (the dispatcher execs itself by `$0` at `lib/99-main.sh:32`, so it is always the script path); `pwd -P` makes it absolute without `realpath`, which BSD lacks.

- [ ] **Step 4: Rebuild and run**

Run: `./build.sh >/dev/null && bash tests/test_auto_update.sh 2>&1 | tail -4`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/75-launch.sh bin/cs tests/test_auto_update.sh
git commit -m "launch: export the pending version and the cs path for the cs-update mod

Claude-Session: https://claude.ai/code/session_01Vq9cY3NDp19s9ES6ALgnBD"
```

---

### Task 3: the mod: manifest, gate, pane, deployment

**Files:**
- Create: `mods/cs-update/.claude-plugin/plugin.json`
- Create: `mods/cs-update/hooks/hooks.json`
- Create: `mods/cs-update/hooks/register.tsx`
- Create: `mods/cs-update/test/register.test.ts`
- Create: `tests/test_mod_update.sh`
- Modify: `lib/01-manifests.sh:96-100` (`CS_MOD_FILES`)
- Modify: `lib/60-doctor.sh:765` (`_doctor_check_mod cs-rotate` gains a sibling)

**Interfaces:**
- Consumes: `CS_UPDATE_AVAILABLE`, `CS_UPDATE_BIN` (Task 2), `~/.cache/cs/update-notes-full-<v>` (Task 1), `.cs/local/state`'s `claude_session_id` line (written by cs before launch).
- Produces (exported from `register.tsx`, used by the tests and by Tasks 4 and 5): `PANE = 'cs-update'`, `OPTION = 'showReleaseNotes'`, `HEARTBEAT = '.cs/local/cs-update.heartbeat'`, `parseSpan(text: string): Section[]` with `type Section = { version: string; lines: string[] }`, `stripInline(s: string): string`, `register(on, options)`; module-internal `isLead($, cwd)`, `openPane($, cwd, pending)`, `runUpdate($)`.

- [ ] **Step 1: Write the manifest and hooks list**

`mods/cs-update/.claude-plugin/plugin.json`:

```json
{
  "name": "cs-update",
  "version": "0.1.0",
  "description": "Release notes for a pending cs update, once per launch, with 1 to install it in place; /cs-update reopens the pane.",
  "author": { "name": "cs" },
  "userConfig": {
    "showReleaseNotes": {
      "type": "boolean",
      "title": "Release notes pane",
      "description": "When a newer cs is available, open its release notes once per launch. Off, /cs-update still opens them on demand.",
      "required": false,
      "default": true
    }
  }
}
```

`mods/cs-update/hooks/hooks.json`:

```json
{"modules":["./register.tsx"]}
```

- [ ] **Step 2: Write the failing bun tests for the parser and the gate**

`mods/cs-update/test/register.test.ts`:

```ts
// ABOUTME: Unit tests for the cs-update mod against a fake engine `$`.
// ABOUTME: Covers the span parser, the once-per-load gate (env, option, lead, tombstone), the pane body, the update key and /cs-update.
import { test, expect, beforeEach } from 'bun:test'

;(globalThis as any).h = (type: any, props: any, ...children: any[]) => ({ type, props: props ?? {}, children })
;(globalThis as any).Fragment = 'Fragment'

import { register, parseSpan, stripInline, PANE, OPTION, HEARTBEAT } from '../hooks/register.tsx'

type Hook = ($: any, e: any, next: (e: any) => Promise<any>) => Promise<any>
const hooks: Record<string, Hook> = {}
const on = (event: string, a: any, b?: any) => {
  const matcher = b ? a : undefined
  const fn: Hook = b ?? a
  const narrowed = matcher?.component ?? matcher?.command
  hooks[narrowed ? `${event}:${narrowed}` : event] = fn
}

let envVars: Record<string, string | undefined>
let files: Record<string, string>
let written: Record<string, string>
let panes: { op: 'open' | 'close'; args: any }[]
let toasts: string[]
let invalidated: string[]
let runs: { argv: string[]; init: any }[]
let runResult: { exitCode: number; stdout: string; stderr: string } | Error
let commands: any[]
let sessionId: string

// The default runner: records the call and answers with `runResult`. A test
// that swaps it in (for a run held in flight) gets it back in beforeEach.
const defaultRun = async (argv: string[], init: any) => {
  runs.push({ argv, init })
  if (runResult instanceof Error) throw runResult
  return runResult
}

const $ = {
  env: { get: async (name: string) => envVars[name] },
  session: { id: async () => sessionId, cwd: async () => '/work' },
  fs: {
    read: async (path: string) => { if (path in files) return files[path]; throw new Error(`ENOENT ${path}`) },
    exists: async (path: string) => path in files || path === '/work/.cs/local',
    write: async (path: string, text: string) => { written[path] = text },
  },
  ui: {
    resolve: async () => ({ Box: 'Box', Text: 'Text', Button: 'Button' }),
    open: async (args: any) => { panes.push({ op: 'open', args }) },
    close: async (args: any) => { panes.push({ op: 'close', args }) },
    toast: (text: string) => { toasts.push(text) },
    invalidate: (event: string) => { invalidated.push(event) },
  },
  process: { run: defaultRun as (argv: string[], init: any) => Promise<any> },
  command: { register: async (spec: any) => { commands.push(spec); return { command: spec.name } } },
}

const SPAN = `## 2026.99.3

One fix: the statusline is readable on light terminals.

### Fixes

- **Statusline: readable.** The \`chiptext\` token was **wrong** in [two places](https://example.com/x).
  A continuation line.

## 2026.99.2

One change: the locked-session menu is single-keypress.

### Changed

- **Menu: keypress.** Cancel stays the default.
`

const start = () => hooks['session.start']($, { cwd: '/work' }, async () => 'started')
const opens = () => panes.filter(p => p.op === 'open')
// A `.map()` inside JSX lands as an array child, so both walkers flatten
// arrays before reading an element's children.
function texts(tree: any): string[] {
  if (typeof tree === 'string') return [tree]
  if (Array.isArray(tree)) return tree.flatMap(texts)
  if (!tree || typeof tree !== 'object') return []
  return (tree.children ?? []).flatMap(texts)
}
function buttons(tree: any): any[] {
  if (Array.isArray(tree)) return tree.flatMap(buttons)
  if (!tree || typeof tree !== 'object') return []
  if (tree.type === 'Button') return [tree]
  return (tree.children ?? []).flatMap(buttons)
}
function headings(tree: any): any[] {
  if (Array.isArray(tree)) return tree.flatMap(headings)
  if (!tree || typeof tree !== 'object') return []
  if (tree.type === 'Text' && tree.props.bold && tree.props.color) return [tree]
  return (tree.children ?? []).flatMap(headings)
}
const draw = () => hooks['ui.render:Pane']($, { requestId: PANE }, async () => 'other')

function load(options: Record<string, unknown> = {}) {
  for (const k of Object.keys(hooks)) delete hooks[k]
  register(on as any, { [OPTION]: true, ...options } as any)
}

beforeEach(() => {
  envVars = { CS_UPDATE_AVAILABLE: '2026.99.3', CS_UPDATE_BIN: '/opt/cs/bin/cs', HOME: '/home/u' }
  files = {
    '/work/.cs/local/state': 'claude_session_color: red\nclaude_session_id: uuid-lead\n',
    '/home/u/.cache/cs/update-notes-full-2026.99.3': SPAN,
  }
  written = {}; panes = []; toasts = []; invalidated = []; runs = []; commands = []
  runResult = { exitCode: 0, stdout: 'ok', stderr: '' }
  ;($ as any).process.run = defaultRun
  sessionId = 'uuid-lead'
  load()
})

test('stripInline drops links, bold and code marks and keeps the words', () => {
  expect(stripInline('The `chiptext` token was **wrong** in [two places](https://example.com/x).'))
    .toBe('The chiptext token was wrong in two places.')
})

test('parseSpan yields one section per version with prose and bullets, headings and blanks dropped', () => {
  const sections = parseSpan(SPAN)
  expect(sections.map(s => s.version)).toEqual(['2026.99.3', '2026.99.2'])
  expect(sections[0].lines).toEqual([
    'One fix: the statusline is readable on light terminals.',
    '- Statusline: readable. The chiptext token was wrong in two places.',
    '  A continuation line.',
  ])
  expect(sections[1].lines).toEqual([
    'One change: the locked-session menu is single-keypress.',
    '- Menu: keypress. Cancel stays the default.',
  ])
})

test('parseSpan of an empty file is no sections', () => {
  expect(parseSpan('')).toEqual([])
})

test('session.start opens the pane once per load and writes the heartbeat', async () => {
  expect(await start()).toBe('started')
  expect(opens()).toHaveLength(1)
  expect(opens()[0].args).toMatchObject({ id: PANE, title: 'cs 2026.99.3 is available', closeOnEscape: true, focus: true })
  expect(written['/work/' + HEARTBEAT]).toMatch(/^\d{4}-/)
  await start()
  expect(opens()).toHaveLength(1)
})

test('no pending version, no pane, no toast', async () => {
  delete envVars.CS_UPDATE_AVAILABLE
  await start()
  expect(opens()).toHaveLength(0)
  expect(toasts).toEqual([])
})

test('the option off skips the launch pane', async () => {
  load({ [OPTION]: false })
  await start()
  expect(opens()).toHaveLength(0)
})

test('a teammate (a session that is not the one cs launched) gets no pane', async () => {
  sessionId = 'uuid-teammate'
  await start()
  expect(opens()).toHaveLength(0)
})

test('a quoted id in the state file still names the lead', async () => {
  files['/work/.cs/local/state'] = 'claude_session_color: red\nclaude_session_id: "uuid-lead"\n'
  await start()
  expect(opens()).toHaveLength(1)
})

test('no state file (not a cs session) means no pane', async () => {
  delete files['/work/.cs/local/state']
  await start()
  expect(opens()).toHaveLength(0)
})

test('the pane draws the title, every version in the session colour, its lines, and the two keys', async () => {
  await start()
  const tree = await draw()
  const words = texts(tree).join('\n')
  // A lone pane draws no title of its own, so the body carries it.
  expect(words).toContain('cs 2026.99.3 is available')
  expect(headings(tree).map(t => [t.props.color, texts(t).join('')])).toEqual([['red', '2026.99.3'], ['red', '2026.99.2']])
  expect(words).toContain('One fix: the statusline is readable on light terminals.')
  expect(words).toContain('- Menu: keypress. Cancel stays the default.')
  // A continuation line hangs under its bullet: it is indented, not run on.
  const cont = texts(tree).find(t => t.includes('A continuation line.'))
  expect(cont).toBe('  A continuation line.')
  const keys = buttons(tree)
  expect(keys.map(b => b.props.hotkey)).toEqual(['1'])
  expect(keys[0].props.label).toBe('update now')
  expect(words).toContain('Esc: later')
})

test('a tombstone (empty notes file) still opens the pane with the fallback body', async () => {
  files['/home/u/.cache/cs/update-notes-full-2026.99.3'] = ''
  await start()
  expect(opens()).toHaveLength(1)
  const words = texts(await draw()).join('\n')
  expect(words).toContain('Release notes could not be fetched at launch; the update is 2026.99.3.')
  expect(buttons(await draw())).toHaveLength(1)
})

test('a missing notes file reads as the tombstone', async () => {
  delete files['/home/u/.cache/cs/update-notes-full-2026.99.3']
  await start()
  expect(opens()).toHaveLength(1)
  expect(texts(await draw()).join('\n')).toContain('could not be fetched')
})

test('another pane id is not the mod\'s to draw', async () => {
  await start()
  expect(await hooks['ui.render:Pane']($, { requestId: 'someone-else' }, async () => 'other')).toBe('other')
})
```

- [ ] **Step 3: Run to see them fail**

Run: `cd mods/cs-update && bun test 2>&1 | tail -5`
Expected: every test fails (module not found).

- [ ] **Step 4: Write the module**

`mods/cs-update/hooks/register.tsx`:

```tsx
/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-update mod: when a cs launch found a newer release, one pane per load with its release notes, `1` to install it in place, Esc for later.
// ABOUTME: Reads the launch's verdict from CS_UPDATE_AVAILABLE / CS_UPDATE_BIN and the span cs cached; /cs-update reopens the pane; session.start writes a heartbeat for doctor.
import type { On, EngineInterface, PluginOptions } from 'claude-code'

declare const h: any
declare const Fragment: any

export const PANE = 'cs-update'
// The /config row (`cs-update.showReleaseNotes`): off, the launch pane is
// skipped and /cs-update still opens it.
export const OPTION = 'showReleaseNotes'
// Doctor observes the mod RUNNING, not merely installed (see cs-rotate).
export const HEARTBEAT = '.cs/local/cs-update.heartbeat'
// Where cs writes the id of the conversation it launched; a teammate claude
// in the same directory has its own id and must not pop its own pane.
export const STATE = '.cs/local/state'
// KEEP IN SYNC with check_update_notify in lib/20-update.sh: the file cs
// caches the pending release's changelog span in, keyed by that version.
export const NOTES = (home: string, version: string) => `${home}/.cache/cs/update-notes-full-${version}`
// How long `cs -update` may take: the download, the checksum, the signature.
export const UPDATE_TIMEOUT_MS = 600000

export type Section = { version: string; lines: string[] }

// Links, bold and inline code, as changelog_summaries strips them in bash
// (_md_strip_inline): the pane shows the words, never the markup.
export function stripInline(s: string): string {
  return s
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\*\*([^*]*)\*\*/g, '$1')
    .replace(/`([^`]*)`/g, '$1')
}

// The span as check_update_notify caches it: `## X.Y.Z` opens a section; its
// prose and bullets are kept in order with the marks stripped; `###` labels,
// comments and blank lines are dropped. A continuation line keeps its indent.
export function parseSpan(text: string): Section[] {
  const sections: Section[] = []
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\s+$/, '')
    if (line.startsWith('## ')) { sections.push({ version: line.slice(3).trim(), lines: [] }); continue }
    if (sections.length === 0) continue
    if (line === '' || line.startsWith('#') || line.startsWith('<!--')) continue
    sections[sections.length - 1].lines.push(stripInline(line))
  }
  return sections
}

// What the pane shows. Module state survives a /clear (as in cs-rotate) and is
// dropped on a reload, which is what "once per load" means.
let version: string | undefined
let sections: Section[] | undefined
let accent: string | undefined
let shown = false

export function register(on: On, options: PluginOptions) {
  version = undefined; sections = undefined; accent = undefined; shown = false
  const wanted = options[OPTION] !== false

  on('session.start', async ($, e, next) => {
    if (await $.fs.exists(`${e.cwd}/.cs/local`)) {
      await $.fs.write(`${e.cwd}/${HEARTBEAT}`, `${new Date().toISOString()}\n`)
    }
    if (wanted && !shown && await isLead($, e.cwd)) {
      const pending = await $.env.get('CS_UPDATE_AVAILABLE')
      if (pending) { shown = true; await openPane($, e.cwd, pending) }
    }
    return next(e)
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE || version === undefined) return next(e)
    const { Box, Text, Button } = await $.ui.resolve(e)
    // A lone pane draws no title of its own (the tab shows only with two or
    // more), so the body opens with it. Version headings take the session
    // colour cs recorded, as the status bar's name does; a continuation line
    // (indented in the changelog) hangs under its bullet.
    return (
      <Box flexDirection="column" paddingX={1}>
        <Text bold>{`cs ${version} is available`}</Text>
        {sections === undefined || sections.length === 0
          ? <Box marginTop={1}><Text>{`Release notes could not be fetched at launch; the update is ${version}.`}</Text></Box>
          : sections.map(s => (
              <Box key={`v-${s.version}`} flexDirection="column" marginTop={1}>
                <Text bold color={accent}>{s.version}</Text>
                {s.lines.map((line, j) => (
                  <Box key={`l-${s.version}-${j}`} marginLeft={line.startsWith(' ') ? 2 : 0}>
                    <Text>{line.startsWith(' ') ? line.trimStart() : line}</Text>
                  </Box>
                ))}
              </Box>
            ))}
        <Box marginTop={1}>
          {/* a Button is a block: nested in a Text the engine refuses the whole tree (measured in cs-rotate), so the keys stand in a Box */}
          <Button key="cs-update-now" hotkey="1" plain label="update now" onPress={() => runUpdate($)} />
          <Text dimColor>{'   Esc: later'}</Text>
        </Box>
      </Box>
    )
  })
}

// The conversation cs launched is the one whose id cs recorded before the
// launch; a teammate in the same directory reads the same file and does not
// match. A directory without the file is not a cs session: no pane. The id
// may be quoted (KEEP IN SYNC with ownsRotation in mods/cs-rotate).
async function isLead($: EngineInterface, cwd: string): Promise<boolean> {
  let state: string
  try { state = await $.fs.read(`${cwd}/${STATE}`) } catch { return false }
  const lead = state.match(/^claude_session_id: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
  return lead !== undefined && lead === (await $.session.id())
}

// The session colour cs recorded, for the version headings; none is fine.
async function sessionColor($: EngineInterface, cwd: string): Promise<string | undefined> {
  try {
    const state = await $.fs.read(`${cwd}/${STATE}`)
    return state.match(/^claude_session_color: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
  } catch { return undefined }
}

async function openPane($: EngineInterface, cwd: string, pending: string) {
  version = pending
  accent = await sessionColor($, cwd)
  const home = await $.env.get('HOME')
  let text = ''
  try { text = home ? await $.fs.read(NOTES(home, pending)) : '' } catch { text = '' }
  sections = parseSpan(text)
  // focus is a request the surface grants only over an idle, empty composer;
  // without it the keys stay with the prompt and `1` does nothing.
  await $.ui.open({ id: PANE, title: `cs ${pending} is available`, focus: true, closeOnEscape: true })
}

async function runUpdate(_$: EngineInterface) {
  // Task 4 fills this in.
}
```

- [ ] **Step 5: Run the bun tests**

Run: `cd mods/cs-update && bun test 2>&1 | tail -5`
Expected: all pass, `0 fail`.

- [ ] **Step 6: Register the mod with cs (manifest, doctor) and write the bash suite**

In `lib/01-manifests.sh`, after `cs-rotate/hooks/register.tsx` inside `CS_MOD_FILES`, add:

```bash
    cs-update/.claude-plugin/plugin.json
    cs-update/hooks/hooks.json
    cs-update/hooks/register.tsx
```

In `lib/60-doctor.sh`, after `_doctor_check_mod cs-rotate`, add `_doctor_check_mod cs-update`.

Create `tests/test_mod_update.sh`:

```bash
#!/usr/bin/env bash
# ABOUTME: Tests for the cs-update mod under mods/cs-update (a Claude Code function-hooks plugin).
# ABOUTME: Pins the manifest and its /config field, the cache-name pin against lib/20-update.sh; runs the bun tests and plugin validate when present.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
MOD="$SCRIPT_DIR/../mods/cs-update"

setup() { :; }
teardown() { :; }

test_mod_manifest_names_the_plugin_its_module_and_the_config_field() {
    assert_eq "cs-update" "$(jq -r .name "$MOD/.claude-plugin/plugin.json")" "plugin name" || return 1
    local module
    module="$(jq -r '.modules[0]' "$MOD/hooks/hooks.json")"
    assert_eq "./register.tsx" "$module" "hooks.json names the register module" || return 1
    assert_file_exists "$MOD/hooks/$module" "the named module exists" || return 1
    assert_eq "boolean" "$(jq -r .userConfig.showReleaseNotes.type "$MOD/.claude-plugin/plugin.json")" "the /config row is a toggle" || return 1
    assert_eq "true" "$(jq -r .userConfig.showReleaseNotes.default "$MOD/.claude-plugin/plugin.json")" "on by default" || return 1
    grep -q "export const OPTION = 'showReleaseNotes'" "$MOD/hooks/register.tsx" \
        || { echo "  FAIL: the module reads a field the manifest does not declare"; return 1; }
}

# The cache file is named in two languages: bash writes it, the mod reads it.
test_mod_reads_the_cache_file_bash_writes() {
    grep -q 'update-notes-full-\$UPDATE_AVAILABLE' "$SCRIPT_DIR/../lib/20-update.sh" \
        || { echo "  FAIL: lib/20-update.sh no longer writes update-notes-full-<version>"; return 1; }
    grep -q 'update-notes-full-\${version}' "$MOD/hooks/register.tsx" \
        || { echo "  FAIL: the mod no longer reads update-notes-full-<version>"; return 1; }
}

test_mod_is_deployed_by_the_installer_and_checked_by_doctor() {
    assert_file_contains "$SCRIPT_DIR/../install.sh" "cs-update/hooks/register.tsx" "install.sh lists the module" || return 1
    assert_file_contains "$SCRIPT_DIR/../lib/60-doctor.sh" "_doctor_check_mod cs-update" "doctor has a row for it" || return 1
}

test_mod_unit_tests_pass_under_bun() {
    if ! command -v bun >/dev/null 2>&1; then
        echo "    SKIP: bun not on PATH"
        return 77
    fi
    local out
    out="$(cd "$MOD" && bun test 2>&1)" || { echo "$out"; return 1; }
    out="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
    assert_output_contains "$out" " 0 fail" "no unit test fails" || return 1
    assert_output_not_contains "$out" " 0 pass" "the suite ran something" || return 1
}

test_mod_validate_inventories_the_hooks_and_calls() {
    if ! command -v claude >/dev/null 2>&1; then
        echo "    SKIP: claude not on PATH"
        return 77
    fi
    local out raw="${TMPDIR:-/tmp}/cs-mod-update-validate.$$"
    env -u ANTHROPIC_API_KEY claude plugin validate "$MOD" > "$raw" 2>&1
    local status=$?
    out="$(sed 's/\x1b\[[0-9;]*m//g' "$raw")"; rm -f "$raw"
    assert_eq "0" "$status" "validate exits 0" || { echo "$out"; return 1; }
    assert_output_contains "$out" "Validation passed" "manifest and hooks validate" || return 1
    if ! grep -q 'hooks:' <<< "$out"; then
        echo "    SKIP: this claude ($(claude --version 2>/dev/null | head -1)) does not inventory function hooks"
        return 77
    fi
    assert_output_contains "$out" 'env reads: CS_UPDATE_AVAILABLE, CS_UPDATE_BIN, HOME' "the mod reads the launch verdict and nothing else" || return 1
    assert_output_contains "$out" '$.process.run (via runUpdate)' "the update runs in one place" || return 1
    assert_output_not_contains "$out" '$.http.fetch' "no network in the mod" || return 1
}

run_test test_mod_manifest_names_the_plugin_its_module_and_the_config_field
run_test test_mod_reads_the_cache_file_bash_writes
run_test test_mod_is_deployed_by_the_installer_and_checked_by_doctor
run_test test_mod_unit_tests_pass_under_bun
run_test test_mod_validate_inventories_the_hooks_and_calls

report_results
```

The validate test's `$.process.run (via runUpdate)` pin goes green in Task 4; until then it fails, which is the point of writing it now.

- [ ] **Step 7: Build, run the three bash suites**

Run: `chmod +x tests/test_mod_update.sh && ./build.sh >/dev/null && bash tests/test_mod_update.sh 2>&1 | tail -8; bash tests/test_install.sh 2>&1 | tail -3; bash tests/test_doctor.sh 2>&1 | tail -3`
Expected: `test_mod_update.sh` passes all but `test_mod_validate_inventories_the_hooks_and_calls` (the `runUpdate` pin, until Task 4) or skips it; `test_install.sh` and `test_doctor.sh` all pass (the manifest test compares `CS_MOD_FILES` with `find mods -type f -not -path '*/test/*'`, so the three new entries must be exactly the three new files).

- [ ] **Step 8: Commit**

```bash
git add mods/cs-update lib/01-manifests.sh lib/60-doctor.sh install.sh bin/cs tests/test_mod_update.sh
git commit -m "cs-update mod: the release-notes pane, once per launch, for the conversation cs launched

Claude-Session: https://claude.ai/code/session_01Vq9cY3NDp19s9ES6ALgnBD"
```

---

### Task 4: the update key

**Files:**
- Modify: `mods/cs-update/hooks/register.tsx` (`runUpdate`, the pane footer)
- Test: `mods/cs-update/test/register.test.ts`

**Interfaces:**
- Consumes: `$.process.run(argv, { timeoutMs })` resolving `{ exitCode, stdout, stderr }`; `CS_UPDATE_BIN`.
- Produces: module state `phase: 'idle' | 'running' | 'done' | 'failed'` and `outcome: string`, drawn in the pane footer.

- [ ] **Step 1: Write the failing tests**

Append to `mods/cs-update/test/register.test.ts`:

```ts
test('1 runs cs -update once, by the exported path, with a ten-minute timeout, and reports the install', async () => {
  await start()
  // The key is gone from the redraw once pressed, so the callback is kept
  // and pressed twice; the run is held in flight so the second press lands
  // while the first is running.
  let release!: (v: any) => void
  ;($ as any).process.run = async (argv: string[], init: any) => { runs.push({ argv, init }); return new Promise(r => { release = r }) }
  const press = buttons(await draw())[0].props.onPress
  const first = press()
  const second = press()
  await Promise.resolve()
  release({ exitCode: 0, stdout: '', stderr: '' })
  await first; await second
  expect(runs).toHaveLength(1)
  expect(runs[0].argv).toEqual(['/opt/cs/bin/cs', '-update'])
  expect(runs[0].init).toMatchObject({ timeoutMs: 600000 })
  const words = texts(await draw()).join('\n')
  // Version-neutral: cs -update installs whatever is latest when pressed,
  // which may be newer than the launch saw.
  expect(words).toContain('Update finished. Takes effect on your next launch.')
  expect(buttons(await draw())).toHaveLength(0)
  expect(invalidated).toContain('ui.render')
})

test('two presses before the path lookup resolves still run once', async () => {
  await start()
  let giveBin!: (v: any) => void
  ;($ as any).env.get = async (name: string) => name === 'CS_UPDATE_BIN' ? new Promise(r => { giveBin = r }) : envVars[name]
  const press = buttons(await draw())[0].props.onPress
  const a = press(); const b = press()
  await Promise.resolve()
  giveBin('/opt/cs/bin/cs')
  await a; await b
  ;($ as any).env.get = async (name: string) => envVars[name]
  expect(runs).toHaveLength(1)
})

test('while the update runs the pane says so and hides the key', async () => {
  await start()
  let release!: (v: any) => void
  ;($ as any).process.run = async (argv: string[], init: any) => { runs.push({ argv, init }); return new Promise(r => { release = r }) }
  const pressed = buttons(await draw())[0].props.onPress()
  await Promise.resolve()
  const words = texts(await draw()).join('\n')
  expect(words).toContain('updating')
  expect(buttons(await draw())).toHaveLength(0)
  release({ exitCode: 0, stdout: '', stderr: '' })
  await pressed
})

test('a non-zero exit shows the last stderr lines and keeps the key for another try', async () => {
  await start()
  runResult = { exitCode: 1, stdout: '', stderr: 'a\nb\nc\nd\ne\nf\nchecksum mismatch\n' }
  await buttons(await draw())[0].props.onPress()
  const words = texts(await draw()).join('\n')
  expect(words).toContain('cs -update exited 1')
  expect(words).toContain('checksum mismatch')
  expect(words).not.toContain('\na\n')
  expect(buttons(await draw())).toHaveLength(1)
})

test('a run that cannot start shows the rejection', async () => {
  await start()
  runResult = new Error('spawn ENOENT')
  await buttons(await draw())[0].props.onPress()
  expect(texts(await draw()).join('\n')).toContain('spawn ENOENT')
})

test('no CS_UPDATE_BIN means the key says so instead of running nothing', async () => {
  delete envVars.CS_UPDATE_BIN
  await start()
  await buttons(await draw())[0].props.onPress()
  expect(runs).toHaveLength(0)
  expect(texts(await draw()).join('\n')).toContain('cs -update')
})
```

- [ ] **Step 2: Run to see them fail**

Run: `cd mods/cs-update && bun test 2>&1 | grep -E 'fail|pass' | tail -3`
Expected: the five new tests fail (`runs` stays empty; the body lacks the strings).

- [ ] **Step 3: Implement `runUpdate` and the footer**

In `register.tsx`, replace the module state block and `runUpdate`, and the footer inside the Pane render:

```tsx
let version: string | undefined
let sections: Section[] | undefined
let shown = false
// The update key's life: idle until pressed, running while cs -update is,
// then what happened. `failed` keeps the key, so a transient failure (a
// download) gets another press; `done` retires it, since a second update
// would install the same version again.
let phase: 'idle' | 'running' | 'done' | 'failed' = 'idle'
let outcome = ''
```

In `register()` reset them too: `phase = 'idle'; outcome = ''`.

Footer (replace the `<Box marginTop={1}>` block in the Pane render):

```tsx
        <Box marginTop={1} flexDirection="column">
          {phase === 'running' && <Text dimColor>{`updating… running cs -update ${version}`}</Text>}
          {(phase === 'done' || phase === 'failed') && <Text>{outcome}</Text>}
          {(phase === 'idle' || phase === 'failed') && (
            <Box>
              {/* a Button is a block: nested in a Text the engine refuses the whole tree (measured in cs-rotate), so the keys stand in a Box */}
              <Button key="cs-update-now" hotkey="1" plain label="update now" onPress={() => runUpdate($)} />
              <Text dimColor>{'   Esc: later'}</Text>
            </Box>
          )}
          {phase === 'done' && <Text dimColor>{'Esc: close'}</Text>}
        </Box>
```

`runUpdate`:

```tsx
// Runs the update cs would run from the shell, by the path launch exported
// (no shell: `$.process.run` takes an argv, and the claude process's PATH is
// not the launching shell's). The pane keeps the outcome until dismissed, so
// it is read rather than flashed. The new files take effect on the next
// launch: this claude and its loaded mods keep the old code.
async function runUpdate($: EngineInterface) {
  // Claimed before the first await: two presses in one tick must not both
  // pass the guard and start two installers.
  if (phase === 'running' || phase === 'done') return
  phase = 'running'; outcome = ''
  $.ui.invalidate('ui.render')
  try {
    const bin = await $.env.get('CS_UPDATE_BIN')
    if (!bin) {
      phase = 'failed'; outcome = 'The launch did not say where cs is; run `cs -update` from a shell.'
      $.ui.invalidate('ui.render'); return
    }
    const { exitCode, stderr } = await $.process.run([bin, '-update'], { timeoutMs: UPDATE_TIMEOUT_MS })
    if (exitCode === 0) {
      // Version-neutral: cs -update resolves the latest release when it runs,
      // which may be newer than the one this launch saw.
      phase = 'done'; outcome = 'Update finished. Takes effect on your next launch.'
    } else {
      const tail = stderr.split('\n').filter(l => l.trim() !== '').slice(-5).join('\n')
      phase = 'failed'; outcome = `cs -update exited ${exitCode}.\n${tail}`
    }
  } catch (err) {
    phase = 'failed'; outcome = `cs -update did not run: ${String(err instanceof Error ? err.message : err)}`
  }
  $.ui.invalidate('ui.render')
}
```

- [ ] **Step 4: Run the bun tests and the validate pin**

Run: `cd mods/cs-update && bun test 2>&1 | tail -4 && cd ../.. && bash tests/test_mod_update.sh 2>&1 | tail -4`
Expected: bun `0 fail`; `test_mod_update.sh` all pass (or validate skipped where claude does not inventory).

- [ ] **Step 5: Commit**

```bash
git add mods/cs-update
git commit -m "cs-update mod: 1 runs cs -update in place and the pane keeps the outcome

Claude-Session: https://claude.ai/code/session_01Vq9cY3NDp19s9ES6ALgnBD"
```

---

### Task 5: `/cs-update` reopens the pane

**Files:**
- Modify: `mods/cs-update/hooks/register.tsx`
- Test: `mods/cs-update/test/register.test.ts`, `tests/test_mod_update.sh` (validate pin)

**Interfaces:**
- Consumes: `$.command.register({ name, description })`, `command.run` events narrowed by `{ command: 'cs-update' }`.

- [ ] **Step 1: Write the failing tests**

Append to the bun file:

```ts
test('the mod registers /cs-update at load', async () => {
  await start()
  expect(commands.map(c => c.name)).toEqual(['cs-update'])
})

const runCommand = () => hooks['command.run:cs-update']($, { command: 'cs-update', args: '', cwd: '/work' }, async () => ({ text: 'unhandled' }))

test('/cs-update reopens the pane after a dismiss, and with the option off, and answers the command', async () => {
  load({ [OPTION]: false })
  await start()
  expect(opens()).toHaveLength(0)
  expect(await runCommand()).toEqual({ text: '' })
  expect(opens()).toHaveLength(1)
  expect(texts(await draw()).join('\n')).toContain('2026.99.3')
})

test('/cs-update with nothing pending says so as its output and opens nothing', async () => {
  delete envVars.CS_UPDATE_AVAILABLE
  await start()
  expect(await runCommand()).toEqual({ text: 'This launch found no newer cs; the check runs again at the next launch.' })
  expect(opens()).toHaveLength(0)
})

test('/cs-update in a teammate opens nothing', async () => {
  sessionId = 'uuid-teammate'
  await start()
  expect(await runCommand()).toEqual({ text: 'The release-notes pane belongs to the conversation cs launched.' })
  expect(opens()).toHaveLength(0)
})
```

- [ ] **Step 2: Run to see them fail**

Run: `cd mods/cs-update && bun test 2>&1 | grep -E 'fail|pass' | tail -3`
Expected: three new failures (`commands` empty; no `command.run:cs-update` hook).

- [ ] **Step 3: Implement**

In `register()`, inside the `session.start` hook before the `wanted` check, register the command once per load (a module flag `registered`):

```tsx
let registered = false
```

reset in `register()`, and in `session.start`:

```tsx
    if (!registered) {
      registered = true
      await $.command.register({ name: 'cs-update', description: 'Release notes for the pending cs update, with 1 to install it.' })
    }
```

Add the hook after the Pane render hook:

```tsx
  // On demand: the same pane, whether or not the launch opened it (the
  // option off, or dismissed). A registered command is answered with
  // `{ text }` (the contract; an unanswered run prints "no hook answered"),
  // so the pane is the answer and the text is empty. A launch that found
  // nothing pending has nothing to show, and says so instead; a teammate
  // (which inherits the exports) is refused as the launch pane refuses it.
  on('command.run', { command: 'cs-update' }, async ($, e) => {
    const cwd = await $.session.cwd()
    if (!(await isLead($, cwd))) return { text: 'The release-notes pane belongs to the conversation cs launched.' }
    const pending = await $.env.get('CS_UPDATE_AVAILABLE')
    if (!pending) return { text: 'This launch found no newer cs; the check runs again at the next launch.' }
    shown = true
    await openPane($, cwd, pending)
    return { text: '' }
  })
```

`openPane` already resets `version`/`sections`; `phase` is left as it is, so a pane reopened after a finished update still shows `done`.

- [ ] **Step 4: Update the validate pin and run everything**

In `tests/test_mod_update.sh`, after the `$.process.run (via runUpdate)` assertion add:

```bash
    assert_output_contains "$out" 'command.run{command=cs-update}' "the reopen command is hooked" || return 1
```

Run: `cd mods/cs-update && bun test 2>&1 | tail -4 && cd ../.. && bash tests/test_mod_update.sh 2>&1 | tail -4`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add mods/cs-update tests/test_mod_update.sh
git commit -m "cs-update mod: /cs-update reopens the pane on demand

Claude-Session: https://claude.ai/code/session_01Vq9cY3NDp19s9ES6ALgnBD"
```

---

### Task 6: docs

**Files:**
- Modify: `README.md` (the feature bullet list near line 36, the health-checks bullet near line 58, the install list near line 110)
- Modify: `docs/configuration.md` (near the `CS_NO_FUNCTION_HOOKS` entry, around line 232)
- Modify: `CHANGELOG.md` (`## Unreleased`)

- [ ] **Step 1: README**

After the conversation-rotation bullet, add a bullet:

```markdown
- **Release notes in the session** - when a launch finds a newer cs, the `cs-update` mod (a function-hooks plugin the installer deploys beside `cs-rotate`) opens one pane with the full changelog for every version above the installed one, once per launch, in the conversation cs launched: `1` runs `cs -update` in place (the new files take effect on the next launch; the pane keeps the outcome until you close it), `Esc` closes it, and `/cs-update` brings it back. `/config` → `cs-update.showReleaseNotes` turns the launch pane off; `/cs-update` still works. `CS_NO_FUNCTION_HOOKS=1` withholds both mods.
```

In the health-checks bullet, change `whether the cs-rotate mod ran` to `whether the cs-rotate and cs-update mods ran`. In the install list, change `and the \`cs-rotate\` mod` to `and the \`cs-rotate\` and \`cs-update\` mods`.

- [ ] **Step 2: docs/configuration.md**

Beside the `CS_NO_FUNCTION_HOOKS` entry add:

```
# Exported by a cs launch, never set by hand: the version a newer cs was
# found at and the path of the running cs. The cs-update mod reads them to
# draw the release-notes pane and to run `cs -update` from inside the
# session. Absent when nothing is pending.
CS_UPDATE_AVAILABLE
CS_UPDATE_BIN
```

And a short subsection wherever the file lists in-session switches:

```
The release-notes pane is a Claude Code `/config` row, `cs-update.showReleaseNotes`
(on by default). Off, a launch opens no pane; `/cs-update` still opens it.
```

- [ ] **Step 3: CHANGELOG**

Under `## Unreleased`, add `### Added`:

```markdown
### Added
- Release notes in the session. When a launch finds a newer cs, the new `cs-update` mod opens one pane with the full changelog for every version above the installed one, once per launch, in the conversation cs launched. `1` runs `cs -update` in place through the engine's process runner (no shell; the path and the version come from the launch, never from the mod's own check) and the pane keeps the outcome until closed, since the new files take effect on the next launch. `Esc` closes it; `/cs-update` reopens it; `/config` → `cs-update.showReleaseNotes` turns the launch pane off. The notify check now caches the changelog span beside the summaries (`~/.cache/cs/update-notes-full-<version>`), and a launch with an update pending exports `CS_UPDATE_AVAILABLE` and `CS_UPDATE_BIN`.
```

- [ ] **Step 4: Vale and the docs suite**

Run: `vale --config ~/.claude/vale/.vale.ini --output=line --no-wrap README.md CHANGELOG.md docs/configuration.md 2>&1 | grep -v '^$' | head; bash tests/test_docs.sh 2>&1 | tail -3` (skip vale if the alert set matches the previous tag's; only new alerts count).
Expected: no new alerts; docs suite green.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/configuration.md CHANGELOG.md
git commit -m "docs: the cs-update mod, its /config row and the two launch exports

Claude-Session: https://claude.ai/code/session_01Vq9cY3NDp19s9ES6ALgnBD"
```

---

### Task 7: install, live measurement, gate

**Files:**
- None new. Evidence under `scratchpad/cs-update-live/`; findings in the narrative.

- [ ] **Step 1: Full local gate and shellcheck**

Run: `bash tests/run_all.sh > scratchpad/cs-update-gate.out 2>&1; tail -3 scratchpad/cs-update-gate.out; { git ls-files '*.sh'; printf '%s\n' bin/cs bin/cs-secrets bin/cs-statusline bin/cs-subagent-statusline; } | xargs shellcheck -S error && echo shellcheck-ok`
Expected: all suites pass; shellcheck clean. Try `claude-tmux:remote-tests --host ghost` first; if its host store is still missing, record "local only".

- [ ] **Step 2: Install and check doctor**

Run: `./install.sh > /dev/null && ls ~/.claude/skills/cs-update/hooks && cs -doctor 2>&1 | grep -i 'cs-update\|drift'`
Expected: the three files deployed; doctor shows no mod drift; the cs-update row reads "has not run" until a launch.

- [ ] **Step 3: Live: the pane on a seeded cache**

In a tmux window, seed a pending version without touching the network:

```bash
mkdir -p ~/.cache/cs
printf '%s 2099.1.1\n' "$(date +%s)" > ~/.cache/cs/update-check
sed -n '1,/^## 2026\.9\.1[0-9]$/p' CHANGELOG.md | sed '$d' > ~/.cache/cs/update-notes-full-2099.1.1
: > ~/.cache/cs/update-notes-2099.1.1
cs cs-update-live
```

The terminal must be at least 144 columns wide: below that the engine holds a pane a plugin opens on its own (measured for cs-rotate's preview). Expected: the launch banner shows `2099.1.1 available`; a few seconds in, the pane opens with `cs 2099.1.1 is available` as its first body line (a lone pane draws no tab title), the version headings in the session colour, the sections, and `1: update now   Esc: later`; the pane has the keys (focus was requested over an idle, empty composer). Screenshot to `scratchpad/cs-update-live/pane.png` (imgcat to see it). Press Esc: closes. Type `/cs-update`: reopens, and the transcript shows no "no hook answered" line. Exit.

The option: `/config`, set `cs-update.showReleaseNotes` off, exit, `cs cs-update-live` again: no pane at launch (a `/clear` proves nothing here, since `session.start` does not fire on `/clear` and the pane was already shown). `/cs-update` still opens it. Set it back on.

Then remove the seed (`rm ~/.cache/cs/update-check ~/.cache/cs/update-notes-*2099*`) and `cs -rm cs-update-live`.

- [ ] **Step 4: Live: the mod's own file overwritten under an open pane**

No published release carries this mod yet, so a real `cs -update` would not touch `~/.claude/skills/cs-update/` and proves nothing about self-overwrite. Measure it directly: with the seeded pane from Step 3 open, from another shell change one comment in the checkout's `mods/cs-update/hooks/register.tsx`, run `./install.sh > /dev/null` (which rewrites the deployed module), then `git checkout -- mods/cs-update/hooks/register.tsx && ./install.sh > /dev/null`. Watch the engine for the whole minute: the pane stays drawn and answers Esc, no reload notice, no crash; `claude --debug` output, if used, shows what the loader did. Record in `scratchpad/cs-update-live/notes.md`.

- [ ] **Step 5: Live: the key runs the real update**

With the seed still in place, press `1` in the pane. Expected: `updating…`, then either `Update finished. Takes effect on your next launch.` (the installer fetched the latest published release, which is older than or equal to this checkout's version; that is fine, the path is what is measured) or the non-zero arm with cs's own message. The engine keeps running with the pane open. After Esc and exit, `./install.sh` from the checkout again, since the real update replaced `bin/cs` with the published release. Record the outcome.

If the engine reloads the mod or misbehaves when its own file is overwritten, stop and report before merging: the fix is a design change (for example, copying the mod aside before the update), not a patch.

- [ ] **Step 6: Foreign-model review**

Offer `/codex:review` on the branch to Alex (Alex runs it). Fold findings; re-run the suites touched.

- [ ] **Step 7: Hand the merge to Alex**

Report: branch, commits, suite counts, the live findings with the screenshot, what was skipped (ghost, if so). Alex decides on `/finish`.

---

## Self-review

- **Spec coverage.** Decisions 1 (second mod, deployment) → Task 3; 2 (env verdict, no version logic) → Tasks 2, 3; 3 (full cache) → Task 1; 4 (once per load, `/cs-update`) → Tasks 3, 5; 5 (lead only) → Task 3 (`isLead` by the state file, since `session.start` carries no `agentId`; the spec's wording is corrected in the same commit as Task 3); 6 (button, `CS_UPDATE_BIN`, outcome kept) → Task 4; 7 (in-place effect, measured) → Task 7; 8 (`/config` toggle) → Tasks 3, 5; 9 (look) → Task 3's render, with the scroll question left to Task 7's measurement. Error handling section → Tasks 3, 4, 5 tests. Out of scope → untouched.
- **Placeholders.** None; every step carries its code.
- **Codex plan review (2026-09-22), folded.** Fixture boundary (Task 1), array-blind test walkers (Task 3), the double-press test and the un-restored runner (Task 4), the guard before the first await (Task 4), `command.run` answering `{ text }` and lead-only (Task 5), exports cleared before the conditional and a no-network "current" case (Task 2), banner fixtures seeding the full file (Task 1), the quoted-id parse (Task 3), title in the body + session-colour headings + hanging indent + `focus: true` (Task 3), a version-neutral success line (Task 4), the option measured across launches and the self-overwrite measured directly (Task 7). Left as is: the `sed 's/\x1b…'` strip in the bun-runner test matches `tests/test_mod_rotate.sh`, which is green on the macOS lane; the assertions do not depend on the strip.
- **Type consistency.** `Section = { version, lines }` in Task 3 is what Task 4's render iterates; `PANE`, `OPTION`, `HEARTBEAT`, `NOTES`, `UPDATE_TIMEOUT_MS`, `parseSpan`, `stripInline`, `runUpdate`, `openPane`, `isLead` are named identically across Tasks 3 to 5; the fake `$` in Task 3's test file already carries `process.run` and `command.register` for Tasks 4 and 5.
