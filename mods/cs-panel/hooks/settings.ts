// ABOUTME: What the cs-panel rows are: `cs -config list --porcelain` parsed into settings, the /config rows cs's mods own, the grouped lines, the filter, and what Enter on each row offers.
// ABOUTME: Pure: what a change offers and where it writes are decided here; register.tsx runs them.
import type { ConfigKind, ConfigRow, ConfigValue } from 'claude-code'

// A cs setting's name. Only parseSettings makes one, from a field that matched
// KEY, so it is ASCII: one character, one cell. It is the argv cs takes; the
// panel reads no CS_* variable itself.
export type SettingKey = string & { readonly __settingKey: unique symbol }

// Where the value readers see comes from, as cs's loader decided it:
//   shell   : the environment pins it, so no file change shows: read-only here
//   launch  : the launch measured it (the theme and background only)
//   session : this session's .cs/local/config
//   machine : ~/.config/cs/config
//   default : nothing sets it; the reader's own default applies
export type Source = 'shell' | 'launch' | 'session' | 'machine' | 'default'

// What a row offers: a toggle, a pick, a typed value, or nothing (changed from
// a shell). The `off` forms are flags whose 1 turns off what the label names:
// `Scope grounding` is on while CS_SCOPE_DISABLE is unset.
export type Edit = 'flag' | 'flagoff' | 'choice' | 'text' | 'shell' | 'shelloff'

export const turnsOff = (edit: Edit): boolean => edit === 'flagoff' || edit === 'shelloff'

// One record of the porcelain. Unknown is undefined.
export type Setting = {
  key: SettingKey
  group: string
  label: string
  edit: Edit
  // The values a choice takes, in cs's order; [] for any other edit.
  choices: readonly string[]
  // How cs names the default for display (`40`, `quiet`, `measured`).
  fallback: string | undefined
  // The short word for the row (`now`, `/clear`, `launch`, `now+launch`) and
  // the sentence for the detail line, both cs's, drawn as they are.
  when: string
  whenText: string
  // What readers see now; a flag reads `1` or undefined.
  value: string | undefined
  source: Source
  // A file value cs skipped that would otherwise apply, with its line and why.
  ignored: string | undefined
  // cs's sentence for what the setting does.
  describe: string
}

// The line that refused the answer; '' when the answer held no line at all.
export type Unreadable = { unreadable: string }

const KEY = /^CS_[A-Z0-9_]+$/
const EDITS: readonly string[] = ['flag', 'flagoff', 'choice', 'text', 'shell', 'shelloff'] satisfies readonly Edit[]
const SOURCES: readonly string[] = ['shell', 'launch', 'session', 'machine', 'default'] satisfies readonly Source[]
// The porcelain's word for none.
const NONE = '-'

const noneOf = (field: string): string | undefined => field === NONE ? undefined : field

// Parse, not validate: twelve tab fields per line (key group label edit
// choices default when whenText value source ignored describe), or the whole
// answer is refused with its first bad line, so a strict reader never draws
// shifted columns. A closed word (edit, source) outside its set refuses too: a
// cs change the panel does not know is a drawn problem, not a wrong row.
// tests/fixtures/config-porcelain.txt pins the wire.
export function parseSettings(stdout: string): Setting[] | Unreadable {
  const lines = stdout.split('\n').filter(line => line !== '')
  if (lines.length === 0) return { unreadable: '' }
  const settings: Setting[] = []
  for (const line of lines) {
    const setting = settingOf(line)
    if (setting === undefined) return { unreadable: line }
    settings.push(setting)
  }
  return settings
}

function settingOf(line: string): Setting | undefined {
  const f = line.split('\t')
  if (f.length !== 12) return undefined
  const [key, group, label, edit, choices, fallback, when, whenText, value, source, ignored, describe] = f as [string, string, string, string, string, string, string, string, string, string, string, string]
  if (!KEY.test(key) || !EDITS.includes(edit) || !SOURCES.includes(source)) return undefined
  if ([group, label, when, whenText, describe].some(field => field === '' || field === NONE)) return undefined
  if ((edit === 'choice') !== (choices !== NONE)) return undefined
  return {
    key: key as SettingKey, group, label, edit: edit as Edit, choices: choices === NONE ? [] : choices.split(','), fallback: noneOf(fallback),
    when, whenText, value: noneOf(value), source: source as Source, ignored: noneOf(ignored), describe,
  }
}

