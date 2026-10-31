/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-panel mod: bare /cs (and /cs-panel) opens a pane of cs's settings, its mods' /config rows and its CS_* settings, and changes one per key press.
// ABOUTME: The only effects of the mod: its hooks, its module state, the cs runs, $.config.set, and the tables of every line it hands the engine.
import type { EngineInterface, On } from 'claude-code'
import { drawPane, ringBack, ringOf, type Handlers, type PanelView } from './draw'
import {
  isModProvider, isRowId, linesOf, modChange, modRowsOf, parseSettings, scopeFor, settingChange, shownOf, writeArgv,
  type Action, type Ask, type Line, type ModRow, type Pending, type RowId, type Setting,
} from './settings'

declare const h: any
declare const Fragment: any

export const PANE = 'cs-panel'
const TITLE = 'cs'
// The dock opens this wide when there is room (ignored inline): the 58-column
// body holds a 22-cell name, every column and the widest strip.
const DOCK_COLUMNS = 60
// How long each cs run may take.
const LIST_TIMEOUT_MS = 10000
const WRITE_TIMEOUT_MS = 10000

// Every line handed to an engine surface, one table per surface; none names
// the plugin first (the engine prefixes it). tests/test_mod_tables.sh greps
// this file for inline literals.
export const COMMANDS = {
  'cs-panel': { name: 'cs-panel', description: "cs's settings: its mods' /config rows and its own CS_* settings, per machine or per session.", immediate: true },
} as const

export const REPLIES = {
  noBin: 'The launch did not say where cs is (CS_BIN); open this conversation with cs to change its settings.',
  opened: 'cs settings are in the panel: Tab moves, c or Enter changes, u puts back the default, p changes it for this session only, Esc closes.',
  notPlaced: (reason: string) => `The panel is open but not drawn yet: ${reason}`,
  failed: (reason: string) => `The panel did not start: ${reason}`,
} as const

// `values` is every value a choice takes when the labels cannot hold them, so
// one past the labels can be typed.
export const ASKS = {
  header: 'cs',
  setting: (label: string, key: string, values: readonly string[]) =>
    `What should ${label} (${key}) be?${values.length === 0 ? '' : ` It takes ${values.join(', ')}.`} Pick one, or type a value under Other.`,
  mod: (label: string, key: string, values: readonly string[]) =>
    `What should ${label} (${key}) be?${values.length === 0 ? '' : ` It takes ${values.join(', ')}.`} Pick one, or type a value under Other.`,
} as const

export const TOASTS = {
  // cs's own reply to a write: what it wrote, where, and when it applies.
  written: (line: string) => line,
  // `why` is runCs's (`exited <code>: <cs's own line>`) or a config.set deny.
  refused: (key: string, why: string) => `${key} not changed: ${why}`,
  modSaved: (key: string, value: string, plugin: string) => `${key}=${value} in /config: ${plugin} reloads with it`,
  notNumber: (label: string, answer: string) => `${label} takes a number; got ${answer}`,
  // A key pressed on a drawing older than the row's state: the row is pending
  // or the rows changed.
  notOffered: (action: string, name: string) => `${action} is not offered for ${name} now`,
} as const

// Lines the pane draws above the rows when a source is stale or missing.
// `why` is runCs's: `exited <code>: <stderr's last line>`, or why it did not start.
export const PROBLEMS = {
  failed: (why: string) => `cs -config list ${why}`,
  unreadable: (line: string) => `cs -config list gave a line the panel cannot read: ${line}`,
  empty: 'cs -config list printed no settings',
  modsUnread: (why: string) => `the /config rows could not be read: ${why}`,
} as const

// Work a press or a timer starts and nothing awaits.
export const LOGS = {
  failed: (err: string) => `the panel's background work failed: ${err}`,
} as const

// What the launch exported: where cs is, and the session name this
// conversation runs under. Read once per load; the environment does not change
// under a process.
type Launch = { bin: string; self: string | undefined }

// A name cs gives a session (validate_session_name, and `<base>@<task>` for a
// feature): no leading dot or hyphen, so cs never reads it as a verb.
const SESSION_NAME = /^[A-Za-z0-9_][A-Za-z0-9._-]*(@[A-Za-z0-9._-]+)?$/

