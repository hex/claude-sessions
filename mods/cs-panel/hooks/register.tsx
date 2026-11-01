/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-panel mod: bare /cs (and /cs-panel) opens a pane of cs's settings, its mods' /config rows and its CS_* settings, under a filter field, and changes one per Enter or resets one file's.
// ABOUTME: The only effects of the mod: its hooks, its module state, the cs runs, $.config.set, and the tables of every line it hands the engine.
import type { EngineInterface, On } from 'claude-code'
import { CONFIRM, drawPane, FILTER, isChooserKey, noteOf, optionKey, RESET, ringBack, ringOf, WORDS, type Chooser, type Handlers, type PanelView } from './draw'
import {
  changeOf, filterLines, isModProvider, isRowId, labelOf, linesOf, lockOf, modRowsOf, parseSettings, resetArgv, shownOf, writeArgv, writesTo,
  type Answer, type Change, type Line, type ModRow, type Pending, type RowId, type Scope, type Setting,
} from './settings'

declare const h: any
declare const Fragment: any

export const PANE = 'cs-panel'
const TITLE = 'cs'
// The dock's width (an inline pane ignores it): a 58-column body holds every column.
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
  opened: 'cs settings are in the panel: type to filter, the arrows move, Enter changes the row, Esc closes.',
  notPlaced: (reason: string) => `The panel is open but not drawn yet: ${reason}`,
  failed: (reason: string) => `The panel did not start: ${reason}`,
} as const

export const TOASTS = {
  // cs's own reply to a write or a reset: what it changed, where, and when it applies.
  written: (line: string) => line,
  // A reset cs refused, as runCs says it; one asked before cs first listed its settings.
  notReset: (why: string) => `cs settings not reset: ${why}`,
  notRead: 'cs has not listed its settings yet, so nothing was reset',
  // `why` is runCs's (`exited <code>: <cs's own line>`) or a config.set deny.
  refused: (key: string, why: string) => `${key} not changed: ${why}`,
  modSaved: (key: string, value: string, plugin: string) => `${key}=${value} in /config: ${plugin} reloads with it`,
  notNumber: (label: string, text: string) => `${label} takes a number; got ${text}`,
  notNow: (name: string) => `${name} is still changing, or no longer listed; try again`,
  readOnly: (label: string, why: string) => `${label}: ${why}`,
} as const

// Lines the pane draws above the rows when a source is stale or missing.
// `why` is runCs's: `exited <code>: <stderr's last line>`, or why it did not start.
export const PROBLEMS = {
  failed: (why: string) => `cs -config list ${why}`,
  unreadable: (line: string) => `cs -config list gave a line the panel cannot read: ${line}`,
  empty: 'cs -config list printed no settings',
  modsUnread: (why: string) => `the /config rows could not be read: ${why}`,
} as const

// Work a press or a timer starts and nothing awaits; a version cs did not tell.
export const LOGS = {
  failed: (err: string) => `the panel's background work failed: ${err}`,
  noVersion: (why: string) => `cs -version ${why}`,
} as const

// What the launch exported: where cs is, the session name this conversation
// runs under, and the version a newer cs was found at. Read once per load; the
// environment does not change under a process.
type Launch = { bin: string; self: string | undefined; update: string | undefined }

// A name cs gives a session (validate_session_name, and `<base>@<task>` for a
// feature): no leading dot or hyphen, so cs never reads it as a verb.
const SESSION_NAME = /^[A-Za-z0-9_][A-Za-z0-9._-]*(@[A-Za-z0-9._-]+)?$/

// Module state. Reset in register(): a reload drops it and the engine cancels
// its timers; a /clear keeps it.
let launch: Launch | undefined
let version: string | undefined
let settings: Setting[] | undefined
// The porcelain text `settings` was parsed from: an identical answer redraws
// nothing.
let answered: string | undefined
let mods: ModRow[] | undefined
let settingsProblem: string | undefined
let modsProblem: string | undefined
let selected: RowId | undefined
let filter = ''
let pending = new Map<RowId, Pending>()
let reading = false
let readAgain = false
// What the pane asks in place, and the file the scope line names; both close
// with the pane.
let chooser: Chooser | undefined
let scope: Scope = 'session'
let isOpen = false
let registered = false
// Where the focus ring is, for ringBack: `drawn` is the last drawing's keys in
// ring order; `ring` the key the ring was last put on and its place then,
// undefined while the pane does not hold the keys.
let drawn: readonly string[] = []
let ring: { key: string; at: number } | undefined
// The last drawing's room, so a window move reads the drawing the state makes
// now, even before the engine draws it.
type Room = Pick<PanelView, 'columns' | 'bodyRows' | 'hasField'>
let room: Room | undefined