// A /config row one of cs's mods owns, as the panel needs it; the engine's
// ConfigRow stays behind modRowsOf.
export type ModRow = {
  // `<plugin>.<field>`, what $.config.set takes.
  key: string
  plugin: string
  label: string
  kind: ConfigKind
  value: ConfigValue
  // A choice's declared options; [] otherwise.
  options: readonly string[]
  isLocked: boolean
  // What the row does, as its plugin declares it; '' when it declares nothing.
  description: string
}

// The plugins whose /config rows the pane lists, by name: a cs-* plugin that
// is not one of them is not cs's to show.
const MOD_PROVIDERS: ReadonlySet<string> = new Set(['cs', 'cs-update', 'cs-mermaid'])

export function isModProvider(plugin: string): boolean {
  return MOD_PROVIDERS.has(plugin)
}

// The mods title their rows `cs: <label>` so /config marks them as cs's; under
// the pane's own Mods heading the mark says nothing, so it comes off.
const MOD_LABEL_MARK = 'cs: '

export function modRowsOf(rows: readonly ConfigRow[]): ModRow[] {
  return rows.filter(r => isModProvider(r.provider.plugin)).map(r => ({
    key: r.key, plugin: r.provider.plugin, label: r.label.startsWith(MOD_LABEL_MARK) ? r.label.slice(MOD_LABEL_MARK.length) : r.label,
    kind: r.kind, value: r.value, options: r.options ?? [], isLocked: r.isLocked, description: r.description ?? '',
  }))
}

// A row's id: its Button key and the selection. `mod:` and `cs:` keep the two
// namespaces apart.
export type RowId = `mod:${string}` | `cs:${string}`

export function isRowId(text: string): text is RowId {
  return text.startsWith('mod:') || text.startsWith('cs:')
}

export type Row =
  | { kind: 'mod'; id: RowId; mod: ModRow }
  | { kind: 'setting'; id: RowId; setting: Setting }

export const labelOf = (row: Row): string => row.kind === 'mod' ? row.mod.label : row.setting.label
export const keyOf = (row: Row): string => row.kind === 'mod' ? row.mod.key : row.setting.key

// Why Enter on a row changes nothing: the shell pins the value, it changes
// from a shell only, a managed setting owns the /config row, or this session's
// file sets it and no session name writes that file. Undefined: it changes it.
export type Lock = 'pinned' | 'shellOnly' | 'managed' | 'noSession'

export function lockOf(row: Row, hasSelf: boolean): Lock | undefined {
  if (row.kind === 'mod') return row.mod.isLocked ? 'managed' : undefined
  const s = row.setting
  if (s.source === 'shell') return 'pinned'
  if (s.edit === 'shell' || s.edit === 'shelloff') return 'shellOnly'
  return s.source === 'session' && !hasSelf ? 'noSession' : undefined
}

// What a row waits on: a write cs or /config has not answered yet. While it is
// set another Enter on the row is refused, so it cannot start a second write.
export type Pending = 'writing'

// The pane's lines, top to bottom: the mods' group and its rows, then each cs
// group in cs's order under its heading. A heading is text, not a Button, so
// the focus ring walks rows only.
export type Line =
  | { kind: 'group'; title: string }
  | { kind: 'row'; row: Row; pending: Pending | undefined }

export function linesOf(mods: readonly ModRow[], settings: readonly Setting[], pending: ReadonlyMap<RowId, Pending>, modsGroup: string): Line[] {
  const lineOf = (row: Row): Line => ({ kind: 'row', row, pending: pending.get(row.id) })
  const lines: Line[] = mods.length === 0 ? [] : [{ kind: 'group', title: modsGroup }]
  for (const mod of mods) lines.push(lineOf({ kind: 'mod', id: `mod:${mod.key}`, mod }))
  let group: string | undefined
  for (const setting of settings) {
    if (setting.group !== group) {
      group = setting.group
      lines.push({ kind: 'group', title: group })
    }
    lines.push(lineOf({ kind: 'setting', id: `cs:${setting.key}`, setting }))
  }
  return lines
}