// Module state. Reset in register(): a reload drops it and the engine cancels
// its timers; a /clear keeps it.
let launch: Launch | undefined
let settings: Setting[] | undefined
// The porcelain text `settings` was parsed from: an identical answer redraws
// nothing.
let answered: string | undefined
let mods: ModRow[] | undefined
let settingsProblem: string | undefined
let modsProblem: string | undefined
let selected: RowId | undefined
let pending = new Map<RowId, Pending>()
let reading = false
let readAgain = false
let isOpen = false
let registered = false
// Where the focus ring is, for ringBack: `drawn` is the last drawing's keys in
// ring order; `ring` the key the ring was last put on and its place then,
// undefined while the pane does not hold the keys.
let drawn: readonly string[] = []
let ring: { key: string; at: number } | undefined

export function register(on: On) {
  launch = undefined; settings = undefined; answered = undefined; mods = undefined; settingsProblem = undefined; modsProblem = undefined
  selected = undefined; pending = new Map(); reading = false; readAgain = false; isOpen = false; registered = false; drawn = []; ring = undefined

  // /cs-panel, once per load. Nothing opens here: the panel opens only when
  // asked.
  on('session.start', async ($, e, next) => {
    if (!registered) {
      registered = true
      await $.command.register(COMMANDS['cs-panel'])
    }
    return next(e)
  })

  // Bare /cs is this panel's; anything after it is the cs mod's rail. That mod
  // passes the bare form on with next(e) and this hook passes the rest on, so
  // the pair answers the same whichever runs first.
  on('command.run', { command: 'cs' }, async ($, e, next) => {
    if (e.args.trim() !== '') return next(e)
    return openPanel($)
  })

  on('command.run', { command: 'cs-panel' }, async ($) => openPanel($))

  // A render while the pane is not known open is a pane that outlived a
  // reload (the engine re-renders an open pane the moment it reloads the
  // module): its reads resume from a timer, since an invalidate inside a
  // render loops, after asking $.ui.panes, so a stray render after a close
  // reads nothing. A drawing that moves the Button the ring is on puts the
  // ring back on it, or on the selected row once it is gone, from a timer
  // too: asked from inside the render it would land on the drawing being
  // replaced.
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    if (!isOpen) $.clock.after(0, () => inBackground($, resume($)))
    launch ??= await readLaunch($)
    const view: PanelView = { lines: currentLines(), selected, problems: problems(), columns: e.props.bodyColumns, bodyRows: e.props.scroll.bodyRows, hasKeys: e.props.isFocused }
    const next = ringOf(view)
    drawn = next.keys
    if (!view.hasKeys) ring = undefined
    const back = ring && ringBack(ring, next)
    if (back !== undefined) $.clock.after(0, () => inBackground($, refocus($, back)))
    return drawPane(view, $.ui.resolve(e), handlers($))
  })

  // Selection follows the focus ring: Tab or an arrow landing on a row selects
  // it, so the strip and the detail name that row before any key is pressed.
  // The ring moves first; a ring moved to a strip key keeps the selection.
  // Every move, the mod's own included, records where the ring now is.
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
    const moved = await next(e)
    if (moved.deny !== undefined) return moved
    ring = e.element === undefined ? undefined : { key: e.element, at: drawn.indexOf(e.element) }
    if (e.element !== undefined && isRowId(e.element) && lineOf(e.element) !== undefined) select($, e.element)
    return moved
  })

  // Closing the pane (Esc, its mark, a plugin) stops its reads and forgets the
  // ring, which closes with it; a close another hook refused leaves both. Rows
  // stay, so a reopen draws the last answer at once and the first read
  // replaces it.
  on('ui.close', { id: PANE }, async ($, e, next) => {
    const closed = await next(e)
    if (closed.deny === undefined) { isOpen = false; ring = undefined }
    return closed
  })

  // A main-loop turn may have run `cs -config` in a shell: an open pane reads
  // both sources again, without holding the turn's end for it. Nothing else
  // changes a setting while no turn runs but the person's presses, which read
  // again themselves, and the /config menu, which the next hook follows.
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined && isOpen) inBackground($, refresh($))
    return next(e)
  })

  // The /config menu changing a row of cs's mods: let it through untouched,
  // then read the mod rows again once it is written. A failure here never
  // refuses the row: its catch answers what next(e) answered.
  on('config.set', async ($, e, next) => {
    const written = await next(e)
    if (isOpen && written.deny === undefined && isModProvider(e.provider.plugin)) inBackground($, refreshMods($))
    return written
  }).catch(($, e, next) => next(e))
}