export function register(on: On) {
  launch = undefined; version = undefined; settings = undefined; answered = undefined; mods = undefined; settingsProblem = undefined; modsProblem = undefined
  selected = undefined; filter = ''; pending = new Map(); reading = false; readAgain = false; chooser = undefined; scope = 'session'; isOpen = false; registered = false
  drawn = []; ring = undefined; room = undefined

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
    // The mobile app's element table holds an Input at run time, but the app draws none.
    room = { columns: e.props.bodyColumns, bodyRows: e.props.scroll.bodyRows, hasField: e.surface !== 'mobile' }
    const view = viewIn(room)
    const next = ringOf(view)
    drawn = next.keys
    if (!e.props.isFocused) ring = undefined
    const back = ring && ringBack(ring, next)
    if (back !== undefined) $.clock.after(0, () => inBackground($, refocus($, back)))
    return drawPane(view, $.ui.resolve(e), handlers($))
  })

  // Selection follows the focus ring: Tab or an arrow landing on a row selects
  // it, so the card names that row before Enter, and one landing on the open
  // chooser's element marks it the chooser's. The ring moves first; a ring
  // moved to the field keeps the selection. Every move, the mod's own
  // included, records where the ring now is.
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
    const moved = await next(e)
    if (moved.deny !== undefined) return moved
    ring = e.element === undefined ? undefined : { key: e.element, at: drawn.indexOf(e.element) }
    if (e.element !== undefined && isRowId(e.element) && lineOf(e.element) !== undefined) select($, e.element)
    const at = e.element === undefined ? -1 : chooserKeys().indexOf(e.element)
    if (chooser?.kind === 'row' && at >= 0 && at !== chooser.at) { chooser = { ...chooser, at }; $.ui.invalidate('ui.render') }
    return moved
  })

  // An arrow, the wheel or a page key moves the ring `e.by` of the open
  // chooser's elements, held to its ends; with none open, the selection `e.by`
  // of the rows the filter shows (the pane windows its own), Up from the first
  // to the field. The ring at no place (-1) has the next drawing put it there.
  // None arrives while the ring is on a picker: its arrows move its own highlight.
  on('ui.scroll', { requestId: PANE }, async ($, e, next) => {
    const keys = chooserKeys()
    if (chooser?.kind === 'row' && keys.length > 0) {
      const at = Math.min(keys.length - 1, Math.max(0, chooser.at + e.by))
      const key = keys[at]
      if (at !== chooser.at && key !== undefined) { chooser = { ...chooser, at }; ring = { key, at: -1 }; $.ui.invalidate('ui.render') }
      return {}
    }
    const ids = shownIds()
    if (ids.length === 0) return next(e)
    const at = selected === undefined ? 0 : Math.max(0, ids.indexOf(selected))
    if (at === 0 && e.by < 0 && drawn.includes(FILTER)) { inBackground($, refocus($, FILTER)); return {} }
    const id = ids[Math.min(ids.length - 1, Math.max(0, at + e.by))]
    if (id !== undefined && id !== ids[at]) { ring = { key: id, at: -1 }; select($, id) }
    return {}
  })

  // Closing the pane (Esc, its mark, a plugin) stops its reads and forgets the
  // ring, the filter, what the pane asks in place and the scope line's file,
  // which close with it; a close another hook refused leaves them. Rows stay,
  // so a reopen draws the last answer at once and the first read replaces it.
  on('ui.close', { id: PANE }, async ($, e, next) => {
    const closed = await next(e)
    if (closed.deny === undefined) { isOpen = false; ring = undefined; filter = ''; chooser = undefined; scope = 'session' }
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
    await readVersion($)
    await refresh($)
    return { text: opened.isPlaced ? REPLIES.opened : REPLIES.notPlaced(opened.reason) }
  } catch (err) {
    return { text: REPLIES.failed(message(err)) }
  }
}