// The rows whose label, key or group holds `text` (trimmed, any case), each
// under its group; a group left with no row goes. An empty text keeps all.
export function filterLines(lines: readonly Line[], text: string): Line[] {
  const needle = text.trim().toLowerCase()
  let group = ''
  const kept = lines.filter(l => {
    if (l.kind === 'group') { group = l.title; return true }
    return [labelOf(l.row), keyOf(l.row), group].some(field => field.toLowerCase().includes(needle))
  })
  return kept.filter((l, i) => l.kind === 'row' || kept[i + 1]?.kind === 'row')
}

// Where a write lands.
export type Scope = 'machine' | 'session'

// The file a write the scope line decides goes to: the scope line's under a
// session name, this machine's without one.
export const writesTo = (scope: Scope, hasSelf: boolean): Scope => hasSelf ? scope : 'machine'

const stateOf = (on: boolean) => on ? 'on' : 'off'

// The labels of a chooser's choices.
export const LABELS = {
  turn: (on: boolean) => on ? 'Turn on' : 'Turn off',
  keep: 'Keep',
  keepValue: (value: string) => `Keep ${value}`,
  fallback: (fallback: string | undefined) => fallback === undefined ? 'Default' : `Default (${fallback})`,
} as const

// What a choice does: leave the row; have cs write a setting's value to a file
// (undefined unsets it there); set a /config row through its owner's
// config.set guard; or refuse a text a number row cannot read, unwritten.
export type Answer =
  | { kind: 'keep' }
  | { kind: 'write'; scope: Scope; key: SettingKey; value: string | undefined }
  | { kind: 'set'; key: string; plugin: string; value: ConfigValue }
  | { kind: 'notNumber'; label: string; text: string }

const KEEP: Answer = { kind: 'keep' }

// One choice of a chooser: its label, and what picking it does.
export type Choice = { label: string; answer: Answer }

// A chooser's field for a typed value: the text it opens with, what it shows
// while empty, and what Enter with a text does.
export type Field = { value: string; placeholder: string | undefined; read: (text: string) => Answer }

// What Enter on a row does: one change at once, or a chooser opened under the
// row, a field first where the row takes a typed value, then its choices, the
// last one Keep.
export type Change = { kind: 'now'; answer: Answer } | { kind: 'choose'; field: Field | undefined; choices: readonly Choice[] }

// A setting's change. A value this session's file holds changes there; any
// other goes to `target`, the file writesTo names, so a change always moves
// what the row shows. Default, an unset in the file that holds the value, is
// offered while a file holds it (a typed setting always), Keep always, the
// current value never. An off flag's labels name its feature: Turn off writes
// 1, and its default, the flag unset, is on.
//   flag   -> no file holding it: the flip at once; else Turn on|off, Default, Keep
//   choice -> the other choices, Default, Keep
//   text   -> a field holding the value, whose text cs's checker judges, then
//             Default, Keep <value>
export function settingChange(s: Setting, target: Scope): Change {
  if (s.edit === 'shell' || s.edit === 'shelloff') throw new Error(`settingChange: ${s.key} is changed from a shell, and the panel offers no change for it`)
  const home: Scope = s.source === 'session' ? 'session' : 'machine'
  const to: Scope = home === 'session' ? 'session' : target
  const write = (value: string | undefined, scope = to): Answer => ({ kind: 'write', scope, key: s.key, value })
  const isFlag = s.edit === 'flag' || s.edit === 'flagoff'
  const isHeld = s.source === 'session' || s.source === 'machine'
  const fallback: Choice[] = isHeld || s.edit === 'text' ? [{ label: LABELS.fallback(isFlag ? stateOf(turnsOff(s.edit)) : s.fallback), answer: write(undefined, home) }] : []
  const keep: Choice = { label: s.edit === 'text' ? LABELS.keepValue(s.value ?? s.fallback ?? NONE) : LABELS.keep, answer: KEEP }
  switch (s.edit) {
    case 'flag':
    case 'flagoff': {
      // The feature is on at 1, or for an off flag at anything but 1.
      const isOn = (s.value === '1') !== turnsOff(s.edit), value = isOn === turnsOff(s.edit) ? '1' : '0'
      if (!isHeld) return { kind: 'now', answer: write(value) }
      return { kind: 'choose', field: undefined, choices: [{ label: LABELS.turn(!isOn), answer: write(value) }, ...fallback, keep] }
    }
    case 'choice':
      return { kind: 'choose', field: undefined, choices: [...s.choices.filter(choice => choice !== (s.value ?? s.fallback)).map(choice => ({ label: choice, answer: write(choice) })), ...fallback, keep] }
    case 'text':
      return { kind: 'choose', field: { value: s.value ?? '', placeholder: s.fallback, read: text => write(text) }, choices: [...fallback, keep] }
  }
}