// Opens (or raises) the pane and reads both sources at once. Immediate, so it
// opens mid-turn too. The pane counts as open before $.ui.open resolves, since
// the engine draws an opening pane first. A refused open is the answer.
async function openPanel($: EngineInterface): Promise<{ text: string }> {
  try {
    launch ??= await readLaunch($)
    if (launch === undefined) return { text: REPLIES.noBin }
    const wasOpen = isOpen
    isOpen = true
    const opened = await $.ui.open({ id: PANE, title: TITLE, focus: true, closeOnEscape: true, columns: DOCK_COLUMNS }).catch((err: unknown) => {
      isOpen = wasOpen
      throw err
    })
    await refresh($)
    return { text: opened.isPlaced ? REPLIES.opened : REPLIES.notPlaced(opened.reason) }
  } catch (err) {
    return { text: REPLIES.failed(message(err)) }
  }
}

// CS_BIN and CLAUDE_SESSION_NAME; undefined without CS_BIN. A name cs would
// not give a session counts as no session name.
async function readLaunch($: EngineInterface): Promise<Launch | undefined> {
  const bin = await $.env.get('CS_BIN')
  if (!bin) return undefined
  const name = await $.env.get('CLAUDE_SESSION_NAME')
  return { bin, self: name !== undefined && SESSION_NAME.test(name) ? name : undefined }
}

// Reads again for a pane that outlived a reload, once $.ui.panes shows it open.
async function resume($: EngineInterface): Promise<void> {
  launch ??= await readLaunch($)
  if (isOpen || launch === undefined) return
  if (!(await $.ui.panes()).some(p => p.id === PANE) || isOpen) return
  isOpen = true
  await refresh($)
}

// Both sources, single-flight: a read asked for while one runs runs once more
// after it, so a write's effect is never lost to an answer that started before
// it. Each redraws only on a change; a failed source keeps its last rows and
// says why above them.
async function refresh($: EngineInterface): Promise<void> {
  if (reading) { readAgain = true; return }
  reading = true
  try {
    do {
      readAgain = false
      await refreshMods($)
      await refreshSettings($)
    } while (readAgain)
  } finally {
    reading = false
  }
}

async function refreshMods($: EngineInterface): Promise<void> {
  let next: ModRow[]
  try {
    next = modRowsOf(await $.config.list())
  } catch (err) {
    setProblems($, settingsProblem, PROBLEMS.modsUnread(message(err)))
    return
  }
  if (JSON.stringify(next) !== JSON.stringify(mods)) { mods = next; $.ui.invalidate('ui.render') }
  setProblems($, settingsProblem, undefined)
}

async function refreshSettings($: EngineInterface): Promise<void> {
  const run = await runCs($, ['-config', 'list', '--porcelain'], { timeoutMs: LIST_TIMEOUT_MS })
  if (!run.ok) return setProblems($, PROBLEMS.failed(run.why), modsProblem)
  if (run.stdout === answered) return setProblems($, undefined, modsProblem)
  const parsed = parseSettings(run.stdout)
  if ('unreadable' in parsed) return setProblems($, parsed.unreadable === '' ? PROBLEMS.empty : PROBLEMS.unreadable(parsed.unreadable), modsProblem)
  settings = parsed
  answered = run.stdout
  $.ui.invalidate('ui.render')
  setProblems($, undefined, modsProblem)
}

function setProblems($: EngineInterface, ofSettings: string | undefined, ofMods: string | undefined): void {
  if (ofSettings === settingsProblem && ofMods === modsProblem) return
  settingsProblem = ofSettings
  modsProblem = ofMods
  $.ui.invalidate('ui.render')
}

function problems(): string[] {
  return [settingsProblem, modsProblem].filter((p): p is string => p !== undefined)
}

// The lines as they stand: undefined until either source first answered.
function currentLines(): Line[] | undefined {
  if (mods === undefined && settings === undefined) return undefined
  return linesOf(mods ?? [], settings ?? [], pending, launch?.self !== undefined)
}

function lineOf(id: RowId): Extract<Line, { kind: 'row' }> | undefined {
  return currentLines()?.find((l): l is Extract<Line, { kind: 'row' }> => l.kind === 'row' && l.row.id === id)
}

// Puts the ring back on `key`. A refusal needs nothing more: the pane gave up
// the keys and the ring went with them, or a later drawing no longer holds the
// key and puts the ring back itself.
async function refocus($: EngineInterface, key: string): Promise<void> {
  await $.ui.focus({ requestId: PANE, key })
}

function select($: EngineInterface, id: RowId): void {
  if (id === selected) return
  selected = id
  $.ui.invalidate('ui.render')
}

function handlers($: EngineInterface): Handlers {
  return { select: id => select($, id), act: (action, id) => inBackground($, act($, action, id)) }
}