// CS_BIN, CLAUDE_SESSION_NAME and CS_UPDATE_AVAILABLE; undefined without
// CS_BIN. A name cs would not give a session counts as no session name.
async function readLaunch($: EngineInterface): Promise<Launch | undefined> {
  const bin = await $.env.get('CS_BIN')
  if (!bin) return undefined
  const name = await $.env.get('CLAUDE_SESSION_NAME')
  return { bin, self: name !== undefined && SESSION_NAME.test(name) ? name : undefined, update: (await $.env.get('CS_UPDATE_AVAILABLE')) || undefined }
}

// cs's version, once a load at the first open (a reload after an update
// installed from this conversation reads the new one): `cs -version` prints
// `cs <version>`. Any other answer leaves it unread and says why in the
// transcript; the next open asks again.
async function readVersion($: EngineInterface): Promise<void> {
  if (version !== undefined) return
  const run = await runCs($, ['-version'], { timeoutMs: LIST_TIMEOUT_MS })
  version = run.ok ? /^cs (\S+)$/.exec(run.stdout.trim())?.[1] : undefined
  if (version !== undefined) $.ui.invalidate('ui.render')
  else $.ui.log(LOGS.noVersion(run.ok ? `printed ${run.stdout.trim() || 'nothing'}` : run.why))
}

// Reads again for a pane that outlived a reload, once $.ui.panes shows it open.
async function resume($: EngineInterface): Promise<void> {
  launch ??= await readLaunch($)
  if (isOpen || launch === undefined) return
  if (!(await $.ui.panes()).some(p => p.id === PANE) || isOpen) return
  isOpen = true
  await readVersion($)
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
  return linesOf(mods ?? [], settings ?? [], pending, WORDS.modsGroup)
}

// The view the state draws in `r`.
function viewIn(r: Room): PanelView {
  return { lines: currentLines(), selected, problems: problems(), session: launch?.self, version, update: launch?.update, ...r, filter, chooser, scope }
}

// The open chooser's elements in ring order as the state draws them now; none
// before the first drawing or while no chooser is drawn.
function chooserKeys(): string[] {
  return room === undefined ? [] : ringOf(viewIn(room)).keys.filter(isChooserKey)
}