// A /config row's change; the owner's config.set guard judges a value, and
// its deny is the toast:
//   boolean -> at once: the negation
//   choice  -> its other options, Keep
//   number  -> a field holding the value, Keep <value>; a text that reads as
//              no number is refused unwritten
//   text    -> a field holding the value, Keep <value>
export function modChange(m: ModRow): Change {
  const shown = shownOf(m.value)
  const set = (value: ConfigValue): Answer => ({ kind: 'set', key: m.key, plugin: m.plugin, value })
  const keep: Choice = { label: LABELS.keepValue(shown), answer: KEEP }
  switch (m.kind) {
    case 'boolean':
      return { kind: 'now', answer: set(m.value !== true) }
    case 'choice':
      return { kind: 'choose', field: undefined, choices: [...m.options.filter(option => option !== shown).map(option => ({ label: option, answer: set(option) })), { label: LABELS.keep, answer: KEEP }] }
    case 'number':
      return { kind: 'choose', field: { value: shown, placeholder: undefined, read: text => {
        const typed = text.trim()
        const value = Number(typed)
        return typed !== '' && Number.isFinite(value) ? set(value) : { kind: 'notNumber', label: m.label, text }
      } }, choices: [keep] }
    case 'text':
      return { kind: 'choose', field: { value: shown, placeholder: undefined, read: text => set(text) }, choices: [keep] }
  }
}

// A row's change, its setting's written to `target` where it does not stay in
// this session's file.
export const changeOf = (row: Row, target: Scope): Change => row.kind === 'mod' ? modChange(row.mod) : settingChange(row.setting, target)

// Whether Enter changes the row with no chooser: a mod's boolean, and a cs
// flag no file holds.
export const flips = (row: Row, target: Scope): boolean => changeOf(row, target).kind === 'now'

// A /config value as the pane and its toasts show it.
export function shownOf(value: ConfigValue): string {
  return typeof value === 'string' ? value : Array.isArray(value) ? value.join(',') : String(value)
}

// The argv of one write, for runCs. `self` is the session name cs launched
// this conversation under, which the session scope needs; a session write is
// planned only with one.
//   machine : -config set <key> <value> | -config unset <key>
//   session : <self> -config set <key> <value> | <self> -config unset <key>
export function writeArgv(scope: Scope, self: string | undefined, key: SettingKey, value: string | undefined): string[] {
  const verb = value === undefined ? ['-config', 'unset', key] : ['-config', 'set', key, value]
  if (scope === 'machine') return verb
  if (self === undefined) throw new Error(`writeArgv: ${key} is to be written to this session's file, but cs named no session for this conversation`)
  return [self, ...verb]
}

// The argv of a reset, for runCs: cs removes every setting from the file, unasked.
//   machine : -config reset --yes
//   session : <self> -config reset --yes
export function resetArgv(scope: Scope, self: string | undefined): string[] {
  const verb = ['-config', 'reset', '--yes']
  if (scope === 'machine') return verb
  if (self === undefined) throw new Error("resetArgv: this session's file is to be reset, but cs named no session for this conversation")
  return [self, ...verb]
}