// The one entry for every key and row press. The row is looked up afresh and
// the press refused with a toast when it no longer offers the action (a press
// from a drawing older than the last read or the row's claim). The row is
// claimed before the first await, so a second press finds nothing offered;
// whatever happens, it is released and both sources are read again.
async function act($: EngineInterface, action: Action, id: RowId): Promise<void> {
  const line = lineOf(id)
  if (line === undefined || !line.actions.includes(action)) { $.ui.toast(TOASTS.notOffered(action, id.slice(id.indexOf(':') + 1))); return }
  select($, id)
  pending.set(id, 'asking')
  $.ui.invalidate('ui.render')
  try {
    // A switch, not a table of functions: the engine refuses `$` handed to a
    // callee it cannot name.
    switch (line.row.kind) {
      case 'mod': await changeMod($, line.row.mod, id); break
      case 'setting': await changeSetting($, line.row.setting, action, id); break
    }
  } finally {
    pending.delete(id)
    $.ui.invalidate('ui.render')
    await refresh($)
  }
}

// change and session: settingChange's plan, answered, then one cs write where
// scopeFor says. unset: the write at once, where the value lives. cs's reply
// is the toast either way, so the panel keeps no copy of cs's checks.
async function changeSetting($: EngineInterface, s: Setting, action: Action, id: RowId): Promise<void> {
  let value: string | undefined
  if (action !== 'unset') {
    const plan = settingChange(s)
    const answer = plan.kind === 'now' ? { kind: 'value', value: plan.value } as const : await asked($, ASKS.setting(s.label, s.key, plan.values), plan)
    if (answer === undefined || answer.kind === 'keep') return
    value = answer.kind === 'default' ? undefined : answer.value
  }
  pending.set(id, 'writing')
  $.ui.invalidate('ui.render')
  const run = await runCs($, writeArgv(scopeFor(s, action), launch?.self, s.key, value), { timeoutMs: WRITE_TIMEOUT_MS })
  $.ui.toast(run.ok ? TOASTS.written(lastLine(run.stdout)) : TOASTS.refused(s.key, run.why))
}

// modChange's plan, answered, then $.config.set: the owner's guard runs (cs's
// own for cs.*), since this is another plugin's set, and its deny is the
// toast. The owner reloads with the new value.
async function changeMod($: EngineInterface, m: ModRow, id: RowId): Promise<void> {
  const plan = modChange(m)
  const answer = plan.kind === 'now' ? { kind: 'value', value: plan.value } as const : await asked($, ASKS.mod(m.label, m.key, plan.values), plan)
  if (answer === undefined || answer.kind === 'keep') return
  if (answer.kind === 'notNumber') { $.ui.toast(TOASTS.notNumber(m.label, answer.answer)); return }
  pending.set(id, 'writing')
  $.ui.invalidate('ui.render')
  const result = await $.config.set({ key: m.key, value: answer.value })
  $.ui.toast(result.deny === undefined ? TOASTS.modSaved(m.key, shownOf(result.value), m.plugin) : TOASTS.refused(m.key, result.deny))
}

// The plan's dialog, read; undefined when dismissed (the person chose to
// leave it) or when no one can be asked, as in a -p run.
async function asked<A>($: EngineInterface, question: string, plan: Ask<A>): Promise<A | undefined> {
  let answer: string
  try {
    answer = await $.ui.ask(question, { header: ASKS.header, options: plan.options })
  } catch {
    return undefined
  }
  return plan.read(answer)
}

// Work nothing awaits (a timer's, a press's) reports a failure in the
// transcript rather than vanishing.
function inBackground($: EngineInterface, work: Promise<void>): void {
  work.catch(err => $.ui.log(LOGS.failed(message(err))))
}

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

// Every cs run goes through here: the launch's CS_BIN, an argv, no shell. One
// shape for success and one for failure, so each toast and problem line says
// a failure the same way.
type CsRun = { ok: true; stdout: string } | { ok: false; why: string }
async function runCs($: EngineInterface, args: readonly string[], init: { timeoutMs: number }): Promise<CsRun> {
  if (launch === undefined) throw new Error(`cs ${args.join(' ')} asked before the launch was read`)
  try {
    const r = await $.process.run([launch.bin, ...args], init)
    return r.exitCode === 0 ? { ok: true, stdout: r.stdout } : { ok: false, why: `exited ${r.exitCode}: ${lastLine(r.stderr)}` }
  } catch (err) {
    return { ok: false, why: `did not run: ${message(err)}` }
  }
}

function lastLine(text: string): string {
  return text.split('\n').filter(line => line.trim() !== '').at(-1) ?? ''
}
