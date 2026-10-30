// ABOUTME: What the cs-panel rows are: `cs -config list --porcelain` parsed into settings, the /config rows cs's mods own, the grouped lines and what each row offers.
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
// a shell).
export type Edit = 'flag' | 'choice' | 'text' | 'shell'

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
}

// The line that refused the answer; '' when the answer held no line at all.
export type Unreadable = { unreadable: string }

const KEY = /^CS_[A-Z0-9_]+$/
const EDITS: readonly string[] = ['flag', 'choice', 'text', 'shell'] satisfies readonly Edit[]
const SOURCES: readonly string[] = ['shell', 'launch', 'session', 'machine', 'default'] satisfies readonly Source[]
// The porcelain's word for none.
const NONE = '-'

const noneOf = (field: string): string | undefined => field === NONE ? undefined : field

// Parse, not validate: eleven tab fields per line (key group label edit
// choices default when whenText value source ignored), or the whole answer is
// refused with its first bad line, so a strict reader never draws shifted
// columns. A closed word (edit, source) outside its set refuses too: a cs
// change the panel does not know is a drawn problem, not a wrong row.
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
  if (f.length !== 11) return undefined
  const [key, group, label, edit, choices, fallback, when, whenText, value, source, ignored] = f as [string, string, string, string, string, string, string, string, string, string, string]
  if (!KEY.test(key) || !EDITS.includes(edit) || !SOURCES.includes(source)) return undefined
  if ([group, label, when, whenText].some(field => field === '' || field === NONE)) return undefined
  if ((edit === 'choice') !== (choices !== NONE)) return undefined
  if (edit === 'flag' && value !== '1' && value !== NONE) return undefined
  return {
    key: key as SettingKey, group, label, edit: edit as Edit, choices: choices === NONE ? [] : choices.split(','), fallback: noneOf(fallback),
    when, whenText, value: noneOf(value), source: source as Source, ignored: noneOf(ignored),
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
}

// The plugins whose /config rows the pane lists, by name: a cs-* plugin that
// is not one of them is not cs's to show.
const MOD_PROVIDERS: ReadonlySet<string> = new Set(['cs', 'cs-update', 'cs-mermaid'])

export function isModProvider(plugin: string): boolean {
  return MOD_PROVIDERS.has(plugin)
}