// The rows the filter shows, top to bottom.
function shownIds(): RowId[] {
  return filterLines(currentLines() ?? [], filter).flatMap(l => l.kind === 'row' ? [l.row.id] : [])
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

// A row's chooser draws under the selected row, so selecting another closes it.
function select($: EngineInterface, id: RowId): void {
  if (id === selected) return
  selected = id
  if (chooser?.kind === 'row') chooser = undefined
  $.ui.invalidate('ui.render')
}

// The ring sent by the next drawing to `key`, and what the pane asks in place.
function ask($: EngineInterface, next: Chooser | undefined, key: string | undefined): void {
  chooser = next
  if (key !== undefined) ring = { key, at: -1 }
  $.ui.invalidate('ui.render')
}

function handlers($: EngineInterface): Handlers {
  return {
    change: id => inBackground($, change($, id, { kind: 'row' })),
    pick: (id, key) => inBackground($, change($, id, { kind: 'choice', key })),
    // Kept so a redraw before Enter keeps what was typed; the field shows it already.
    type: text => { if (chooser?.kind === 'row') chooser = { ...chooser, text } },
    submit: (id, text) => inBackground($, change($, id, { kind: 'field', text })),
    filter: text => { if (text !== filter) { filter = text; if (chooser?.kind === 'row') chooser = undefined; $.ui.invalidate('ui.render') } },
    toRows: () => { const first = shownIds()[0]; if (first !== undefined) { select($, first); inBackground($, refocus($, first)) } },
    reset: () => askReset($),
    confirm: () => inBackground($, resetSettings($)),
    keep: () => ask($, undefined, RESET),
    scope: next => { if (next !== scope) { scope = next; $.ui.invalidate('ui.render') } },
  }
}

// Enter on a row, Enter on one of its chooser's choices or a pick in its
// picker, or Enter in its chooser's field.
type Entry = { kind: 'row' } | { kind: 'choice'; key: string } | { kind: 'field'; text: string }

// What an entry asks of the row's change as it stands: its chooser opened, an
// answer, or nothing it offers now (a drawing older than the last read). A
// picker's values are choices too, as Buttons where the surface draws no picker.
function answerOf(change: Change, entry: Entry): Answer | 'choose' | undefined {
  if (entry.kind === 'row') return change.kind === 'now' ? change.answer : 'choose'
  if (change.kind === 'now') return undefined
  const { control } = change
  switch (entry.kind) {
    case 'choice': return [...(control?.kind === 'picker' ? control.options : []), ...change.choices].find(c => optionKey(c.label) === entry.key)?.answer
    case 'field': return control?.kind === 'field' ? control.read(entry.text) : undefined
  }
}

// An entry on a row. It is refused with a toast when the row, looked up afresh,
// waits on a write or is gone, or a choice comes from a chooser no longer open
// on it (a drawing older than the last read or the row's claim), and says why
// when nothing changes the row. Enter opens the row's chooser with the ring on
// its first element, or makes its one change at once; a choice closes the
// chooser and makes its own. A write claims the row before its first await,
// so a second Enter finds it waiting; whatever happens, it is released and
// both sources are read again.
async function change($: EngineInterface, id: RowId, entry: Entry): Promise<void> {
  const line = lineOf(id)
  const isOffered = entry.kind === 'row' || (chooser?.kind === 'row' && chooser.id === id)
  if (line === undefined || line.pending !== undefined || !isOffered) { $.ui.toast(TOASTS.notNow(id.slice(id.indexOf(':') + 1))); return }
  const hasSelf = launch?.self !== undefined
  if (lockOf(line.row, hasSelf) !== undefined) { $.ui.toast(TOASTS.readOnly(labelOf(line.row), noteOf(line.row, hasSelf))); return }
  select($, id)
  const plan = changeOf(line.row, writesTo(scope, hasSelf))
  const answer = answerOf(plan, entry)
  if (answer === 'choose') {
    // Set first, so the keys read are the ones it draws.
    chooser = { kind: 'row', id, text: plan.kind === 'choose' && plan.control?.kind === 'field' ? plan.control.value : '', at: 0 }
    ask($, chooser, chooserKeys()[0])
    return
  }
  ask($, undefined, undefined)
  if (answer === undefined) { $.ui.toast(TOASTS.notNow(id.slice(id.indexOf(':') + 1))); return }
  switch (answer.kind) {
    case 'keep': return
    case 'notNumber': $.ui.toast(TOASTS.notNumber(answer.label, answer.text)); return
  }
  pending.set(id, 'writing')
  $.ui.invalidate('ui.render')
  try {
    // A switch, not a table of functions: the engine refuses `$` handed to a
    // callee it cannot name.
    switch (answer.kind) {
      case 'write': await changeSetting($, answer); break
      case 'set': await changeMod($, answer); break
    }
  } finally {
    pending.delete(id)
    $.ui.invalidate('ui.render')
    await refresh($)
  }
}

// One cs write. cs's reply is the toast, so the panel keeps no copy of cs's
// checks.
async function changeSetting($: EngineInterface, write: Extract<Answer, { kind: 'write' }>): Promise<void> {
  const run = await runCs($, writeArgv(write.scope, launch?.self, write.key, write.value), { timeoutMs: WRITE_TIMEOUT_MS })
  $.ui.toast(run.ok ? TOASTS.written(lastLine(run.stdout)) : TOASTS.refused(write.key, run.why))
}

// $.config.set: the owner's guard runs (cs's own for cs.*), since this is
// another plugin's set, and its deny is the toast. The owner reloads with the
// new value.
async function changeMod($: EngineInterface, set: Extract<Answer, { kind: 'set' }>): Promise<void> {
  const result = await $.config.set({ key: set.key, value: set.value })
  $.ui.toast(result.deny === undefined ? TOASTS.modSaved(set.key, shownOf(result.value), set.plugin) : TOASTS.refused(set.key, result.deny))
}

// Enter on the reset control: its confirmation in the keys' line, the ring
// sent to confirm. Its counts are cs's list's, so before the first list it
// says so and asks nothing.
function askReset($: EngineInterface): void {
  if (settings === undefined) { $.ui.toast(TOASTS.notRead); return }
  ask($, { kind: 'reset' }, CONFIRM)
}

// Enter on confirm: the keys' line back, then one cs run that removes every
// setting from the file the scope line names. cs's reply is the toast, and
// both sources are read again. A confirm from a drawing older than the last
// one runs again: cs answers a reset of an emptied file with nothing to reset.
async function resetSettings($: EngineInterface): Promise<void> {
  ask($, undefined, RESET)
  const run = await runCs($, resetArgv(writesTo(scope, launch?.self !== undefined), launch?.self), { timeoutMs: WRITE_TIMEOUT_MS })
  $.ui.toast(run.ok ? TOASTS.written(lastLine(run.stdout)) : TOASTS.notReset(run.why))
  await refresh($)
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
