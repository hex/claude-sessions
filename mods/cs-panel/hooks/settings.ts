// ABOUTME: What the cs-panel rows are: `cs -config list --porcelain` parsed into settings, the /config rows cs's mods own, the grouped lines, the filter and each row's dialog.
// ABOUTME: Pure: what a change asks and where it writes are decided here; register.tsx runs them.
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
  // cs's sentence for what the setting does; '' when cs gives none.
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

// Parse, not validate: eleven tab fields per line (key group label edit
// choices default when whenText value source ignored), or twelve with the
// description after them, or the whole answer is refused with its first bad
// line, so a strict reader never draws shifted columns. A closed word (edit,
// source) outside its set refuses too: a cs change the panel does not know is
// a drawn problem, not a wrong row.
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
  if (f.length !== 11 && f.length !== 12) return undefined
  const [key, group, label, edit, choices, fallback, when, whenText, value, source, ignored, describe = NONE] = f as [string, string, string, string, string, string, string, string, string, string, string, string?]
  if (!KEY.test(key) || !EDITS.includes(edit) || !SOURCES.includes(source)) return undefined
  if ([group, label, when, whenText].some(field => field === '' || field === NONE) || describe === '') return undefined
  if ((edit === 'choice') !== (choices !== NONE)) return undefined
  return {
    key: key as SettingKey, group, label, edit: edit as Edit, choices: choices === NONE ? [] : choices.split(','), fallback: noneOf(fallback),
    when, whenText, value: noneOf(value), source: source as Source, ignored: noneOf(ignored), describe: noneOf(describe) ?? '',
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

// Why Enter on a row opens no dialog: the shell pins the value, it changes
// from a shell only, a managed setting owns the /config row, or this session's
// file sets it and no session name writes that file. Undefined: it opens one.
export type Lock = 'pinned' | 'shellOnly' | 'managed' | 'noSession'

export function lockOf(row: Row, hasSelf: boolean): Lock | undefined {
  if (row.kind === 'mod') return row.mod.isLocked ? 'managed' : undefined
  const s = row.setting
  if (s.source === 'shell') return 'pinned'
  if (s.edit === 'shell' || s.edit === 'shelloff') return 'shellOnly'
  return s.source === 'session' && !hasSelf ? 'noSession' : undefined
}

// What a row waits on after Enter; while set, another Enter on it is refused,
// so it cannot start a second write.
export type Pending = 'asking' | 'writing'

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

const stateOf = (on: boolean) => on ? 'on' : 'off'

// The option labels the dialogs ask with; free text under Other is a value.
export const LABELS = {
  turn: (on: boolean) => on ? 'Turn on' : 'Turn off',
  sessionOnly: (on: boolean) => `This session only: ${stateOf(on)}`,
  keep: 'Keep',
  keepValue: (value: string) => `Keep ${value}`,
  fallback: (fallback: string | undefined) => fallback === undefined ? 'Default' : `Default (${fallback})`,
  cancel: 'Cancel',
  machine: 'This machine', session: 'This session only',
} as const

// A dialog: the labels, the values the question names (a choice with more
// values than labels), and what an answer means. `$.ui.ask` takes 2-4 labels
// and pads fewer with Yes/No, so every plan has two to four.
export type Ask<A> = { kind: 'ask'; options: readonly string[]; values: readonly string[]; read: (answer: string) => A }
const MOST_OPTIONS = 4

// Leave it, write `value` (undefined unsets it) to `scope`, or a value whose
// file the Where dialog asks.
export type SettingAnswer = { kind: 'keep' } | { kind: 'write'; scope: Scope; value: string | undefined } | { kind: 'where'; value: string }

// A setting's dialog, and what its question says beside the labels: the file
// an answer writes unless its label names this session (undefined when a value
// asks Where), and for an off flag the value its Turn label writes.
export type SettingAsk = Ask<SettingAnswer> & { writes: Scope | undefined; sets: { label: string; value: string } | undefined }

// A setting's dialog. A change goes where the value lives (this session's file
// when it sets the value, else this machine's), so it moves what the row shows;
// with a session name, a value bound for the machine asks Where first. Default
// (an unset there) is offered when a file holds the value, Keep always, the
// current value never; an answer no label names is a value typed under Other,
// which cs's checker judges. An off flag's labels name its feature: Turn off
// writes 1, and its default, the flag unset, is on.
//   flag   -> Turn on|off, Default, This session only: on|off, Keep
//   choice -> the other choices that fit beside Default and Keep (the question
//             names every value when some do not), Default, Keep
//   text   -> Keep <value> and Default, always: an ask takes two labels
export function settingChange(s: Setting, hasSelf: boolean): SettingAsk {
  if (s.edit === 'shell' || s.edit === 'shelloff') throw new Error(`settingChange: ${s.key} is changed from a shell, and the panel offers no change for it`)
  type Offer = readonly [string, SettingAnswer]
  const home: Scope = s.source === 'session' ? 'session' : 'machine'
  const asksWhere = hasSelf && home === 'machine'
  const typed = (value: string): SettingAnswer => asksWhere ? { kind: 'where', value } : { kind: 'write', scope: home, value }
  const isFlag = s.edit === 'flag' || s.edit === 'flagoff'
  const fallback: Offer[] = s.source === 'session' || s.source === 'machine' || s.edit === 'text'
    ? [[LABELS.fallback(isFlag ? stateOf(turnsOff(s.edit)) : s.fallback), { kind: 'write', scope: home, value: undefined }]] : []
  const keep: Offer = [s.edit === 'text' ? LABELS.keepValue(s.value ?? s.fallback ?? NONE) : LABELS.keep, { kind: 'keep' }]
  let offers: Offer[]
  let values: readonly string[] = []
  let sets: SettingAsk['sets']
  switch (s.edit) {
    case 'flag':
    case 'flagoff': {
      // The feature is on at 1, or for an off flag at anything but 1.
      const isOn = (s.value === '1') !== turnsOff(s.edit), value = isOn === turnsOff(s.edit) ? '1' : '0'
      offers = [[LABELS.turn(!isOn), { kind: 'write', scope: home, value }], ...fallback, ...(asksWhere ? [[LABELS.sessionOnly(!isOn), { kind: 'write', scope: 'session', value }] as const] : []), keep]
      sets = turnsOff(s.edit) ? { label: LABELS.turn(!isOn), value } : undefined
      break
    }
    case 'choice': {
      const others = s.choices.filter(choice => choice !== (s.value ?? s.fallback))
      const room = MOST_OPTIONS - fallback.length - 1
      offers = [...others.slice(0, room).map((choice): Offer => [choice, typed(choice)]), ...fallback, keep]
      values = others.length > room ? s.choices : []
      break
    }
    case 'text':
      offers = [keep, ...fallback]
  }
  return { kind: 'ask', options: offers.map(([label]) => label), values, read: answer => offers.find(([label]) => label === answer)?.[1] ?? typed(answer),
    writes: asksWhere && !isFlag ? undefined : home, sets }
}

// The Where dialog: this machine's file or this session's; an answer that names
// neither writes nothing.
export const WHERE: Ask<Scope | undefined> = { kind: 'ask', options: [LABELS.machine, LABELS.session], values: [],
  read: answer => answer === LABELS.machine ? 'machine' : answer === LABELS.session ? 'session' : undefined }

// Leave it, this value (the owner's config.set guard judges it, and its deny
// is the toast), or an answer a number row cannot take, refused unwritten.
export type ModAnswer = { kind: 'keep' } | { kind: 'value'; value: ConfigValue } | { kind: 'notNumber'; answer: string }

// A mod row:
//   boolean -> at once: the negation
//   choice  -> ask: its options (more than four: the first four, the rest
//              typed under Other; fewer than two: and Cancel)
//   number  -> ask: Keep <value> and Cancel; Other must read as a number
//   text    -> ask: Keep <value> and Cancel; Other is the value
export function modChange(m: ModRow): { kind: 'now'; value: ConfigValue } | Ask<ModAnswer> {
  const shown = shownOf(m.value)
  const keepOr = (other: (answer: string) => ModAnswer) => (answer: string): ModAnswer =>
    answer === LABELS.keepValue(shown) || answer === LABELS.cancel ? { kind: 'keep' } : other(answer)
  switch (m.kind) {
    case 'boolean':
      return { kind: 'now', value: m.value !== true }
    case 'choice': {
      const options = m.options.length < 2 ? [...m.options, LABELS.cancel] : m.options.slice(0, MOST_OPTIONS)
      return { kind: 'ask', options, values: m.options.length > MOST_OPTIONS ? m.options : [], read: answer => answer === LABELS.cancel ? { kind: 'keep' } : { kind: 'value', value: answer } }
    }
    case 'number':
      return { kind: 'ask', options: [LABELS.keepValue(shown), LABELS.cancel], values: [], read: keepOr(answer => {
        const typed = answer.trim()
        const value = Number(typed)
        return typed !== '' && Number.isFinite(value) ? { kind: 'value', value } : { kind: 'notNumber', answer }
      }) }
    case 'text':
      return { kind: 'ask', options: [LABELS.keepValue(shown), LABELS.cancel], values: [], read: keepOr(answer => ({ kind: 'value', value: answer })) }
  }
}

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