export function modRowsOf(rows: readonly ConfigRow[]): ModRow[] {
  return rows.filter(r => isModProvider(r.provider.plugin)).map(r => ({
    key: r.key, plugin: r.provider.plugin, label: r.label, kind: r.kind, value: r.value, options: r.options ?? [], isLocked: r.isLocked,
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

// What a row offers, in strip order; draw.tsx's KEYS is keyed by it and `act`
// checks a press against it.
//   change  : every row but a locked mod row, a shell-pinned setting and an
//             `edit: shell` setting; also the row's own press.
//   unset   : a setting a file sets: remove it there, so the next layer or the
//             default applies. A /config row has none: the panel cannot see a
//             userConfig default.
//   session : a changeable setting, when this conversation runs under a cs
//             session name: the change goes to that session's file only.
// A setting this session's file sets is written there, so with no session
// name it offers nothing.
export type Action = 'change' | 'unset' | 'session'

export function actionsOf(row: Row, hasSelf: boolean): Action[] {
  if (row.kind === 'mod') return row.mod.isLocked ? [] : ['change']
  const s = row.setting
  if (s.edit === 'shell' || s.source === 'shell') return []
  if (s.source === 'session' && !hasSelf) return []
  const actions: Action[] = ['change']
  if (s.source === 'session' || s.source === 'machine') actions.push('unset')
  if (hasSelf) actions.push('session')
  return actions
}

// What a row waits on after a press; while set it offers nothing, so a second
// press cannot start a second write.
export type Pending = 'asking' | 'writing'

// The pane's lines, top to bottom: the `Mods` heading and its rows, then each
// cs group in cs's order under its heading. A heading is text, not a Button,
// so the focus ring walks rows only.
export type Line =
  | { kind: 'mods' }
  | { kind: 'group'; title: string }
  | { kind: 'row'; row: Row; actions: readonly Action[]; pending: Pending | undefined }

export function linesOf(mods: readonly ModRow[], settings: readonly Setting[], pending: ReadonlyMap<RowId, Pending>, hasSelf: boolean): Line[] {
  const lineOf = (row: Row): Line => {
    const waiting = pending.get(row.id)
    return { kind: 'row', row, actions: waiting === undefined ? actionsOf(row, hasSelf) : [], pending: waiting }
  }
  const lines: Line[] = mods.length === 0 ? [] : [{ kind: 'mods' }]
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

// Where a write lands.
export type Scope = 'machine' | 'session'

// change and unset: where the value lives (a session value in the session,
// anything else on the machine), so a change always moves what the row shows.
// session: the session.
export function scopeFor(setting: Setting, action: Action): Scope {
  return action === 'session' || setting.source === 'session' ? 'session' : 'machine'
}

// The option labels a change asks with; free text under Other is the value.
export const LABELS = {
  keep: (value: string) => `Keep ${value}`,
  fallback: (fallback: string | undefined) => fallback === undefined ? 'Default' : `Default (${fallback})`,
  cancel: 'Cancel',
} as const

// A change that asks first: the labels, the values the question names (a
// choice with more values than labels), and what an answer means. `$.ui.ask`
// takes 2-4 labels and pads fewer with Yes/No, so every plan has two or more.
export type Ask<A> = { kind: 'ask'; options: readonly string[]; values: readonly string[]; read: (answer: string) => A }

// Leave it, put it back to its default (unset where it lives), or this value;
// cs's checker judges a typed one, and its refusal is the toast.
export type SettingAnswer = { kind: 'keep' } | { kind: 'default' } | { kind: 'value'; value: string }

// A setting:
//   flag         -> at once: '0' when on, '1' when off
//   choice <= 3  -> ask: the choices and Default
//   choice 4     -> ask: the four choices (u is the default)
//   choice > 4   -> ask: the first three and Default; the question names
//                   every value, the rest typed under Other
//   text         -> ask: Keep <value> and Default; Other is the value
export function settingChange(s: Setting): { kind: 'now'; value: string } | Ask<SettingAnswer> {
  switch (s.edit) {
    case 'flag':
      return { kind: 'now', value: s.value === '1' ? '0' : '1' }
    case 'choice': {
      const fallback = LABELS.fallback(s.fallback)
      const options = s.choices.length === 4 ? s.choices : [...s.choices.slice(0, 3), fallback]
      return { kind: 'ask', options, values: s.choices.length > 4 ? s.choices : [], read: answer => answer === fallback ? { kind: 'default' } : { kind: 'value', value: answer } }
    }
    case 'text': {
      const keep = LABELS.keep(s.value ?? s.fallback ?? NONE)
      const fallback = LABELS.fallback(s.fallback)
      return { kind: 'ask', options: [keep, fallback], values: [], read: answer => answer === keep ? { kind: 'keep' } : answer === fallback ? { kind: 'default' } : { kind: 'value', value: answer } }
    }
    case 'shell':
      throw new Error(`settingChange: ${s.key} is changed from a shell, and the panel offers no change for it`)
  }
}

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
    answer === LABELS.keep(shown) || answer === LABELS.cancel ? { kind: 'keep' } : other(answer)
  switch (m.kind) {
    case 'boolean':
      return { kind: 'now', value: m.value !== true }
    case 'choice': {
      const options = m.options.length < 2 ? [...m.options, LABELS.cancel] : m.options.slice(0, 4)
      return { kind: 'ask', options, values: m.options.length > 4 ? m.options : [], read: answer => answer === LABELS.cancel ? { kind: 'keep' } : { kind: 'value', value: answer } }
    }
    case 'number':
      return { kind: 'ask', options: [LABELS.keep(shown), LABELS.cancel], values: [], read: keepOr(answer => {
        const typed = answer.trim()
        const value = Number(typed)
        return typed !== '' && Number.isFinite(value) ? { kind: 'value', value } : { kind: 'notNumber', answer }
      }) }
    case 'text':
      return { kind: 'ask', options: [LABELS.keep(shown), LABELS.cancel], values: [], read: keepOr(answer => ({ kind: 'value', value: answer })) }
  }
}

// A /config value as the pane and its toasts show it.
export function shownOf(value: ConfigValue): string {
  return typeof value === 'string' ? value : Array.isArray(value) ? value.join(',') : String(value)
}

// The argv of one write, for runCs. `self` is the session name cs launched
// this conversation under, which the session scope needs; actionsOf offers a
// session write only with one.
//   machine : -config set <key> <value> | -config unset <key>
//   session : <self> -config set <key> <value> | <self> -config unset <key>
export function writeArgv(scope: Scope, self: string | undefined, key: SettingKey, value: string | undefined): string[] {
  const verb = value === undefined ? ['-config', 'unset', key] : ['-config', 'set', key, value]
  if (scope === 'machine') return verb
  if (self === undefined) throw new Error(`writeArgv: ${key} is to be written to this session's file, but cs named no session for this conversation`)
  return [self, ...verb]
}
