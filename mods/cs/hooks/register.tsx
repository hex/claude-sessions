/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs mod: keys above the prompt: rotate past the threshold, wrap up, /clear once a handoff is armed, or start a queue nothing runs.
// ABOUTME: A turn ending past CS_ROTATE_FORCE_CTX (default 80, off disables) runs /rotate itself, then counts down to the /clear (session colour, amber, crit); session.start writes a heartbeat for doctor.
// ABOUTME: /queue adds a task to the session's walk-away queue through `cs -queue add`, at once even mid-turn; bare, it prints `cs -queue list`. /finish toasts its start and outcome and, while its gate runs, the band carries the elapsed time.
// ABOUTME: The band carries a rail: one tick per prompt on the transcript's live branch (read after each turn), the one being read thick; a press or /cs next|prev|first|last|N scrolls the transcript to that prompt; bare /cs goes on to the cs panel.
import type { On, EngineInterface, PluginOptions, RenderElement, RenderSurface } from 'claude-code'

declare const h: any
declare const Fragment: any

// KEEP IN SYNC with the ctx warn and crit defaults in bin/cs-statusline
// (_seg_ctx): by default the band appears where the status bar turns amber and
// the Stop hook gives its headroom notice. CS_STATUSLINE_CTX_WARN, from the
// process environment or a cs settings file, moves it, as it moves the bar;
// CS_ROTATE_BUTTON_CTX moves the band alone. A value that is not a number is
// ignored.
export const DEFAULT_PERCENT = 40

// The count's colour ramp, in the status bar's inks. KEEP IN SYNC with _sgr in
// bin/cs-statusline (tests/test_mod_rotate.sh pins every value here against
// it): the session palette is Claude Code's /color, the tab colour cs sets;
// amber and crit are the bar's warning and critical inks. Amber pivots on the
// measured background's luminance and falls back to the theme; crit follows
// the theme.
export const SESSION_PALETTE: Record<string, string> = {
  red: '220,38,38', blue: '106,155,204', green: '22,163,74', yellow: '202,138,4',
  purple: '130,125,189', orange: '217,119,87', pink: '196,102,134', cyan: '8,145,178',
}
export const AMBER_LIGHT = '180,83,9'
export const AMBER_DARK = '251,191,36'
export const CRIT_LIGHT = '215,0,21'
export const CRIT_DARK = '255,69,58'
// Seconds left at which the count turns amber, and then crit (below CRIT_AT).
export const AMBER_AT = 10
export const CRIT_AT = 5

// The colour the count wears with `left` seconds to go: the session's own
// colour while there is time (none, so the surrounding ink, when the session
// has no colour in the palette), amber from AMBER_AT, crit under CRIT_AT.
export function countdownColor(left: number, session: string | undefined, bg: string | undefined, theme: string | undefined): string | undefined {
  if (left < CRIT_AT) return `rgb(${theme === 'dark' ? CRIT_DARK : CRIT_LIGHT})`
  if (left <= AMBER_AT) return amberColor(bg, theme)
  return paletteColor(session)
}

// The bar's amber for this terminal: pivoted on the measured background's
// luminance, and on the theme when there is no measurement.
export function amberColor(bg: string | undefined, theme: string | undefined): string {
  const rgb = (bg ?? '').split(';').map(part => (/^\s*\d{1,3}\s*$/.test(part) ? Number(part) : NaN))
  const measured = rgb.length === 3 && rgb.every(v => v <= 255)
  const light = measured ? 2126 * rgb[0] + 7152 * rgb[1] + 722 * rgb[2] >= 1530000 : theme !== 'dark'
  return `rgb(${light ? AMBER_LIGHT : AMBER_DARK})`
}

// A session colour name as an rgb() the engine paints, or undefined for a name
// outside the palette (state hand-edited, or from a newer Claude Code).
export function paletteColor(name: string | undefined): string | undefined {
  const rgb = name === undefined ? undefined : SESSION_PALETTE[name]
  return rgb === undefined ? undefined : `rgb(${rgb})`
}

// Doctor observes the mod RUNNING, not merely installed: under a managed
// machine's policy a mod can load and never run. Written when the plugin loads
// (process start or reload; session.start does not fire on /clear). Path is
// relative to the session's cwd, which under cs is the session directory (or
// its worktree).
export const HEARTBEAT = '.cs/local/cs.heartbeat'
// Written by /wrap's last pass: the conversation it wrapped.
export const WRAPPED = '.cs/local/wrapped'

// The rotate skill's last step writes the handoff's basename here; cs's
// SessionStart hook reads it on the next conversation and starts the handoff's
// next step. While it names a handoff the conversation has nothing left to do
// but /clear, whatever the context reads. An encrypted session keeps the
// marker and its handoffs behind .cs/private (a link into its vault).
export const MARKER = '.cs/local/pending-handoff'
export const HANDOFFS = '.cs/handoffs'
export const PRIVATE_MARKER = '.cs/private/pending-handoff'
export const PRIVATE_HANDOFFS = '.cs/private/handoffs'

// The conversation a forced rotation already ran /rotate for, by id. Written
// BEFORE the run is scheduled: a rotation that fails must not be retried at
// the end of every turn. Module state would not do: it survives a /clear
// (measured; a timer started before one kept firing after it) and is lost
// on a reload of the mod.
export const FORCED = '.cs/local/cs.forced'
// The conversation whose rotate button was pressed, by id, from just before
// the press runs /rotate until the end of the next main-loop turn: cs
// -archive-tasks plan reads it, as it reads FORCED, so the one-key rotation
// does not stop to ask. Emptied at that turn's end, so a /rotate typed later
// in the conversation asks as a manual one does.
export const PRESSED = '.cs/local/cs.pressed'

// Once the forced rotation has armed its handoff, how long the band counts
// down before the mod runs the /clear itself. Pressing the button or sending a
// prompt stops it.
export const GRACE_SECONDS = 20
// The percentage a turn must end past for the mod to rotate on its own. Above
// the 65% nudge, so the ladder stays suggest -> offer -> force, and below where
// Claude Code's own auto-compact lands, so a handoff is written while the
// conversation is still whole.
export const FORCE_DEFAULT = 80
// How long cs may take to say whether it trusts the session's control files
// (`cs -vet-session`, about 0.2 s measured) before the answer counts as a no.
const VET_TIMEOUT_MS = 10000
// How often an idle band asks cs for its features again, and how long one
// answer may take: the readiness walks git and the tree for every feature.
const FEATURES_POLL_MS = 30000
const FEATURES_TIMEOUT_MS = 20000
// How long cs may take to list its settings before the read counts as failed.
const SETTINGS_TIMEOUT_MS = 10000


// The wrap key's question, and the answer that runs /wrap. `$.ui.ask` opens
// the engine's own AskUserQuestion dialog and resolves to the label chosen, or
// to free text typed under Other, so the answer is compared exactly; it rejects
// when the dialog is dismissed and in a `-p` run, where there is nobody to ask.
export const WRAP_QUESTION = 'Run /wrap for this session?'
export const WRAP_YES = 'Yes, wrap up'

// Bare /queue's offer, and the prompt a Start sends when no turn is running.
// `cs -queue start` only arms the queue: the Stop hook hands over each task as
// a turn ends, so an idle session needs one turn to reach that first stop.
export const QUEUE_START = 'Start'
export const QUEUE_COMPACT = 'Compact'
// How much of a task a toast shows: a queued one, or the feature /finish lands.
const TOAST_TASK_CHARS = 60

function cutTask(task: string): string {
  return task.length > TOAST_TASK_CHARS ? `${task.slice(0, TOAST_TASK_CHARS)}…` : task
}

// /finish's progress, as cs records it while `cs <base> -integrate-feature`
// and `-retire-feature` run (_finish_progress_write in lib/30-worktree.sh):
// one record, replaced whole at each step, behind .cs/private in an encrypted
// session and in .cs/local otherwise. pid is the cs process that wrote it.
export const FINISH_RECORD = 'finish-progress.json'
// How often the watch /finish starts reads the record.
export const FINISH_POLL_MS = 1000
export type FinishRecord = {
  id: string
  pid: number
  task: string
  sha: string
  step: string
  gate_started?: number
  result?: string
  reason?: string
}
const FINISH_OUTCOMES = new Set(['landed', 'refused', 'retired'])

// Asked after Start or Compact: how the tasks run, as the word cs -queue start
// takes for each (none runs them in this conversation).
export const QUEUE_MODE_QUESTION = 'How should the queued tasks run?'
export const QUEUE_HERE = 'In this conversation'
export const QUEUE_SUBAGENTS = 'In subagents'
export const QUEUE_WORKFLOWS = 'As workflows'
const QUEUE_MODE_WORDS: Record<string, string[]> = { [QUEUE_HERE]: [], [QUEUE_SUBAGENTS]: ['subagents'], [QUEUE_WORKFLOWS]: ['workflow'] }
export const QUEUE_KICK = 'The cs walk-away queue is started. Reply with one short line saying so, then stop: the cs Stop hook hands you each queued task in turn.'

// Every line the mod hands the engine to draw on a surface of the engine's
// own: its dialogs, toasts, transcript notices, slash command replies and
// slash menu rows, one table per surface, so a design tool outside cs can draw
// each from these words. Claude Code leads each toast, notice and reply with the
// plugin's name, so no line names cs first; one that starts `cs <base>` or
// `cs -queue` names a cs command. An error arrives as the text its site makes
// of it: some keep the `Error: ` that String() gives, some only the message.
export type Ask = { question: string; header: string; options: string[] }
export const ASKS = {
  wrap: { question: WRAP_QUESTION, header: 'Wrap', options: [WRAP_YES, 'Not now'] },
  queueStart: (count: number): Ask => ({ question: `Start the ${count} queued ${count === 1 ? 'task' : 'tasks'} now?`, header: 'Queue', options: [QUEUE_START, 'Not yet', QUEUE_COMPACT] }),
  queueMode: { question: QUEUE_MODE_QUESTION, header: 'Queue', options: [QUEUE_HERE, QUEUE_SUBAGENTS, QUEUE_WORKFLOWS] },
} satisfies Record<string, Ask | ((...args: never[]) => Ask)>

export const TOASTS = {
  queued: (task: string) => `queued: ${cutTask(task)}`,
  bandOption: (problem: string) => `the band draws no prompt bars: ${problem}. Set it in /config.`,
  promptNotDrawn: 'that prompt is not on screen yet',
  scrollRefused: (deny: string) => deny,
  transcriptTail: () => `the transcript is over ${READ_CAP / 1024 / 1024} MiB; the rail lists the prompts of its tail`,
  forceBelowStart: (force: number, startPercent: number) => `CS_ROTATE_FORCE_CTX=${force} is below this conversation's starting context (${startPercent}%); not forcing a rotation`,
  rotateFailed: (err: string) => `/rotate did not run: ${err}`,
  clearFailed: (err: string) => `/clear did not run: ${err}`,
  nextStep: (line: string) => `next step: ${line}`,
  noRotation: (refusal: string) => `no rotation in this session: ${refusal}`,
  feedFailed: (err: string) => `feed update failed: ${err}`,
  finishFailed: (task: string, err: string) => `/finish${task === '' ? '' : ` ${task}`} did not run: ${err}`,
  pressedNotEmptied: (err: string) => `could not empty ${PRESSED}: ${err}`,
  wrapFailed: (err: string) => `/wrap did not run: ${err}`,
  queueNoBin: 'the launch did not say where cs is (CS_BIN); run cs -queue start from a shell in this session',
  queueModeUnknown: (how: string) => `'${how}' is not a way to run the queue; it is not started`,
  notCompacted: (reason: string) => `the conversation was not compacted (${reason}); the queue is not started`,
  queueStartFailed: (err: string) => `cs -queue start did not run: ${err}`,
  queueStartExited: (code: number, tail: string) => `cs -queue start exited ${code}${tail === '' ? '' : `: ${tail}`}`,
  queueKickFailed: (err: string) => `the queue is armed, but its first turn did not start: ${err}`,
  finishRecordUnread: (dir: string) => `.cs/${dir}/${FINISH_RECORD} is not a record cs wrote; /finish progress is not shown`,
  finishPidUnknown: (err: string) => `cannot tell whether /finish is still running: ${err}`,
} as const

export const LOGS = {
  featuresUnread: (err: string) => `the features word could not be read: ${err}`,
  featuresExited: (base: string, code: number, line: string) => `cs ${base} -features exited ${code}: ${line}`,
  featuresUnreadable: (base: string, record: string) => `cs ${base} -features gave a record the band cannot read: ${record}`,
  featuresNoAnswer: (base: string, err: string) => `cs ${base} -features did not answer: ${err}`,
  transcriptUnread: (err: string) => `the transcript could not be read: ${err}`,
  colorFailed: (color: string, err: string) => `/color ${color} did not run: ${err}`,
  feedUnread: (message: string) => `the feed setting could not be read: ${message}`,
  settingsExited: (code: number, line: string) => `cs -config list exited ${code}: ${line}`,
  settingsUnreadable: (record: string) => `cs -config list gave a record the band cannot read: ${record}`,
  settingsUnread: (err: string) => `cs's settings could not be read: ${err}`,
} as const

// `what` is the cs command a reply is about: `cs -queue add` or `cs -queue list`.
export const REPLIES = {
  queueNoBin: 'The launch did not say where cs is (CS_BIN); run `cs -queue add "<task>"` from a shell in this session.',
  queueFailed: (what: string, err: string) => `${what} did not run: ${err}`,
  queueExited: (what: string, code: number, tail: string) => tail === '' ? `${what} exited ${code}.` : `${what} exited ${code}.\n${tail}`,
  queued: (task: string) => `Queued: ${task}`,
  csUsage: 'usage: /cs next|prev|first|last|<n>',
  railEmpty: 'the rail has no prompts',
  noneAfter: 'no prompt after this one',
  noneBefore: 'no prompt before this one',
  railCount: (count: number) => `the rail has ${count} ${count === 1 ? 'prompt' : 'prompts'}`,
} as const

export const COMMANDS = {
  queue: { name: 'queue', description: "Add a task to this cs session's walk-away queue, or list it.", argumentHint: '[task]', immediate: true },
  cs: { name: 'cs', description: "Bare: cs's settings panel. next|prev|first|last|<n>: scroll the transcript along the band's rail of prompts.", argumentHint: '[next|prev|first|last|<n>]', immediate: true },
} as const

// The countdown: seconds left, its ticker, and what the band last saw. Module
// state survives a /clear (measured), so every path that ends the countdown
// cancels the ticker; a reload of the mod drops it with its timers.
let left: number | undefined
let ticker: { cancel: () => void } | undefined
let bandIdle = false
// Whether a turn was running when the band last drew: a queue started then
// reaches its first stop without a prompt from the mod.
let turnRunning = false
// The handoff whose next step the count has toasted, by its text: one toast
// per armed handoff, so a count restarted for the same handoff (a prompt
// stopped it, the next turn's end started it again) says nothing, and the
// successor's own handoff, armed in the same process after the /clear, is
// toasted in its turn.
let stepToastedFor: string | undefined
// Set while the mod's own /clear runs. The marker stays armed until the
// successor's SessionStart consumes it, so the band still offers the button
// meanwhile; a second /clear would end the conversation the handoff started,
// so a press then does nothing.
let clearing = false
// cs's last refusal of this session's control files, toasted once: the band
// asks on every render while a handoff is armed.
let lastRefusal: string | undefined
// Whether cs's last answer on this session's control files was a refusal. Set
// and cleared by every vet (sessionVetted), so the session start's and a feed
// press's alike; only a passed vet or a reload clears it, never a prompt. The
// feed key reads off while it is set: the band's label says what cs-feed
// draws, and cs-feed reads a refused session as off.
let feedVetRefused = false
// Counts presses of the clear button: a press acts only if no later press or
// prompt came while cs was answering it.
let pressCount = 0

// Which conversation the turns belong to, and whether it is being judged. A
// conversation that begins past the force threshold did not get there by
// working: forcing it would rotate again as soon as its successor woke
// (measured at 1%). Only a conversation born of a /clear seen in this process
// (`clearSeen`, then `birth`) is judged that way, by the context its first
// turn ended with (`startPercent`). Any other new id (a launch, a reload, a
// /resume at 72%) is adopted unjudged, since past the line is exactly where
// the person asked to be rotated. Module state is kept across /clear, which
// is what makes the birth visible.
let adopted: string | undefined
let clearSeen = false
let birth: string | undefined
let startPercent: number | undefined
// Whether this load has registered /queue: session.start fires at load, and
// registering the same name again would only replace it.
let registered = false
// The /finish watch: its timer, whether the turn that started it has ended,
// which steps of which runs have been toasted (`<id>:started`,
// `<id>:<outcome>`), the gate the band shows while one runs under a live pid,
// and whether a problem reading the record or the pid has been said.
let finishWatch: { cancel: () => void } | undefined
let finishTurnOver = false
let finishShown = new Set<string>()
let finishGate: { task: string; since: number } | undefined
let finishProblemShown = false

// The features word: what the band's right edge says of the session's feature
// worktrees, as cs last answered, and the task a press finishes ('' for bare
// /finish, which lists them and asks; absent, no press). One reading at a
// time; the idle clock that reads again; the last complaint logged.
export type FeaturesWord = { label: string; finish?: string }
type BandPress = () => void | Promise<unknown>
export type BandEntry =
  // A word's ink colours the whole label, or only its `lead` glyph with the rest dim.
  | { key: string; kind: 'word'; label: string; ink?: { color: string | undefined } | { lead: string; color: string } }
  | { key: string; kind: 'press'; label: string; onPress: BandPress; ink?: { lead: string; color: string } }
  | { key: string; kind: 'chord'; label: string; action: string; onPress: BandPress; ink?: { text: string; color: string | undefined } }
type BandFacts = {
  featured?: { label: string; onPress?: BandPress }
  countdown?: { seconds: number; ink: string | undefined }
  rotating: boolean
  armed: boolean
  wrapping: boolean
  feed?: { on: boolean; color: string | undefined; onPress: BandPress }
  waiting: number
  gate?: string
  queued: number
  queueRunning: boolean
  // The queue glyph's amber, as the status line draws its queue count.
  queueInk: string
  mail: number
  rotate: BandPress
  wrap: BandPress
  queue: BandPress
}

const QUEUE_GLYPH = '\u25a4'
// The queue press's head: its glyph, its verb and its count.
const QUEUE_COUNT = /^\u25a4 run \d+/

export function buildBandEntries(facts: BandFacts): BandEntry[] {
  const entries: BandEntry[] = []
  if (facts.rotating) entries.push({ key: 'cs-rotate', kind: 'chord', label: facts.armed ? '/clear now' : 'rotate', action: ROTATE_ACTION, onPress: facts.rotate })
  // The grace follows the clear key whose press stops it.
  if (facts.countdown !== undefined) entries.push({ key: 'cs-countdown', kind: 'word', label: `in ${facts.countdown.seconds}s`, ink: { color: facts.countdown.ink } })
  if (facts.wrapping) entries.push({ key: 'cs-wrap', kind: 'chord', label: 'wrap', action: WRAP_ACTION, onPress: facts.wrap })
  if (facts.feed !== undefined) entries.push({ key: 'cs-feed', kind: 'chord', label: facts.feed.on ? 'feed ✓' : 'feed', action: FEED_ACTION, onPress: facts.feed.onPress, ink: facts.feed.on ? { text: '✓', color: facts.feed.color } : undefined })
  // The queue has no chord: a click or Enter under the band's focus starts it.
  if (facts.waiting > 0) entries.push({ key: 'cs-queue', kind: 'press', label: `${QUEUE_GLYPH} run ${facts.waiting} queued ${facts.waiting === 1 ? 'task' : 'tasks'}`, onPress: facts.queue, ink: { lead: QUEUE_GLYPH, color: facts.queueInk } })
  // The features word leads what the session is; only a ready feature can be pressed.
  if (facts.featured !== undefined) {
    const { label, onPress } = facts.featured
    entries.push(onPress === undefined ? { key: 'cs-features', kind: 'word', label } : { key: 'cs-features', kind: 'press', label, onPress })
  }
  if (facts.gate !== undefined) entries.push({ key: 'cs-gate', kind: 'word', label: facts.gate })
  if (facts.queued > 0) entries.push({ key: 'cs-queued', kind: 'word', label: `${QUEUE_GLYPH} queue ${facts.queued}${facts.queueRunning ? ' running' : ''}`, ink: { lead: QUEUE_GLYPH, color: facts.queueInk } })
  if (facts.mail > 0) entries.push({ key: 'cs-mail', kind: 'word', label: `mail ${facts.mail}` })
  return entries
}

let featuresWord: FeaturesWord | undefined
let featuresReading = false
let featuresClock: { cancel: () => void } | undefined
let featuresComplaint: string | undefined

// cs's settings as cs resolves them (`cs -config list --porcelain`): each
// key's value, for the records a settings file gave (the session's or this
// machine's). A key the shell pins, or whose value the launch measured, has
// none, so its $.env.get answers: cs puts the environment above the files,
// except a measured theme and background, which a file's pin outranks.
let fileSettings = new Map<string, string>()
let settingsReading = false
let settingsComplaint: string | undefined

// The rail. A prompt is a row of the transcript's live branch; its requestId
// is the id the engine drew its UserMessage row under, once seen.
export type Prompt = { uuid: string; text: string }
// How much of a prompt's first line a tick carries as its text.
export const RAIL_TEXT_CHARS = 80
// The fewest cells before the rail that name a prompt.
const RAIL_LABEL_MIN = 10
// `$.fs.read` refuses a file over this; a longer transcript is read from its tail.
const READ_CAP = 4 * 1024 * 1024
// What the transcript last read held, and the file it was: the file is parsed
// again only when its size or mtime moved.
let railFile: { path: string; size: number; mtimeMs: number } | undefined
let prompts: Prompt[] = []
// Row key (a uuid's first four groups, or the id itself) -> the requestId the
// engine last drew that row under and the row's first line, from the
// UserMessage renders; requestId -> the latest non-null onScreen report.
let drawnRows = new Map<string, { requestId: string; text: string }>()
let shown = new Map<string, { first: number; last: number; of: number }>()
// Prompts a jump was refused for, by uuid; whether that, a prompt no row has
// drawn yet, and a transcript read from its tail have been said this session.
let denied = new Set<string>()
let denySaid = false
let notYetSaid = false
let tailSaid = false
// The prompt the band last drew thick, and whether a redraw for a moved read
// prompt is already scheduled.
let drawnRead = -1
let redrawPending = false
// The band's /config rows (plugin.json userConfig), as this activation got
// them: whether it draws the prompt bars at all (off by default), the prompt
// it names, `latest` (the newest) or `read` (the one being read), and the
// most bars it draws before the prompts past them fold into `…N` or `M…`. A
// change reloads the plugin and register runs again. A stored value the band
// cannot draw leaves it without bars (undefined), said once, and the rest of
// the mod running: a throw from register would unload all of it.
const CS_PLUGIN = 'cs'
type BandOptions = { prompts: boolean; prompt: 'latest' | 'read'; bars: number }
let bandOptions: BandOptions | undefined
let bandProblem: string | undefined
let bandProblemSaid = false
let feedPressPending: Promise<void> | undefined
let feedComplaint: string | undefined

// What is wrong with a value for one of the band's rows, by field name;
// undefined when the band can draw it, or the field is not the band's.
function bandOptionProblem(field: string, value: unknown): string | undefined {
  if (field === 'bandPrompts') return typeof value === 'boolean' ? undefined : `cs.bandPrompts is on or off; got ${String(value)}`
  if (field === 'bandPrompt') return value === 'latest' || value === 'read' ? undefined : `cs.bandPrompt is latest or read; got ${String(value)}`
  if (field === 'bandBars') {
    return typeof value === 'number' && Number.isInteger(value) && value >= 1 ? undefined : `cs.bandBars is the most bars the band draws, a whole number of 1 or more; got ${String(value)}`
  }
  return undefined
}

export function register(on: On, options: PluginOptions) {
  bandProblem = bandOptionProblem('bandPrompts', options.bandPrompts) ?? bandOptionProblem('bandPrompt', options.bandPrompt) ?? bandOptionProblem('bandBars', options.bandBars)
  bandOptions = bandProblem === undefined
    ? { prompts: options.bandPrompts as boolean, prompt: options.bandPrompt as BandOptions['prompt'], bars: options.bandBars as number }
    : undefined
  bandProblemSaid = false
  feedPressPending = undefined
  feedComplaint = undefined
  // A (re)load has no countdown: the engine cancelled the old one's timers.
  left = undefined; ticker = undefined; bandIdle = false; turnRunning = false; stepToastedFor = undefined; adopted = undefined; clearSeen = false; clearing = false; birth = undefined; startPercent = undefined; registered = false
  finishWatch = undefined; finishTurnOver = false; finishShown = new Set(); finishGate = undefined; finishProblemShown = false
  lastRefusal = undefined
  feedVetRefused = false
  featuresWord = undefined; featuresReading = false; featuresClock = undefined; featuresComplaint = undefined
  fileSettings = new Map(); settingsReading = false; settingsComplaint = undefined
  railFile = undefined; prompts = []; drawnRows = new Map(); shown = new Map(); denied = new Set(); denySaid = false; notYetSaid = false; tailSaid = false; drawnRead = -1; redrawPending = false
  on('session.start', async ($, e, next) => {
    if (!registered) {
      registered = true
      await $.command.register(COMMANDS.queue)
      await $.command.register(COMMANDS.cs)
    }
    await refreshRail($)
    readFeaturesLater($)
    readSettingsLater($)
    // Only in a cs session; anywhere else the mod stays silent. Nor while git
    // tracks the session's control files: the heartbeat would change them.
    if ((await $.fs.exists(`${e.cwd}/.cs/local`)) && (await isCsSession($, e.cwd)) && (await sessionVetted($, e.cwd))) {
      await $.fs.write(`${e.cwd}/${HEARTBEAT}`, `${new Date().toISOString()}\n`)
    }
    return next(e)
  })

  // `/queue <task>` runs `cs -queue add` by the path the launch exported;
  // `/queue` alone runs `cs -queue list`. The child inherits the claude
  // process's environment, and CLAUDE_SESSION_META_DIR there picks the queue.
  // Registered immediate, so the hook may run while a turn streams: it reads
  // nothing of the turn. cs is the judge of the task: whatever it refuses
  // (an empty or multi-line body) comes back as its own stderr.
  on('command.run', { command: 'queue' }, async ($, e) => {
    const task = e.args.trim()
    const argv = task === '' ? ['-queue', 'list'] : ['-queue', 'add', e.args]
    const bin = await $.env.get("CS_BIN")
    if (!bin) return { text: REPLIES.queueNoBin }
    const what = `cs ${argv.slice(0, 2).join(' ')}`
    let result: { exitCode: number; stdout: string; stderr: string }
    try {
      result = await $.process.run([bin, ...argv])
    } catch (err) {
      return { text: REPLIES.queueFailed(what, String(err instanceof Error ? err.message : err)) }
    }
    if (result.exitCode !== 0) {
      const tail = result.stderr.split('\n').filter(l => l.trim() !== '').slice(-5).join('\n')
      return { text: REPLIES.queueExited(what, result.exitCode, tail) }
    }
    if (task !== '') {
      // The command's text lands in the transcript, which a running turn
      // scrolls past; the toast under the prompt confirms the add where the
      // person is looking. One line, so a long task is cut.
      $.ui.toast(TOASTS.queued(task))
      return { text: REPLIES.queued(task) }
    }
    const pending = /^Pending \((\d+)\)$/m.exec(result.stdout)
    if (pending && !(await queueRunning($))) void offerToStart($, bin, Number(pending[1]))
    return { text: result.stdout.trimEnd() }
  })

  // `/cs next|prev|first|last|<n>` scrolls the transcript to a prompt of the
  // rail, counted from the one being read. Immediate: a typed command answers
  // the person's own input, which is when the engine lets a plugin move a
  // transcript row, mid-turn too. A move answers with no text: a transcript
  // row of its own would grow the transcript under the view it just moved.
  // Bare /cs is the cs panel's and goes on to the next hook; the panel's own
  // hook hands an argument on, so the two answer alike in either order.
  on('command.run', { command: 'cs' }, async ($, e, next) => {
    const asked = e.args.trim()
    if (asked === '') return next(e)
    const count = prompts.length
    const current = readIndex()
    let target: number
    if (asked === 'next') target = current + 1
    else if (asked === 'prev') target = current - 1
    else if (asked === 'first') target = 0
    else if (asked === 'last') target = count - 1
    else if (/^\d+$/.test(asked)) target = Number(asked) - 1
    else return { text: REPLIES.csUsage }
    if (count === 0) return { text: REPLIES.railEmpty }
    if (asked === 'next' && target >= count) return { text: REPLIES.noneAfter }
    if (asked === 'prev' && target < 0) return { text: REPLIES.noneBefore }
    if (target < 0 || target >= count) return { text: REPLIES.railCount(count) }
    await jumpTo($, target)
    return {}
  })

  // A /config row of the band's takes only a value the band can draw: a bad
  // one is refused at the menu, where it is typed, not met at the next load.
  on('config.set', async ($, e, next) => {
    if (e.provider.plugin !== CS_PLUGIN) return next(e)
    const problem = bandOptionProblem(e.key.slice(e.key.lastIndexOf('.') + 1), e.value)
    return problem === undefined ? next(e) : { deny: problem }
  })

  // The end of a turn is the one moment a rotation can be started for the
  // person: the answer is in, nothing runs. An aborted or errored turn is no
  // place to start one, and a subagent's turn ends in the same event. A
  // press's /rotate runs in the main loop's next turn, so that turn's end,
  // whatever ended it, is where the press is over.
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      finishTurnOver = true
      await clearPressed($)
      await refreshRail($)
      readFeaturesLater($)
      readSettingsLater($)
    }
    if (e.reason === 'answer' && e.agentId === undefined) await forceRotation($)
    return next(e)
  })

  // /finish is a skill: this fires when it is typed, and when `cs <base>
  // -finish` launches a conversation on it. Its turn runs cs's integrate and
  // retire, and the watch follows the record cs writes meanwhile, until that
  // turn is over and nothing runs.
  on('skill.prompt', { skill: 'finish' }, async ($, e, next) => {
    finishTurnOver = false
    if (!finishWatch) await watchFinish($)
    return next(e)
  })

  // A prompt entering the session, from anywhere, means the conversation is
  // not done with: the countdown stops and the prompt goes through untouched.
  on('prompt.submit', async ($, e, next) => {
    if (ticker) stopCountdown($)
    // A new turn asks afresh, as the Stop hook says it afresh each turn: the
    // band draws the handoff again, and its press asks cs before it clears.
    // A press still waiting on cs is dropped.
    lastRefusal = undefined
    pressCount += 1
    return next(e)
  })

  // A /clear from anywhere else (typed, another plugin) ends the conversation
  // the count belongs to, so the timer must not outlive it, and makes the
  // next conversation a birth; a run the engine refuses makes nothing.
  on('command.run', { command: 'clear' }, async ($, e, next) => {
    clearSeen = true
    if (ticker) stopCountdown($)
    let result
    try {
      result = await next(e)
    } catch (err) {
      clearSeen = false
      throw err
    }
    // The rail is the conversation's: the next one starts with none, and
    // reads its own transcript as its first turn ends.
    railFile = undefined; prompts = []; drawnRows = new Map(); shown = new Map(); denied = new Set(); drawnRead = -1
    $.ui.invalidate('ui.render')
    return result
  })

  // A turn that starts from a prompt is work after any wrap that finished: the
  // marker that wrap left no longer describes the conversation. A continuation
  // (no prompt, as a Stop hook's feedback starts one) is the wrap's own turn.
  // A main-loop turn rereads cs's settings, so one changed while idle counts
  // from the next prompt, the rotation its end may force included.
  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) readSettingsLater($)
    if (e.text !== '') await clearWrapped($)
    return next(e)
  })

  // Every prompt row the engine draws passes through untouched; what it is
  // drawn under, and what of it is on screen, is kept for the rail. The
  // composer's echo draws first under `placeholder`, the real id on the next
  // render (measured), so that id binds nothing. A `null` report on a row's
  // first render is the row not laid out yet (measured): nothing changes. A
  // `null` after a report is the row drawn outside the viewport: its report
  // goes, as the contract's own example does. A report that moves the read
  // prompt redraws the band from a timer: an invalidate inside a render is a
  // render loop.
  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    if (e.requestId !== 'placeholder') {
      drawnRows.set(rowKey(e.requestId), { requestId: e.requestId, text: firstLine(e.props.text) })
      if (e.props.onScreen) shown.set(e.requestId, e.props.onScreen)
      else if (e.props.onScreen === null) shown.delete(e.requestId)
      if (!redrawPending && bandOptions?.prompts === true && prompts.length > 1 && namedIndex() !== drawnRead) {
        redrawPending = true
        $.clock.after(0, () => { redrawPending = false; $.ui.invalidate('ui.render') })
      }
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const drawn = await next(e)
    // The band draws in a new conversation before any of its turns end, so
    // the birth is settled here: a later /resume is not mistaken for it.
    await noteConversation($, await $.session.id())
    // A survey owns the band; a running turn cannot be rotated out of.
    turnRunning = e.props.isWorking
    bandIdle = !e.props.hasSurvey && !e.props.isWorking
    // The /finish gate's word draws mid-turn, since the gate runs inside one,
    // whatever else the band has to say.
    const gate = await gateWord($)
    // The band draws on every redraw and asks cs nothing: it shows the last
    // answer cs gave (sessionVetted), which every step that acts asks afresh.
    // An armed handoff makes the rotation due at any context.
    const handoff = lastRefusal === undefined && (await handoffArmed($))
    const armed = bandIdle && handoff
    const { context } = await $.session.usage()
    const percent = context.percent
    const due = handoff || (percent !== undefined && percent >= (await threshold($)))
    let rotating = bandIdle && due
    // Tasks queued and nothing running them, at any context, draw the start
    // key; an armed handoff draws its clear key alone. Tasks queued that the
    // start key does not offer (the queue runs them, a turn runs, or the
    // clear key stands alone) are said, not pressed.
    const queue = e.props.hasSurvey ? 0 : await queueLength($)
    const queueStarted = queue > 0 && (await queueRunning($))
    let waiting = !bandIdle || armed || queueStarted ? 0 : queue
    let queued = waiting > 0 ? 0 : queue
    // Mail from other sessions that `cs -msg` has not read yet.
    let mail = e.props.hasSurvey ? 0 : await unreadMail($)
    // The rail draws, once cs.bandPrompts turns it on, whenever the
    // conversation has two prompts to move between, a turn running or not,
    // under the same ownership as the keys; its bars draw not at all while a
    // stored band row is bad, which the lead's band says once.
    const bars = bandOptions?.bars
    let railing = !e.props.hasSurvey && prompts.length > 1 && bandOptions?.prompts === true
    if (bandProblem !== undefined && !bandProblemSaid && (await ownsRotation($))) {
      bandProblemSaid = true
      $.ui.toast(TOASTS.bandOption(bandProblem))
    }
    // The features word leads what the session is, at the line's right; a
    // running gate already names the feature it lands.
    let featured = !e.props.hasSurvey && gate === undefined ? featuresWord : undefined
    let feedEligible = bandIdle && !armed
    if ((rotating || waiting > 0 || queued > 0 || mail > 0 || railing || featured || feedEligible) && !(await ownsRotation($))) { rotating = false; waiting = 0; queued = 0; mail = 0; railing = false; featured = undefined; feedEligible = false }
    // The named tick is remembered on every path, drawn or not, so a row's
    // report that moves nothing visible schedules no redraw.
    const named = namedIndex()
    drawnRead = named
    const hasContent = rotating || waiting > 0 || queued > 0 || mail > 0 || gate !== undefined || railing || featured !== undefined
    if (!hasContent && !feedEligible) return drawn
    // Listing /feed reads availability without queuing a command or adding a status row.
    const feeding = feedEligible && (await $.command.list()).some(command => command.name === 'feed' && command.source === 'plugin' && command.plugin === 'cs-feed')
    if (!hasContent && !feeding) return drawn
    const wrapped = rotating && !armed && (await wrapFinished($))
    const chords = await boundChords($)
    const own = paletteColor(await sessionColor($))
    const { Box, Text, Button } = await $.ui.resolve(e)
    const wrapping = rotating && !armed && !wrapped
    const finish = featured?.finish
    const entries = buildBandEntries({
      featured: featured === undefined ? undefined : { label: featured.label, onPress: finish === undefined || !bandIdle ? undefined : () => pressFinish($, finish) },
      countdown: armed && left !== undefined ? { seconds: left, ink: await rampColor($, left) } : undefined,
      rotating, armed, wrapping, waiting, gate, queued, queueRunning: queueStarted, mail,
      queueInk: amberColor(fileSettings.get('CS_TERM_BG_RGB') ?? await $.env.get("CS_TERM_BG_RGB"), fileSettings.get('CS_TERM_THEME') ?? await $.env.get("CS_TERM_THEME")),
      feed: feeding ? { on: !feedVetRefused && await readFeed($), color: own, onPress: () => pressFeed($) } : undefined,
      rotate: armed ? () => pressClear($) : () => pressRotate($),
      wrap: () => askToWrap($),
      queue: () => pressQueueStart($),
    })
    const rail = railing && bars !== undefined ? { prompts, named, denied, bars, jump: (i: number) => jumpTo($, i) } : undefined
    return drawBand({ drawn, entries, chords, own, bodyColumns: e.props.bodyColumns, surface: e.surface, rail }, { Box, Text, Button })
  })

  // A rail tick never takes the band's focus ring: the ring draws as an
  // inverted block that reads as part of the rail, and the band's keyboard
  // route along the rail is /cs. The band's other buttons keep it.
  on('ui.focus', { component: 'AbovePrompt', plugin: 'cs' }, async ($, e, next) => {
    if (e.element?.startsWith('cs-rail-')) return { deny: 'cs: the rail takes clicks and /cs, not the focus ring' }
    return next(e)
  })
}

// What the band's line is drawn from, as the AbovePrompt handler read it: the
// engine's own tree, the entries, the bound chords by action, the session
// colour, and the rail when cs.bandPrompts draws one.
export type BandView = {
  drawn: RenderElement
  entries: BandEntry[]
  chords: Record<string, string>
  own: string | undefined
  bodyColumns: number
  surface: RenderSurface
  rail?: { prompts: Prompt[]; named: number; denied: Set<string>; bars: number; jump: (i: number) => Promise<void> }
}
export type BandElements = Pick<ReturnType<EngineInterface['ui']['resolve']>, 'Box' | 'Text' | 'Button'>

// The words that leave an overrunning line first, first to last, each only as
// a word: a features word that can be pressed is a press and stays. After
// them the shared chord prefix goes. The countdown, the presses and the
// chords leave only whole: last (LEAVE_ORDER), or earlier where what the line
// would draw of them says nothing (mutedBy).
const DROP_ORDER = ['cs-mail', 'cs-queued', 'cs-features', 'cs-gate']

// Which side of the line each entry draws on: the actions, what a chord or a
// press does now, at the left; what the session is, at the
// right edge beside the rail. The line's free cells stand between the two.
type Zone = 'actions' | 'status'
const ZONES = new Map<string, Zone>([
  ['cs-rotate', 'actions'], ['cs-countdown', 'actions'], ['cs-wrap', 'actions'], ['cs-feed', 'actions'], ['cs-queue', 'actions'], ['cs-queued', 'actions'],
  ['cs-features', 'status'], ['cs-gate', 'status'], ['cs-mail', 'status'],
])
// The cells between two entries of a zone, and the fewest between the zones.
const GAP = 3
const SEP = ' '.repeat(GAP)
// Between the keys (the chords and the clear key's countdown) and the presses
// and words after them, in the same cells as SEP.
const KEYS_END = ' \u00b7 '

// The entries of each zone, in the line's order.
function zonesOf<T extends BandEntry>(entries: T[]): Record<Zone, T[]> {
  const zones: Record<Zone, T[]> = { actions: [], status: [] }
  for (const entry of entries) {
    const zone = ZONES.get(entry.key)
    if (zone === undefined) throw new Error(`cs: the band has no zone for ${entry.key}`)
    zones[zone].push(entry)
  }
  return zones
}

// The chords that share a prefix (`ctrl+x 1`, `ctrl+x 2`): the prefix, and
// each chord's own key after it, or the chord whole when they differ.
function chordSpelling(entries: BandEntry[], chords: Record<string, string>) {
  const prefix = sharedPrefix(entries.flatMap(entry => entry.kind === 'chord' ? [chords[entry.action]] : []))
  return {
    prefix,
    spelled: (action: string) => {
      const chord = chords[action]
      return chord === undefined ? undefined : prefix === undefined ? chord : chord.slice(prefix.length + 1)
    },
  }
}

const firstChordOf = (entries: BandEntry[], chords: Record<string, string>) =>
  entries.findIndex(entry => entry.kind === 'chord' && chords[entry.action] !== undefined)

// An entry as the fitted line draws it: a chord with no room for its word
// draws as its key alone.
export type FittedEntry = BandEntry & { keyOnly?: true }

// What the words take, in cells, as the tree draws them: in each zone a
// separator between entries, the prefix once before the first bound chord
// with its one-cell margin, each chord's key with its one-cell margin, then
// the label; and the fewest cells between the zones when both draw.
// `spelling` is the whole line's: a cut that leaves fewer chords keeps them
// spelled as the full line spells them.
type ChordSpelling = ReturnType<typeof chordSpelling>
function wordCellsOf(entries: FittedEntry[], chords: Record<string, string>, { prefix, spelled }: ChordSpelling, prefixed: boolean): number {
  const cellsOfZone = (zone: FittedEntry[]) => {
    const firstChord = firstChordOf(zone, chords)
    return cellWidth(zone.map((entry, index) => {
      const chord = entry.kind === 'chord' ? spelled(entry.action) : undefined
      const keyed = chord === undefined ? entry.label : entry.keyOnly ? chord : `${chord} ${entry.label}`
      return `${index === firstChord && prefixed && prefix !== undefined ? `${prefix} ` : ''}${keyed}`
    }).join(SEP))
  }
  const { actions, status } = zonesOf(entries)
  const actionCells = cellsOfZone(actions)
  const statusCells = cellsOfZone(status)
  return actionCells + statusCells + (actionCells > 0 && statusCells > 0 ? GAP : 0)
}

// The keepers whose words are free text, shortened first to last before any
// chord loses its word, each no shorter than one cell and `…`.
const SHORTEN_ORDER = ['cs-features', 'cs-queue']
const SHORTEST_CELLS = 2

// The entries that leave whole, first to last, once the words are short and
// every bound chord is its key: the countdown's free text before the actions,
// the presses before the chords. Only chords are left after them.
const LEAVE_ORDER = ['cs-countdown', 'cs-features', 'cs-queue']

// The entries a line of `room` cells draws, and whether it spells the chord
// prefix. The engine's Buttons never shrink, so a line wider than its room
// would squeeze the band's Texts to a cell each and wrap them down: the band
// draws one line. While it overruns, the entries leave in LEAVE_ORDER, then
// the chords right to left, and the line is fitted again from what stays, so
// a chord left after one leaves takes its word back when it fits. A Button
// that leaves the tree takes its chord with it, so the chords leave last. An
// unbound chord has no key to fall back to: the last one cuts its word to end
// in `…` before it leaves. An entry that says nothing as fitted (mutedBy)
// leaves first, overrun or not, and the line is fitted again without it.
export function fitBand(all: BandEntry[], chords: Record<string, string>, room: number): { entries: FittedEntry[]; prefixed: boolean } {
  const spelling = chordSpelling(all, chords)
  for (let kept = all; ;) {
    const fitted = shortenBand(kept, chords, spelling, room)
    const mute = mutedBy(fitted.entries, kept)
    if (mute !== undefined) {
      kept = kept.filter(entry => entry.key !== mute)
      continue
    }
    const excess = wordCellsOf(fitted.entries, chords, spelling, fitted.prefixed) - room
    const last = fitted.entries[fitted.entries.length - 1]
    if (excess <= 0 || last === undefined) return fitted
    const leaving = LEAVE_ORDER.find(key => fitted.entries.some(entry => entry.key === key))
    if (leaving === undefined) {
      if (last.kind !== 'chord') throw new Error(`cs: the band left ${last.key} for last, where only chords stay`)
      const keep = (last.keyOnly ? 0 : cellWidth(last.label)) - excess
      if (keep >= 1) return { entries: [...fitted.entries.slice(0, -1), { ...last, label: cutToCells(last.label, keep), ink: undefined }], prefixed: false }
    }
    kept = kept.filter(entry => entry.key !== (leaving ?? last.key))
  }
}

// The entry a fitted line draws that says nothing, which leaves before the
// line is fitted again: a status word cut shorter than its head, the words
// before its first ` · `, and `…`, which names nothing (`1…` of `1 feature ·
// fix-auth ready`); then the countdown beside a clear key drawn bare (`1   in
// 18s` counts down to nothing the line names, so it leaves before
// `/clear now` loses its word). The cut word goes first: the cells it took
// may be what bared the key. `kept` holds each entry's whole label.
function mutedBy(fitted: FittedEntry[], kept: BandEntry[]): string | undefined {
  const stub = fitted.find(entry => {
    if (ZONES.get(entry.key) !== 'status') return false
    const whole = kept.find(k => k.key === entry.key)?.label
    if (whole === undefined) throw new Error(`cs: the band fitted ${entry.key}, an entry it was not given`)
    const head = whole.split(' · ')[0] ?? whole
    return entry.label !== whole && cellWidth(entry.label) < cellWidth(head) + 1
  })
  if (stub !== undefined) return stub.key
  const bareClear = fitted.some(entry => entry.key === 'cs-rotate' && entry.keyOnly)
  return bareClear && fitted.some(entry => entry.key === 'cs-countdown') ? 'cs-countdown' : undefined
}

// The entries of a line of `room` cells before any leaves whole: each step
// runs only while the line still overruns. Words leave (DROP_ORDER, then the
// prefix); the features and queue words shorten (SHORTEN_ORDER); bound chords
// fall back to their key alone, right to left, so the actions outlive the
// free text. What it returns may still overrun.
function shortenBand(all: BandEntry[], chords: Record<string, string>, spelling: ChordSpelling, room: number): { entries: FittedEntry[]; prefixed: boolean } {
  const over = (entries: FittedEntry[], prefixed: boolean) => wordCellsOf(entries, chords, spelling, prefixed) - room
  let entries: FittedEntry[] = all
  for (const key of DROP_ORDER) {
    if (over(entries, true) <= 0) return { entries, prefixed: true }
    entries = entries.filter(entry => entry.key !== key || entry.kind !== 'word')
  }
  if (over(entries, true) <= 0) return { entries, prefixed: true }
  for (const key of SHORTEN_ORDER) {
    const excess = over(entries, false)
    if (excess <= 0) return { entries, prefixed: false }
    entries = entries.map(entry => {
      const cells = cellWidth(entry.label)
      return entry.key !== key || cells <= SHORTEST_CELLS ? entry : { ...entry, label: shortened(entry.label, Math.max(SHORTEST_CELLS, cells - excess)) }
    })
  }
  for (let i = entries.length - 1; i >= 0; i--) {
    if (over(entries, false) <= 0) return { entries, prefixed: false }
    entries = entries.map((entry, j) => (j === i && entry.kind === 'chord' && spelling.spelled(entry.action) !== undefined ? { ...entry, keyOnly: true } : entry))
  }
  return { entries, prefixed: false }
}

export function drawBand(v: BandView, el: BandElements): RenderElement {
  const { Box, Text, Button } = el
  const { chords, own } = v
  // The line starts two cells in; the words have the rest.
  const room = v.bodyColumns - 2
  // A rail keeps its least, the named bar alone, the older prompts folded
  // into `…N ` before it and the newer into ` M…` after it, and the three
  // cells before it: the words fit what that leaves, so the status words drop
  // and the keys shorten before the rail goes. The actions outrank the rail:
  // where the words beside its least lose an action the whole line would
  // keep, they fit the whole line, and the rail takes what they leave, or
  // nothing. An action the whole line drops too (the count beside a bare
  // clear key) is no reason for the rail to go, nor is a word the band drops
  // (the queue word draws among the actions, but leaves before the rail).
  const reserved = v.rail === undefined ? 0 : railCells(v.rail.prompts.length, leastWindow(v.rail.named)) + GAP
  const actionKeys = (all: BandEntry[]) => zonesOf(all).actions.filter(entry => entry.kind !== 'word' || !DROP_ORDER.includes(entry.key)).map(entry => entry.key)
  const besideRail = fitBand(v.entries, chords, room - reserved)
  const keptActions = actionKeys(besideRail.entries)
  const wholeLine = fitBand(v.entries, chords, room)
  const { entries, prefixed } = actionKeys(wholeLine.entries).every(key => keptActions.includes(key)) ? besideRail : wholeLine
  // The Buttons carry no hotkey: a bare digit pressed them from an empty
  // composer, where a digit typed as the answer to a numbered question
  // belongs. A chord bound to each Button's action presses it instead, and
  // the engine draws a Button with no hotkey as its label alone, so the key
  // is spelled beside it, and only when keybindings.json binds one. Chords
  // that share a prefix (`ctrl+x 1`, `ctrl+x 2`) spell it once, bold in the theme's light gray, and
  // each Button its own key; chords that differ are spelled whole.
  const spelling = chordSpelling(v.entries, chords)
  const { spelled } = spelling
  const prefix = prefixed ? spelling.prefix : undefined
  const key = (action: string) => {
    const text = spelled(action)
    return text !== undefined && <Box marginRight={1}><Text bold color={own}>{text}</Text></Box>
  }
  // A chord with no room for its word is its key alone, still the Button its
  // action presses; fitBand keys only a bound chord.
  const keyButton = (entry: Extract<BandEntry, { kind: 'chord' }>) => {
    const text = spelled(entry.action)
    if (text === undefined) throw new Error(`cs: the band drew ${entry.key} as a key it has no chord for`)
    return <Button key={entry.key} action={entry.action} plain label={text} onPress={entry.onPress}><Text bold color={own}>{text}</Text></Button>
  }
  // What the words take, in cells, so the rail knows what the line leaves it.
  const wordCells = wordCellsOf(entries, chords, spelling, prefixed)
  // The rail: one upright bar per prompt, flush at the line's right edge, `┃`
  // for the one the band names, `┆` for one a jump was refused, `│`
  // otherwise (side by side, flat ticks run together into one line), each a
  // Button (the named one a Text, as dim as the rest: there is nowhere to
  // jump, and its heavier stroke alone marks it). It draws at most
  // cs.bandBars bars in what the line leaves after the inset, the gaps and
  // the words, always the named one among them (railTicks); the older prompts
  // collapse into one `…N` run, a cell before the first bar, and any newer
  // than the drawn bars into one `M…` run, a cell after the last. The named
  // tick is remembered so a report that moves it can redraw the band.
  const budget = room - (wordCells > 0 ? GAP + wordCells : 0)
  const rail = v.rail
  const shown = rail === undefined ? undefined : railTicks(rail.prompts.length, budget, rail.bars, rail.named)
  const ticks = rail === undefined || shown === undefined ? undefined : { ...rail, ...shown }
  const drawnTick = (i: number) => ticks !== undefined && i >= ticks.from && i < ticks.to
  // Left of the rail, GAP cells before it so the `…N` run never reads as
  // the cut name's own `…`, the band names a prompt in what the line leaves:
  // the newest or the one being read (cs.bandPrompt), or the one under the
  // pointer. Too little left to name one names none.
  const railWidth = ticks === undefined ? 0 : railCells(ticks.prompts.length, ticks)
  const labelRoom = ticks === undefined ? 0 : budget - railWidth - GAP
  const labeled = labelRoom >= RAIL_LABEL_MIN
  // A bar under the pointer swaps its prompt in over the named one, on the
  // terminal only: the desktop app paints a card over a line without hiding
  // what is under it, so both prompts would show at once.
  const hovering = labeled && v.surface === 'terminal'
  const name = (prompts: Prompt[], i: number) => {
    const p = prompts[i]
    if (p === undefined) throw new Error(`cs: the band named prompt ${i} of ${prompts.length}`)
    return `#${i + 1} ${p.text}`
  }
  // The name is as wide as the widest prompt it can show, the named one or a
  // drawn bar's under the pointer, and no wider than the room: a name sized
  // to the one it shows would move the words before it whenever a swap shows
  // a longer or shorter one. It is padded on its left, so it hugs the gap
  // before the bars.
  const labelCells = ticks === undefined || !labeled ? 0 : Math.min(labelRoom, Math.max(...[ticks.named, ...(hovering ? ticks.prompts.map((_, i) => i).filter(drawnTick) : [])]
    .map(i => cellWidth(name(ticks.prompts, i)))))
  // Each name fills the width, so a card over the named one paints every
  // cell of it: a shorter one would leave the named one's head showing.
  const label = (prompts: Prompt[], i: number) => fitRight(name(prompts, i), labelCells)
  // A line too narrow for any tick, with nothing else to say, draws nothing.
  if (entries.length === 0 && ticks === undefined) return v.drawn
  // One thin line, a blank line above it so it reads apart from the
  // transcript, in two zones: at the left the actions, only the words that
  // need a key now, the keys in the session colour and the rest dim; at the
  // right edge what the session is, dim, then the prompt's name, then the
  // rail, ending in the line's last cell. A spacer that grows
  // takes the line's free cells between them, so the rail stays put as the
  // actions come and go; the row is the line's whole width for it to grow
  // into, and a line with nothing at the right draws no spacer. The context
  // percentage is the bar's to carry; the band does not repeat it. It starts
  // two columns in, where Claude Code draws the bar and the mode line under
  // the prompt. A Button is a block: nested in a Text the engine refuses the
  // whole tree (measured), so each separator stands beside its Button.
  const { actions, status } = zonesOf(entries)
  const right = status.length > 0 || ticks !== undefined
  const drawZone = (zone: FittedEntry[]) => {
    const firstChord = firstChordOf(zone, chords)
    const afterKeys = zone.findLastIndex(entry => entry.kind === 'chord' || entry.key === 'cs-countdown') + 1
    return zone.flatMap((entry, index) => [
      index > 0 && <Text dimColor>{index === afterKeys ? KEYS_END : SEP}</Text>,
      index === firstChord && prefix !== undefined && <Box marginRight={1}><Text bold color="subtle">{prefix}</Text></Box>,
      entry.kind === 'chord' && !entry.keyOnly && key(entry.action),
      entry.kind === 'word'
        ? entry.ink === undefined ? <Text dimColor>{entry.label}</Text>
          : 'lead' in entry.ink ? <Text><Text color={entry.ink.color}>{entry.ink.lead}</Text><Text dimColor>{entry.label.slice(entry.ink.lead.length)}</Text></Text>
          : <Text bold color={entry.ink.color}>{entry.label}</Text>
        : entry.kind === 'chord'
          ? entry.keyOnly ? keyButton(entry) : entry.ink === undefined
            ? <Button key={entry.key} action={entry.action} plain label={entry.label} onPress={entry.onPress} />
            : <Button key={entry.key} action={entry.action} plain label={entry.label} onPress={entry.onPress}>{entry.label.slice(0, -entry.ink.text.length)}<Text color={entry.ink.color}>{entry.ink.text}</Text></Button>
          : entry.ink === undefined
            ? <Button key={entry.key} plain label={entry.label} onPress={entry.onPress} />
            : <Button key={entry.key} plain label={entry.label} onPress={entry.onPress}><Text color={entry.ink.color}>{entry.ink.lead}</Text>{entry.label.slice(entry.ink.lead.length)}</Button>,
    ])
  }
  return (
    <Box flexDirection="column">
      {v.drawn}
      <Box marginTop={1}>
        <Box key="cs-rotate-band" marginLeft={2} {...(right ? { width: v.bodyColumns - 2 } : {})}>
          {drawZone(actions)}
          {right && <Box key="cs-spacer" flexGrow={1} />}
          {right && (
            <Box key="cs-status" marginLeft={actions.length > 0 ? GAP : 0}>
              {drawZone(status)}
              {ticks !== undefined && labeled && (
                <Box width={labelCells} marginLeft={status.length > 0 ? GAP : 0}>
                  {/* the theme's lightest text gray, `subtle`, which follows light and dark: the name stays quieter than the dim words before it */}
                  <Text color="subtle" italic wrap="truncate-end">{label(ticks.prompts, ticks.named)}</Text>
                  {/* a card for each drawn bar but the named one: a prompt folded into `…N` or `M…` has no bar to hover */}
                  {hovering && ticks.prompts.map((_, i) => drawnTick(i) && i !== ticks.named && (
                    <Box position="absolute" top={0} left={0} display="none" hover={{ scope: `cs-rail-${i}`, display: 'flex' }}>
                      <Text color="subtle" italic wrap="truncate-end">{label(ticks.prompts, i)}</Text>
                    </Box>
                  ))}
                </Box>
              )}
              {ticks !== undefined && (
                <Box key="cs-rail" marginLeft={status.length > 0 || labeled ? GAP : 0}>
                  {ticks.from > 0 && <Box marginRight={1}><Text dimColor>{`…${ticks.from}`}</Text></Box>}
                  {ticks.prompts.slice(ticks.from, ticks.to).map((p, j) => {
                    const i = ticks.from + j
                    if (i === ticks.named) return <Text dimColor>{'┃'}</Text>
                    return <Button key={`cs-rail-${i}`} plain dimColor label={ticks.denied.has(p.uuid) ? '┆' : '│'}
                                   hover={hovering ? { scope: `cs-rail-${i}`, dimColor: false } : undefined} onPress={() => ticks.jump(i)} />
                  })}
                  {ticks.to < ticks.prompts.length && <Box marginLeft={1}><Text dimColor>{`${ticks.prompts.length - ticks.to}\u2026`}</Text></Box>}
                </Box>
              )}
            </Box>
          )}
        </Box>
      </Box>
    </Box>
  )
}

// The chord prefix every bound key shares, up to its last space (`ctrl+x` of
// `ctrl+x 1` and `ctrl+x 2`); undefined when none are bound, the bound chords
// differ before their last word, or a bound chord is one word.
export function sharedPrefix(chords: (string | undefined)[]): string | undefined {
  const bound = chords.filter((chord): chord is string => chord !== undefined)
  if (bound.length === 0) return undefined
  const prefixes = bound.map(chord => {
    const at = chord.lastIndexOf(' ')
    return at <= 0 ? undefined : chord.slice(0, at)
  })
  const first = prefixes[0]
  return first !== undefined && prefixes.every(prefix => prefix === first) ? first : undefined
}

// One `-features --porcelain` record, as _feature_readiness prints it.
export type FeatureRecord = { task: string; ahead: number; state: string }
// Every state _feature_readiness prints (lib/30-worktree.sh).
const FEATURE_STATES = new Set(['ready', 'staged', 'locked', 'dirty', 'untracked', 'vault-locked', 'base-dirty', 'merged'])

// The records of `-features --porcelain`, or what is wrong with the first line
// that is not one: ten tab-separated fields, a whole `ahead`, a known state.
export function parseFeatures(stdout: string): FeatureRecord[] | { unreadable: string } {
  const records: FeatureRecord[] = []
  for (const line of stdout.split('\n')) {
    if (line === '') continue
    const fields = line.split('\t')
    const [task, , ahead, , , , , , , state] = fields
    if (fields.length !== 10 || task === undefined || task === '' || !/^\d+$/.test(ahead ?? '') || !FEATURE_STATES.has(state ?? '')) return { unreadable: line }
    records.push({ task, ahead: Number(ahead), state: state as string })
  }
  return records
}

// A record's state as the band says it: `ready` only with work ahead of the
// base to land.
function stateWord(record: FeatureRecord): string {
  return record.state === 'ready' && record.ahead === 0 ? 'no commits' : record.state
}

// The word for a base's records.
export function featuresWordOf(records: FeatureRecord[]): FeaturesWord | undefined {
  if (records.length === 0) return undefined
  const count = `${records.length} ${records.length === 1 ? 'feature' : 'features'}`
  const ready = records.filter(r => stateWord(r) === 'ready')
  const only = ready[0]
  if (ready.length === 1 && only !== undefined) return { label: `${count} \u00b7 ${cutTask(only.task)} ready`, finish: only.task }
  if (ready.length > 1) return { label: `${count} \u00b7 ${ready.length} ready`, finish: '' }
  const one = records[0]
  if (records.length === 1 && one !== undefined) return { label: `${count} \u00b7 ${cutTask(one.task)} ${stateWord(one)}` }
  return { label: `${count} \u00b7 none ready` }
}

// The hooks do not wait on cs: a base's readiness walks git for every
// feature (1.4 s measured for one), so the band redraws when it answers.
function readFeaturesLater($: EngineInterface) {
  refreshFeatures($).catch(err => $.ui.log(LOGS.featuresUnread(String(err instanceof Error ? err.message : err))))
}

// Asks cs for the session's features and redraws the band when the word
// moved. Only the lead conversation of a base session asks (cs never admits
// `@` in a name it creates, so `@` marks a feature); a reading still running
// is not doubled.
async function refreshFeatures($: EngineInterface) {
  if (featuresReading) return
  featuresReading = true
  try {
    const word = await readFeatures($)
    if (word?.label !== featuresWord?.label || word?.finish !== featuresWord?.finish) {
      featuresWord = word
      $.ui.invalidate('ui.render')
    }
  } finally {
    featuresReading = false
  }
}

async function readFeatures($: EngineInterface): Promise<FeaturesWord | undefined> {
  const bin = await $.env.get("CS_BIN")
  if (!bin || !(await ownsRotation($))) return undefined
  const base = await csSessionName($, await $.session.cwd())
  // A feature (`base@task`) draws no word: /finish lands it from its base,
  // and asked from here cs reads the base conversation's own lock as `locked`.
  if (base === undefined || base.includes('@')) return undefined
  // A base with no `<base>@<task>` directory beside it has no features: cs is
  // not asked, and no clock asks again. /feature runs in the base's own
  // conversation, so the turn it ends in reads the new feature.
  if (!(await hasFeatureDirs($, base))) return undefined
  featuresClock ??= $.clock.every(FEATURES_POLL_MS, () => { if (bandIdle) return refreshFeatures($) })
  let complaint: string | undefined
  let word: FeaturesWord | undefined
  try {
    const result = await $.process.run([bin, base, '-features', '--porcelain'], { timeoutMs: FEATURES_TIMEOUT_MS })
    const parsed = result.exitCode === 0 ? parseFeatures(result.stdout) : undefined
    if (parsed === undefined) {
      complaint = LOGS.featuresExited(base, result.exitCode, result.stderr.split('\n').filter(l => l.trim() !== '').slice(-1)[0] ?? '')
    } else if ('unreadable' in parsed) {
      complaint = LOGS.featuresUnreadable(base, parsed.unreadable)
    } else {
      word = featuresWordOf(parsed)
    }
  } catch (err) {
    complaint = LOGS.featuresNoAnswer(base, String(err instanceof Error ? err.message : err))
  }
  if (complaint !== undefined && complaint !== featuresComplaint) $.ui.log(complaint)
  featuresComplaint = complaint
  return word
}

// The hooks do not wait on a cs fork for its settings: the answer lands in
// fileSettings, and the band redraws when a value moved.
function readSettingsLater($: EngineInterface) {
  void refreshFileSettings($)
}

// Asks cs for its settings, by the path the launch exported; the child
// inherits claude's environment, so cs judges the same pins this process has.
// A failed or unreadable answer keeps the settings last read and is logged
// once until the complaint changes; a read still running is not doubled.
async function refreshFileSettings($: EngineInterface) {
  if (settingsReading) return
  settingsReading = true
  let complaint: string | undefined
  try {
    const bin = await $.env.get("CS_BIN")
    if (!bin) return
    const result = await $.process.run([bin, '-config', 'list', '--porcelain'], { timeoutMs: SETTINGS_TIMEOUT_MS })
    const read = result.exitCode === 0 ? parseFileSettings(result.stdout) : undefined
    if (read === undefined) {
      complaint = LOGS.settingsExited(result.exitCode, result.stderr.split('\n').filter(l => l.trim() !== '').slice(-1)[0] ?? '')
    } else if ('unreadable' in read) {
      complaint = LOGS.settingsUnreadable(read.unreadable)
    } else if (!sameSettings(read, fileSettings)) {
      fileSettings = read
      $.ui.invalidate('ui.render')
    }
  } catch (err) {
    complaint = LOGS.settingsUnread(String(err instanceof Error ? err.message : err))
  } finally {
    settingsReading = false
  }
  if (complaint !== undefined && complaint !== settingsComplaint) $.ui.log(complaint)
  settingsComplaint = complaint
}

const SETTING_SOURCES = new Set(['default', 'machine', 'session', 'shell', 'launch'])

// The porcelain's records: eleven tab-separated fields, the key first, the
// value ninth (`-` for none) and its source tenth. Each value a settings file
// gave (source session or machine) is kept; a record of any other shape makes
// the whole answer unreadable.
function parseFileSettings(text: string): Map<string, string> | { unreadable: string } {
  const settings = new Map<string, string>()
  for (const line of text.split('\n')) {
    if (line === '') continue
    const fields = line.split('\t')
    const [key, , , , , , , , value, source] = fields
    if (fields.length !== 11 || key === undefined || value === undefined || source === undefined || !SETTING_SOURCES.has(source)) return { unreadable: line }
    if ((source === 'session' || source === 'machine') && value !== '-') settings.set(key, value)
  }
  return settings
}

function sameSettings(a: Map<string, string>, b: Map<string, string>): boolean {
  return a.size === b.size && [...a].every(([key, value]) => b.get(key) === value)
}

// Whether the sessions root holds a feature of `base`: cs names each one's
// directory `<base>@<task>` there.
async function hasFeatureDirs($: EngineInterface, base: string): Promise<boolean> {
  const root = await sessionsRoot($)
  if (root === undefined) return false
  let entries: { name: string }[]
  try {
    entries = await $.fs.list(root)
  } catch {
    return false // no sessions root to list: no features
  }
  return entries.some(entry => entry.name.startsWith(`${base}@`))
}

// The prompts the rail draws a bar for, `from` up to but not including
// `to`: those before fold into its `…N` run, those after into its `M…` run.
type RailWindow = { from: number; to: number }

// The bars the rail draws of `count` prompts: the most, up to `most`, that
// fit `budget` cells with their runs, and always the named one. They end at
// the newest prompt, slid back only as far as the named one, where it is the
// first; undefined when not even the named bar fits.
export function railTicks(count: number, budget: number, most: number, named: number): RailWindow | undefined {
  if (!Number.isInteger(named) || named < 0 || named >= count) throw new Error(`cs: the rail named prompt ${named} of ${count}`)
  for (let drawn = Math.min(most, count); drawn >= 1; drawn--) {
    const from = Math.min(count - drawn, named)
    const shown = { from, to: from + drawn }
    if (railCells(count, shown) <= budget) return shown
  }
  return undefined
}

// The rail's least: the named bar alone.
function leastWindow(named: number): RailWindow {
  return { from: named, to: named + 1 }
}

// The cells the rail takes: its bars, and each run with the space between it
// and the bars.
function railCells(count: number, { from, to }: RailWindow): number {
  return foldCells(from) + to - from + foldCells(count - to)
}

// The cells of a run of folded prompts, `…N ` before the bars or ` N…`
// after them, the space included; none when no prompt folds.
function foldCells(folded: number): number {
  return folded > 0 ? `\u2026${folded}`.length + 1 : 0
}

// The prompt the band names: the newest, or the one being read (cs.bandPrompt).
function namedIndex(): number {
  return bandOptions?.prompt === 'read' ? readIndex() : prompts.length - 1
}

// The prompt being read: of the prompts whose drawn row has reported what of
// it is on screen, the one drawn highest (the row cut at the viewport's top
// reports the rows scrolled away as `first`; every other visible row reports
// 0, and of those the earliest prompt is the higher); when none has reported,
// the prompt last read (the reader is inside a reply, its prompt scrolled
// away), else the newest.
function readIndex(): number {
  let best = -1
  let bestFirst = -1
  prompts.forEach((p, i) => {
    const id = requestIdOf(p)
    const report = id === undefined ? undefined : shown.get(id)
    if (report !== undefined && report.first > bestFirst) { best = i; bestFirst = report.first }
  })
  if (best >= 0) return best
  return drawnRead >= 0 && drawnRead < prompts.length ? drawnRead : prompts.length - 1
}

// The id the engine drew a prompt's row under: by the row's uuid (the engine
// keys a message row by its message id; a message split into rows keeps the
// uuid's first four groups), else by the first line's text when no other
// prompt carries it, as a row drawn before the transcript stored it is
// matched (a repeated "continue" would bind every one to the same row);
// undefined while no row has.
function requestIdOf(p: Prompt): string | undefined {
  const byKey = drawnRows.get(rowKey(p.uuid))
  if (byKey !== undefined) return byKey.requestId
  if (prompts.filter(q => q.text === p.text).length > 1) return undefined
  for (const drawn of drawnRows.values()) if (drawn.text === p.text) return drawn.requestId
  return undefined
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const rowKey = (id: string) => (UUID.test(id) ? id.slice(0, 24) : id)

// A prompt's text as the rail carries it: the first non-blank line, trimmed,
// cut to RAIL_TEXT_CHARS with an ellipsis.
// Terminal cells, not UTF-16 length: wide CJK and emoji take two, combining
// marks none, and a cut keeps whole graphemes. The same measure as
// mods/cs-mermaid/hooks/text.ts, for the band's named gap.
const WIDE = /[\u1100-\u115f\u2e80-\u303e\u3041-\u33ff\u3400-\u4dbf\u4e00-\u9fff\ua000-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]|[\u{1F300}-\u{1F64F}]|[\u{1F900}-\u{1F9FF}]|[\u{20000}-\u{3FFFD}]/u
const ZERO = /^[\p{M}\u200b-\u200f\ufe0f]+$/u

function graphemes(text: string): string[] {
  const Segmenter = (Intl as { Segmenter?: new (locale: string, options: { granularity: 'grapheme' }) => { segment(input: string): Iterable<{ segment: string }> } }).Segmenter
  if (!Segmenter) return Array.from(text)
  return Array.from(new Segmenter('en', { granularity: 'grapheme' }).segment(text), piece => piece.segment)
}

function cellsOf(grapheme: string): number {
  if (ZERO.test(grapheme)) return 0
  return WIDE.test(grapheme.replace(/[\p{M}\u200b-\u200f\ufe0f]/gu, '')) ? 2 : 1
}

function cellWidth(text: string): number {
  return graphemes(text).reduce((sum, grapheme) => sum + cellsOf(grapheme), 0)
}

// `text` at most `width` cells wide, ending in `…` when anything was cut; a
// cut that lands after a space drops the space, so the `…` sits on the word.
// A label cut to `cells`, or to its glyph where the cut would land inside the
// queue press's count: `▤ run 1…` of twelve tasks names another number.
function shortened(label: string, cells: number): string {
  const cut = cutToCells(label, cells)
  const count = QUEUE_COUNT.exec(label)?.[0]
  return count !== undefined && cellWidth(cut) <= cellWidth(count) ? cutToCells(label, SHORTEST_CELLS) : cut
}

function cutToCells(text: string, width: number): string {
  if (cellWidth(text) <= width) return text
  let fitted = ''
  let used = 0
  for (const grapheme of graphemes(text)) {
    const cells = cellsOf(grapheme)
    if (used + cells > width - 1) break
    fitted += grapheme
    used += cells
  }
  return `${fitted.trimEnd()}\u2026`
}

// `text` cut to `width` cells, with spaces before it to fill `width`.
function fitRight(text: string, width: number): string {
  const fitted = cutToCells(text, width)
  return ' '.repeat(Math.max(0, width - cellWidth(fitted))) + fitted
}

function firstLine(text: string): string {
  const line = text.split('\n').map(l => l.trim()).find(l => l !== '') ?? ''
  const pieces = graphemes(line)
  return pieces.length > RAIL_TEXT_CHARS ? `${pieces.slice(0, RAIL_TEXT_CHARS - 1).join('')}\u2026` : line
}

// Scrolls the transcript to prompt `i`'s row, from a press or a typed /cs,
// which is when the engine lets a plugin move a transcript row. A refusal
// marks the tick dotted and is toasted once a session; a prompt no row has
// drawn since a resume is tried by its uuid, and a refusal for want of a
// drawn row says so once instead.
async function jumpTo($: EngineInterface, i: number) {
  const p = prompts[i]
  if (p === undefined) return
  const id = requestIdOf(p)
  const result = await $.ui.scroll({ to: { requestId: id ?? p.uuid }, block: 'start' })
  if (result.deny === undefined) {
    if (denied.delete(p.uuid)) $.ui.invalidate('ui.render')
    return
  }
  if (id === undefined && /nothing drawn/.test(result.deny)) {
    if (!notYetSaid) { notYetSaid = true; $.ui.toast(TOASTS.promptNotDrawn) }
    return
  }
  if (!denied.has(p.uuid)) { denied.add(p.uuid); $.ui.invalidate('ui.render') }
  if (!denySaid) { denySaid = true; $.ui.toast(TOASTS.scrollRefused(result.deny)) }
}

// Reads the transcript again when it moved and redraws the band when the
// prompts changed. A file that cannot be read (none yet, or cs is not the
// launcher) lists nothing.
async function refreshRail($: EngineInterface) {
  const path = await transcriptPath($)
  let size: number
  let mtimeMs: number
  try {
    ({ size, mtimeMs } = await $.fs.stat(path))
  } catch {
    if (prompts.length > 0) { prompts = []; $.ui.invalidate('ui.render') }
    railFile = undefined
    return
  }
  if (railFile !== undefined && railFile.path === path && railFile.size === size && railFile.mtimeMs === mtimeMs) return
  let text: string
  try {
    if (size > READ_CAP) {
      // Past what one read may copy, the newest READ_CAP bytes; the cut's
      // partial first line is dropped by the parser.
      text = (await $.process.run(['tail', '-c', String(READ_CAP), path])).stdout
      if (!tailSaid) { tailSaid = true; $.ui.toast(TOASTS.transcriptTail()) }
    } else {
      text = await $.fs.read(path)
    }
  } catch (err) {
    $.ui.log(LOGS.transcriptUnread(String(err instanceof Error ? err.message : err)))
    return
  }
  railFile = { path, size, mtimeMs }
  const next = parsePrompts(text)
  const changed = next.length !== prompts.length || next.some((p, i) => p.uuid !== prompts[i].uuid || p.text !== prompts[i].text)
  prompts = next
  if (changed) $.ui.invalidate('ui.render')
}

// Where Claude Code writes this conversation's transcript, the way cs's own
// _claude_project_dir finds it (lib/40-state.sh): CS_TRANSCRIPTS_DIR, else
// ~/.claude/projects, or the session's own config dir's projects/ when it
// has one (.cs/claude-config, an encrypted session); under that, the cwd as
// resolved with every character outside [A-Za-z0-9] made `-`, then
// <session id>.jsonl.
async function transcriptPath($: EngineInterface): Promise<string> {
  const cwd = await $.session.cwd()
  let base = (await $.env.get("CS_TRANSCRIPTS_DIR")) || `${await $.env.get("HOME")}/.claude/projects`
  if (await $.fs.exists(`${cwd}/.cs/claude-config`)) base = `${cwd}/.cs/claude-config/projects`
  const resolved = (await resolvedPath($, cwd)) ?? cwd
  return `${base}/${resolved.replace(/[^A-Za-z0-9]/g, '-')}/${await $.session.id()}.jsonl`
}

// The person's prompts on the live branch of a transcript's JSONL, in order.
// The live branch is the chain of parents from the last row (a /rewind leaves
// its abandoned rows in the file off that chain; a /compact boundary row
// links on through logicalParentUuid). A prompt is a user row the person
// sent: not a tool result, a slash command's echo, a meta row (hook feedback,
// an image), a compact summary, a sidechain's, one the engine stamped another
// origin, an interrupt the engine wrote for the person, or one framed by a
// tag alone on its first line (a teammate's message, a command's output). A
// line that is not a row (torn, or not JSON) is skipped.
const FRAMED = /^<[A-Za-z][\w:-]*(\s[^>]*)?>(<\/[\w:-]+>)?$|^<[A-Za-z][\w:-]*>[^<]*<\/[\w:-]+>$/
const INTERRUPT = /^\[Request interrupted by user/
export function parsePrompts(jsonl: string): Prompt[] {
  const rows: any[] = []
  for (const line of jsonl.split('\n')) {
    if (line.trim() === '') continue
    try {
      const row = JSON.parse(line)
      if (typeof row?.uuid === 'string') rows.push(row)
    } catch {
      // a torn last line while the engine appends, or not a row
    }
  }
  const byId = new Map(rows.map(row => [row.uuid, row]))
  const live = new Set<string>()
  let row = [...rows].reverse().find(r => !r.isSidechain)
  while (row !== undefined && !live.has(row.uuid)) {
    live.add(row.uuid)
    const parent = row.parentUuid ?? row.logicalParentUuid
    row = typeof parent === 'string' ? byId.get(parent) : undefined
  }
  const out: Prompt[] = []
  for (const r of rows) {
    if (!live.has(r.uuid) || r.type !== 'user' || r.isMeta || r.isCompactSummary || r.isSidechain) continue
    if (r.origin?.kind !== undefined && r.origin.kind !== 'human') continue
    const content = r.message?.content
    let text: string | undefined
    if (typeof content === 'string') text = content
    else if (Array.isArray(content)) {
      if (content.some((b: any) => b?.type === 'tool_result')) continue
      text = content.filter((b: any) => b?.type === 'text' && typeof b.text === 'string').map((b: any) => b.text).join('\n')
    }
    if (text === undefined) continue
    const line = firstLine(text)
    if (line === '' || FRAMED.test(line) || INTERRUPT.test(line)) continue
    out.push({ uuid: r.uuid, text: line })
  }
  return out
}

function numberOr(raw: string | undefined, fallback: number): number {
  return raw !== undefined && /^\d+$/.test(raw.trim()) ? Number(raw.trim()) : fallback
}

// On at FORCE_DEFAULT unless CS_ROTATE_FORCE_CTX says otherwise: `off` (any
// case) and `0` turn the forcing off, a percentage from 1 to 100 moves it, and
// anything else — a typo, or a number past 100 no turn can reach — is the
// default rather than silence, because a value nobody can read must not
// quietly disable a rotation the person is relying on. A settings file's value
// comes first (fileSettings). `claude plugin validate` lists what a module
// reads, and a name it does not spell is refused.
async function forceThreshold($: EngineInterface): Promise<number | undefined> {
  const raw = (fileSettings.get('CS_ROTATE_FORCE_CTX') ?? await $.env.get("CS_ROTATE_FORCE_CTX"))?.trim()
  if (raw === undefined || raw === '') return FORCE_DEFAULT
  if (raw.toLowerCase() === 'off' || /^0+$/.test(raw)) return undefined
  const n = /^\d+$/.test(raw) ? Number(raw) : NaN
  return n >= 1 && n <= 100 ? n : FORCE_DEFAULT
}

// A conversation id the mod has not met yet is the current one from here on,
// and the call says so. It is a birth, to be judged by its first turn's end,
// only when a /clear was seen since the last id; a /resume, a launch or a
// reload adopt unjudged, and an earlier judgment of the same id is dropped
// with them.
async function noteConversation($: EngineInterface, id: string): Promise<boolean> {
  if (id === adopted) return false
  const reapplyColor = adopted !== undefined || clearSeen
  adopted = id
  startPercent = undefined
  birth = clearSeen ? id : undefined
  clearSeen = false
  if (reapplyColor && (await isCsSession($, await $.session.cwd()))) {
    const color = await sessionColor($)
    if (color !== undefined && Object.hasOwn(SESSION_PALETTE, color)) {
      $.command.run({ command: 'color', args: color }).catch(err => {
        $.ui.log(LOGS.colorFailed(color, String(err).replace(/[\r\n]+/g, ' ')))
      })
    }
  }
  return true
}

// Runs /rotate for the person once a turn ends past the force threshold, once
// per conversation, from a timer: the contract refuses `$.command.run` inside
// a hook the turn is waiting on, and a `clock.after` callback runs once the
// hook has returned (measured: a 0 ms timer scheduled in turn.complete ran the
// command). A rejected run is not retried; the button stays for the person.
async function forceRotation($: EngineInterface) {
  const force = await forceThreshold($)
  if (force === undefined) return
  if (!(await ownsRotation($))) return
  const id = await $.session.id()
  const { context } = await $.session.usage()
  await noteConversation($, id)
  if (birth === id) {
    birth = undefined
    startPercent = context.percent
    if (startPercent !== undefined && startPercent >= force) {
      $.ui.toast(TOASTS.forceBelowStart(force, startPercent))
    }
  }
  if (await handoffArmed($)) {
    if (!ticker && (await sessionVetted($, await $.session.cwd()))) startCountdown($)
    return
  }
  if (startPercent !== undefined && startPercent >= force) return
  if (context.percent === undefined || context.percent < force) return
  const cwd = await $.session.cwd()
  if (!(await sessionVetted($, cwd))) return
  const forced = `${cwd}/${FORCED}`
  if ((await $.fs.exists(forced)) && (await $.fs.read(forced)).trim() === id) return
  await $.fs.write(forced, `${id}\n`)
  $.clock.after(0, () => {
    rotate($).catch(err => $.ui.toast(TOASTS.rotateFailed(String(err))))
  })
}

// Counts the band down, one redraw a second (the contract folds calls past
// ten a second). Each redraw re-reads the marker and the handoff: the count
// must see the press and the prompt that stop it, so nothing here is cached.
// At zero the /clear runs only where the band would draw the button: the band
// idle, the handoff still armed, this the lead; otherwise the count stops and
// the button stays for the person.
function startCountdown($: EngineInterface) {
  left = GRACE_SECONDS
  // From a timer: the count starts inside the turn's own hook.
  $.clock.after(0, () => toastNextStep($))
  ticker = $.clock.every(1000, async () => {
    // Nothing to count once stopped, and nothing below zero: a period that
    // lands while the zero tick is still reading leaves the count where it is.
    if (left === undefined || left <= 0) return
    left -= 1
    $.ui.invalidate('ui.render')
    if (left > 0) return
    // The count holds at zero through the reads below: a prompt or a press
    // landing meanwhile stops it (left becomes undefined), and this tick
    // then does nothing, so nothing clears twice or behind a new turn.
    const idle = bandIdle && (await handoffArmed($)) && (await ownsRotation($)) && (await sessionVetted($, await $.session.cwd()))
    if (left !== 0) return
    stopCountdown($)
    if (idle) await clearAndContinue($).catch(err => $.ui.toast(TOASTS.clearFailed(String(err))))
  })
}

function stopCountdown($: EngineInterface) {
  ticker?.cancel()
  ticker = undefined
  left = undefined
  $.ui.invalidate('ui.render')
}

// Toasts the armed handoff's next step for the count that scheduled it, if
// that count still runs and the handoff has not been toasted: what the next
// conversation will do, read while the count runs. A handoff with no next step
// toasts nothing.
async function toastNextStep($: EngineInterface) {
  if (ticker === undefined) return
  const text = await armedHandoff($)
  if (text === undefined || text === stepToastedFor || ticker === undefined) return
  stepToastedFor = text
  const line = nextStepLine(text)
  if (line !== undefined) $.ui.toast(TOASTS.nextStep(line))
}

// How much of the next step the toast carries: one line, cut past this.
export const NEXT_STEP_CHARS = 160

// The first line of the handoff's Next Step section (`# Next Step`, `## 1.
// Next Step`), trimmed, cut to NEXT_STEP_CHARS with an ellipsis; undefined
// when the handoff has no such section or the section is empty. A `#` line
// inside a fenced block (a shell comment in a command block) is the step's
// text, not the next section, and a line that opens or closes a fence is not
// the step's first line.
export function nextStepLine(text: string): string | undefined {
  const lines = text.split('\n')
  const start = lines.findIndex(line => /^#+\s*(\d+\.\s*)?next step\s*$/i.test(line.trim()))
  if (start < 0) return undefined
  let fence: string | undefined
  for (const line of lines.slice(start + 1)) {
    const marker = /^\s*(```|~~~)/.exec(line)?.[1]
    if (marker !== undefined && (fence === undefined || fence === marker)) {
      fence = fence === undefined ? marker : undefined
      continue
    }
    if (fence === undefined && /^#+\s/.test(line)) return undefined
    const first = line.trim()
    if (first === '') continue
    return first.length > NEXT_STEP_CHARS ? `${first.slice(0, NEXT_STEP_CHARS)}\u2026` : first
  }
  return undefined
}

// The band's own threshold; without one it is the bar's warn band, read the way
// the bar reads it. A settings file's value comes first (fileSettings). Each
// variable's name is a literal: `claude plugin validate` lists what a module
// reads, and a name it does not spell is refused.
async function threshold($: EngineInterface): Promise<number> {
  return numberOr(
    fileSettings.get('CS_ROTATE_BUTTON_CTX') ?? await $.env.get("CS_ROTATE_BUTTON_CTX"),
    numberOr(fileSettings.get('CS_STATUSLINE_CTX_WARN') ?? await $.env.get("CS_STATUSLINE_CTX_WARN"), DEFAULT_PERCENT),
  )
}

// A handoff name the SessionStart hook loads: letters, digits and ._@-, at
// most 160 characters, so never one with a separator.
const PLAIN_NAME = /^[A-Za-z0-9._@-]{1,160}$/

// Armed means the marker names a handoff the SessionStart hook will accept
// after the /clear: a plain basename (PLAIN_NAME), a file in the store, and
// frontmatter that still says unconsumed. Whether cs trusts the
// session's control files is asked apart (sessionVetted), by each step that
// acts on the handoff, never by the band's drawing. A marker an aborted
// rotation left behind, or one naming a handoff since consumed, would offer a
// /clear that lands in a conversation with nothing to continue from, so it
// does not arm. One exists per render; the reads only while the marker is there.
async function handoffArmed($: EngineInterface): Promise<boolean> {
  return (await armedHandoff($)) !== undefined
}

// The armed handoff's text, read under the rule above; undefined when unarmed.
// Each marker names a handoff in its own store only: the vault's marker never
// arms from the plaintext store, nor the reverse. The marker is read rather
// than probed for, as queueRunning does: a read follows the .cs/private link
// the way the hook's own does, and a marker that cannot be read (absent, or
// behind a locked vault) arms nothing.
async function armedHandoff($: EngineInterface): Promise<string | undefined> {
  const cwd = await $.session.cwd()
  for (const [marker, store] of [[PRIVATE_MARKER, PRIVATE_HANDOFFS], [MARKER, HANDOFFS]]) {
    let name: string
    try {
      // The hook reads the marker with tr -d '[:space:]', which in the C
      // locale drops ASCII whitespace anywhere in it and keeps every other
      // character. This drops that same set.
      name = (await $.fs.read(`${cwd}/${marker}`)).replace(/[\t\n\v\f\r ]/g, '')
    } catch {
      continue
    }
    if (!PLAIN_NAME.test(name)) return undefined
    try {
      const text = await $.fs.read(`${cwd}/${store}/${name}`)
      return isUnconsumed(text) ? text : undefined
    } catch {
      return undefined
    }
  }
  return undefined
}

// Whether cs trusts the session's control files, by cs's own rule (the one
// SessionStart, the Stop hook and the queue verbs ask): while git tracks a
// file in .cs/local or .cs/private, a pull can put a marker there, and the
// SessionStart hook refuses the rotation it names. An answer cs cannot give
// is a no. Each new refusal is toasted once. Each answer starts a cs process
// (0.15-0.44 s measured), so only the steps that act ask: the session start's
// heartbeat, a countdown's start and zero, a forced /rotate, a press of the
// clear, rotate or feed button, and the emptying of the wrap marker
// (clearWrapped, as a prompt starts a turn) and of the press marker
// (clearPressed, at a main-loop turn's end or when the engine refuses the
// press's run).
async function sessionVetted($: EngineInterface, cwd: string): Promise<boolean> {
  const bin = await $.env.get("CS_BIN")
  let refusal: string | undefined
  if (!bin) {
    refusal = 'the launch did not say where cs is (CS_BIN)'
  } else {
    try {
      const result = await $.process.run([bin, '-vet-session', cwd], { timeoutMs: VET_TIMEOUT_MS })
      if (result.exitCode !== 0) {
        refusal = result.stderr.split('\n').filter(l => l.trim() !== '').slice(-1)[0] ?? `cs -vet-session exited ${result.exitCode}`
      }
    } catch (err) {
      refusal = `cs -vet-session did not run: ${String(err instanceof Error ? err.message : err)}`
    }
  }
  if (refusal !== undefined && refusal !== lastRefusal) $.ui.toast(TOASTS.noRotation(refusal))
  lastRefusal = refusal
  feedVetRefused = refusal !== undefined
  return refusal === undefined
}

// The hook's own rule (_handoff_is_unconsumed in hooks/session-start.sh): a
// frontmatter block opened by `---` on the first line and CLOSED by the next
// `---`, carrying `status: unconsumed` between them. A file the closing line
// never reaches (a truncated write) is not armed: the hook would refuse it,
// and a /clear on it would land in a conversation with nothing to continue.
export function isUnconsumed(text: string): boolean {
  const lines = text.split('\n')
  if (lines[0] !== '---') return false
  let matched = false
  for (const line of lines.slice(1)) {
    if (line === '---') return matched
    if (line === 'status: unconsumed') matched = true
  }
  return false
}

// The count's colour for this session and terminal, a settings file's
// background and theme first. Each name is a literal: `claude plugin validate`
// lists what a module reads.
async function rampColor($: EngineInterface, secs: number): Promise<string | undefined> {
  return countdownColor(secs, await sessionColor($), fileSettings.get('CS_TERM_BG_RGB') ?? await $.env.get("CS_TERM_BG_RGB"), fileSettings.get('CS_TERM_THEME') ?? await $.env.get("CS_TERM_THEME"))
}

// The session's colour name as cs recorded it in state, or undefined.
async function sessionColor($: EngineInterface): Promise<string | undefined> {
  const state = await readState($)
  return state?.match(/^claude_session_color: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
}

// The engine actions the rotate and wrap Buttons answer to. They carry no default
// chord and no engine handler is mounted for them (measured on 2.1.291 and
// 2.1.292), so the chord a person binds to one presses the Button. The band
// depends on that: a Claude Code that mounts a handler for either action
// takes Ctrl+X 1 or Ctrl+X 2 from the band without a word. KEEP IN SYNC with
// CS_ROTATE_WRAP_KEYS in lib/01-manifests.sh, which binds them.
export const ROTATE_ACTION = 'strip:jump1'
export const WRAP_ACTION = 'strip:jump2'
export const FEED_ACTION = 'strip:jump3'

async function readFeed($: EngineInterface): Promise<boolean> {
  let complaint: string | undefined
  try {
    // Writes are non-atomic: only the whole on line counts. Trimming would
    // accept a torn write without its newline; every other value is off.
    const text = await $.fs.read(`${await $.session.cwd()}/.cs/local/feed`)
    feedComplaint = undefined
    return text === 'on\n'
  } catch (err) {
    const message = String(err instanceof Error ? err.message : err)
    if (!message.endsWith(' failed: ENOENT')) complaint = LOGS.feedUnread(message)
  }
  if (complaint !== undefined && complaint !== feedComplaint) $.ui.log(complaint)
  feedComplaint = complaint
  return false
}

async function pressFeed($: EngineInterface) {
  if (feedPressPending !== undefined) return feedPressPending
  const pending = (async () => {
    try {
      const cwd = await $.session.cwd()
      if (!(await sessionVetted($, cwd))) return
      const on = !(await readFeed($))
      await $.fs.write(`${cwd}/.cs/local/feed`, on ? 'on\n' : 'off\n')
    } catch (err) {
      $.ui.toast(TOASTS.feedFailed(String(err instanceof Error ? err.message : err)))
    } finally {
      $.ui.invalidate('ui.render')
    }
  })()
  feedPressPending = pending
  try {
    await pending
  } finally {
    if (feedPressPending === pending) feedPressPending = undefined
  }
}

// The chord keybindings.json binds to each action in the Global context, as
// the person wrote it. Claude Code reads that file from CLAUDE_CONFIG_DIR, else
// ~/.claude; an encrypted session's config dir holds a link to the shell's
// file, so this reads the file Claude Code reads. An unreadable or malformed
// file, or a key unbound with null, binds nothing.
async function boundChords($: EngineInterface): Promise<Record<string, string>> {
  const dir = (await $.env.get("CLAUDE_CONFIG_DIR")) || `${await $.env.get("HOME")}/.claude`
  let doc: any
  try {
    doc = JSON.parse(await $.fs.read(`${dir}/keybindings.json`))
  } catch {
    return {} // no file, or not JSON: no chord to spell
  }
  const chords: Record<string, string> = {}
  for (const block of Array.isArray(doc?.bindings) ? doc.bindings : []) {
    if (block?.context !== 'Global' || typeof block.bindings !== 'object' || block.bindings === null) continue
    for (const [chord, action] of Object.entries(block.bindings)) {
      if (typeof action === 'string' && chords[action] === undefined) chords[action] = chord
    }
  }
  return chords
}

async function readState($: EngineInterface): Promise<string | undefined> {
  try {
    return await $.fs.read(`${await $.session.cwd()}/.cs/local/state`)
  } catch {
    return undefined // no state: not a session cs launched
  }
}

// KEEP IN SYNC with isCsSession and resolvedPath in mods/cs-update (the two
// mods deploy as separate plugins and share no module).
// Whether directory `cwd` is a cs session. Nothing inside a directory can
// prove it: a cloned repository may carry any file under .cs/, .cs/local
// included. The sessions root ($CS_SESSIONS_ROOT, else ~/.claude-sessions) is
// what a clone cannot carry: the directory is a session when the root's entry
// under its own name, or under the session_name an adopted session's state
// records, lands on the directory itself. The recorded name is only a
// candidate, so it may not reach outside the root. Identity is by resolved
// path, as the hooks compare by inode: a link at the root and a home reached
// through a symlink each spell the same directory another way.
async function isCsSession($: EngineInterface, cwd: string): Promise<boolean> {
  return (await csSessionName($, cwd)) !== undefined
}

// The name under which the sessions root holds directory `cwd`, by the rule
// isCsSession states; undefined when it holds it under none.
async function csSessionName($: EngineInterface, cwd: string): Promise<string | undefined> {
  const root = await sessionsRoot($)
  if (root === undefined) return undefined
  const here = await resolvedPath($, cwd)
  if (here === undefined) return undefined
  const dir = cwd.replace(/\/+$/, '')
  const names = [dir.slice(dir.lastIndexOf('/') + 1)]
  let state = ''
  try {
    state = await $.fs.read(`${cwd}/.cs/local/state`)
  } catch {
    // no state: only the directory's own name is a candidate
  }
  const recorded = state.match(/^session_name: *"?([^"\s/]+)"?[ \t]*$/m)?.[1]
  if (recorded !== undefined && recorded !== '.' && recorded !== '..') names.push(recorded)
  for (const name of names) {
    if ((await resolvedPath($, `${root}/${name}`)) === here) return name
  }
  return undefined
}

// $CS_SESSIONS_ROOT, else ~/.claude-sessions; undefined with neither set.
async function sessionsRoot($: EngineInterface): Promise<string | undefined> {
  const home = await $.env.get('HOME')
  return (await $.env.get('CS_SESSIONS_ROOT')) || (home ? `${home}/.claude-sessions` : undefined)
}

// Where `path` lands once every link is followed; undefined when it leads
// nowhere or cannot be read, which proves nothing about a session.
async function resolvedPath($: EngineInterface, path: string): Promise<string | undefined> {
  try {
    return (await $.fs.stat(path, { resolve: true })).realPath
  } catch {
    return undefined
  }
}

// Only the lead conversation of a cs session may be offered a rotation, or the
// queue's start key: the Stop hook drains on the lead's turns alone. The
// rotate skill refuses outside a cs session, .cs/local/disabled opts a
// directory out of cs entirely, and the handoff it writes carries the UUID in
// .cs/local/state, which belongs to the one conversation cs launched: a
// teammate claude in the same directory would arm the lead's marker under the
// lead's identity. The checks run only once the band has a button to draw.
// The value may be quoted and may carry trailing spaces, as cs's own state
// readers allow.
async function ownsRotation($: EngineInterface): Promise<boolean> {
  const cwd = await $.session.cwd()
  const local = `${cwd}/.cs/local`
  if (!(await $.fs.exists(local)) || (await $.fs.exists(`${local}/disabled`))) return false
  if (!(await isCsSession($, cwd))) return false
  const state = await readState($)
  if (state === undefined) return false
  const lead = state.match(/^claude_session_id: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
  return lead !== undefined && lead === (await $.session.id())
}

// The features word's press: /finish as if typed, on the one feature ready,
// or bare ('') to list them and ask which.
// The word keeps no press after one: the next answer from cs gives it back.
async function pressFinish($: EngineInterface, task: string) {
  if (featuresWord !== undefined) featuresWord = { label: featuresWord.label }
  $.ui.invalidate('ui.render')
  await $.command.run({ command: 'finish', args: task }).catch(err => {
    $.ui.toast(TOASTS.finishFailed(task, String(err instanceof Error ? err.message : err)))
  })
}

// Runs the rotate skill as if the person had typed /rotate: the skill draws
// the purpose from the conversation itself.
async function rotate($: EngineInterface) {
  await $.command.run({ command: 'rotate', args: '' })
}

// The rotate button's press. The skill ends by arming a marker in .cs/local,
// so the press asks cs first, as the forced /rotate does before it runs. It
// then names the conversation in PRESSED for the rotation to read; a run the
// engine refuses runs no turn, so the press empties it again itself.
async function pressRotate($: EngineInterface) {
  const cwd = await $.session.cwd()
  if (!(await sessionVetted($, cwd))) return
  await $.fs.write(`${cwd}/${PRESSED}`, `${await $.session.id()}\n`)
  try {
    await rotate($)
  } catch (err) {
    await clearPressed($)
    throw err
  }
}

// Empties PRESSED while it names this conversation. A marker git tracks stays
// as git has it, like every control file then. One that cannot be emptied
// would make a later typed /rotate read as pressed, so that is said, and the
// caller goes on.
async function clearPressed($: EngineInterface) {
  const cwd = await $.session.cwd()
  let marker: string
  try {
    marker = (await $.fs.read(`${cwd}/${PRESSED}`)).trim()
  } catch {
    return // no press has been made here
  }
  if (marker === '' || marker !== (await $.session.id())) return
  if (!(await sessionVetted($, cwd))) return
  await $.fs.write(`${cwd}/${PRESSED}`, '')
    .catch(err => $.ui.toast(TOASTS.pressedNotEmptied(String(err))))
}

// /wrap's last pass writes WRAPPED naming the conversation it ran in
// (CLAUDE_CODE_SESSION_ID, so a teammate's wrap names the teammate), so a wrap
// that finished is the conversation's latest act and the key has nothing to
// offer. The next turn started from a prompt clears it. A summary written any
// other way proves nothing.
async function wrapFinished($: EngineInterface): Promise<boolean> {
  const marker = await readWrapped($)
  return marker !== '' && marker === (await $.session.id())
}

async function clearWrapped($: EngineInterface) {
  const marker = await readWrapped($)
  if (marker === '' || marker !== (await $.session.id())) return
  // A marker git tracks stays as git has it, like every control file then.
  if (!(await sessionVetted($, await $.session.cwd()))) return
  await $.fs.write(`${await $.session.cwd()}/${WRAPPED}`, '').catch(() => {})
}

async function readWrapped($: EngineInterface): Promise<string> {
  try {
    return (await $.fs.read(`${await $.session.cwd()}/${WRAPPED}`)).trim()
  } catch {
    return '' // no wrap has finished here
  }
}

// `2` asks before running /wrap: it replaces .cs/summary.md and runs two Opus
// passes before the narrative rotation, so a key that may have been meant for
// the composer opens the engine's own dialog rather than acting on the press.
async function askToWrap($: EngineInterface) {
  let answer: string
  try {
    answer = await $.ui.ask(ASKS.wrap.question, { header: ASKS.wrap.header, options: ASKS.wrap.options })
  } catch {
    return // dismissed, or a `-p` run with nobody to ask
  }
  if (answer !== WRAP_YES) return
  try {
    await $.command.run({ command: 'wrap', args: '' })
  } catch (err) {
    $.ui.toast(TOASTS.wrapFailed(String(err)))
  }
}

// An armed or draining queue is already on its way; only bin/cs and the Stop
// hook write the file, and no file is an idle queue.
// An encrypted session keeps its queue behind .cs/private (a link into its
// vault), every other session in .cs/local. A file that cannot be read (absent,
// or behind a locked vault) says nothing about the queue.
async function queueRunning($: EngineInterface): Promise<boolean> {
  const cwd = await $.session.cwd()
  for (const dir of ['private', 'local']) {
    let state: string
    try {
      state = (await $.fs.read(`${cwd}/.cs/${dir}/queue.state`)).trim()
    } catch {
      continue
    }
    return state === 'armed' || state === 'draining'
  }
  return false
}

// How many tasks are queued, whether or not the queue runs them; 0 when it is
// empty or cannot be read. The queue is one file per task, behind .cs/private
// in an encrypted session (where a locked vault lists nothing) and in
// .cs/local otherwise.
async function queueLength($: EngineInterface): Promise<number> {
  const cwd = await $.session.cwd()
  const dir = (await $.fs.exists(`${cwd}/.cs/private`)) ? 'private' : 'local'
  let entries: { kind: string }[]
  try {
    entries = await $.fs.list(`${cwd}/.cs/${dir}/queue`)
  } catch {
    return 0 // no queue directory: nothing queued
  }
  return entries.filter(entry => entry.kind === 'file').length
}

// How many mails wait unread: cs delivers each as one .json file in the
// session's mailbox new/, where it stays until `cs -msg` reads it. The
// mailbox sits behind .cs/private in an encrypted session (where a locked
// vault lists nothing) and in .cs/local otherwise; 0 when it cannot be read.
// Should the engine call a locked vault's dangling link absent, .cs/local is
// listed instead, where cs writes no mail beside that link: 0 again.
async function unreadMail($: EngineInterface): Promise<number> {
  const cwd = await $.session.cwd()
  const dir = (await $.fs.exists(`${cwd}/.cs/private`)) ? 'private' : 'local'
  let entries: { name: string; kind: string }[]
  try {
    entries = await $.fs.list(`${cwd}/.cs/${dir}/mail/new`)
  } catch {
    return 0 // no mailbox: no mail
  }
  return entries.filter(entry => entry.kind === 'file' && entry.name.endsWith('.json')).length
}

// How many tasks are queued while nothing runs them; 0 when the queue is
// armed or draining, empty, or cannot be read.
async function idleQueueLength($: EngineInterface): Promise<number> {
  const count = await queueLength($)
  if (count === 0 || (await queueRunning($))) return 0
  return count
}

// The start key's press: the offer bare /queue makes, for the tasks queued
// now. A queue started or emptied since the band drew is left alone.
async function pressQueueStart($: EngineInterface) {
  const bin = await $.env.get("CS_BIN")
  if (!bin) {
    $.ui.toast(TOASTS.queueNoBin)
    return
  }
  const count = await idleQueueLength($)
  if (count > 0) await offerToStart($, bin, count)
}

// Asked after bare /queue has printed the list, so the tasks are on screen
// when the question is, and by the band's start key. Start arms the queue; Not
// yet leaves it as it is, and the band keeps offering its start key.
// Compact compacts the conversation first, then starts as Start does; a
// compaction that does not happen leaves the queue unarmed. Start and Compact
// then ask how the tasks run, before any compaction, so a dismissed second
// question starts and compacts nothing.
async function offerToStart($: EngineInterface, bin: string, count: number) {
  let answer: string
  try {
    const start = ASKS.queueStart(count)
    answer = await $.ui.ask(start.question, { header: start.header, options: start.options })
  } catch {
    return // dismissed, or a `-p` run with nobody to ask
  }
  if (answer !== QUEUE_START && answer !== QUEUE_COMPACT) return
  let how: string
  try {
    how = await $.ui.ask(ASKS.queueMode.question, { header: ASKS.queueMode.header, options: ASKS.queueMode.options })
  } catch {
    return
  }
  const mode = QUEUE_MODE_WORDS[how]
  if (mode === undefined) {
    // Free text typed under "Other" names no mode cs knows.
    $.ui.toast(TOASTS.queueModeUnknown(how))
    return
  }
  if (answer === QUEUE_COMPACT) {
    let reason: string | undefined
    try {
      const compacted = await $.session.compact()
      reason = 'skip' in compacted ? compacted.skip : undefined
    } catch (err) {
      reason = String(err instanceof Error ? err.message : err)
    }
    if (reason !== undefined) {
      $.ui.toast(TOASTS.notCompacted(reason))
      return
    }
  }
  let result: { exitCode: number; stdout: string; stderr: string }
  try {
    result = await $.process.run([bin, '-queue', 'start', ...mode])
  } catch (err) {
    $.ui.toast(TOASTS.queueStartFailed(String(err instanceof Error ? err.message : err)))
    return
  }
  if (result.exitCode !== 0) {
    const tail = result.stderr.split('\n').filter(l => l.trim() !== '').slice(-1)[0] ?? ''
    $.ui.toast(TOASTS.queueStartExited(result.exitCode, tail))
    return
  }
  if (turnRunning) return
  try {
    await $.prompt.submit({ text: QUEUE_KICK })
  } catch (err) {
    $.ui.toast(TOASTS.queueKickFailed(String(err instanceof Error ? err.message : err)))
  }
}

// The clear button's press: the /clear runs only once cs says it trusts the
// session's control files, as at a countdown's zero. The press stops the count
// before it asks, so the zero tick cannot clear while cs answers, and only the
// latest press acts.
async function pressClear($: EngineInterface) {
  if (clearing) return
  if (ticker) stopCountdown($)
  const press = ++pressCount
  const vetted = await sessionVetted($, await $.session.cwd())
  if (press !== pressCount) return
  if (!vetted) return stopCountdown($)
  await clearAndContinue($)
}

// /clear ends this conversation, and cs's SessionStart hook then starts the
// armed handoff's next step in the new one.
// Measured: the run resolves once the screen has cleared and a new transcript
// is open; the marker is the hook's to consume. From the count stopping to
// the run nothing here waits: a prompt landing in such a wait would find no
// count to stop, and the /clear would follow it.
async function clearAndContinue($: EngineInterface) {
  clearSeen = true
  if (ticker) stopCountdown($)
  clearing = true
  try {
    await $.command.run({ command: 'clear', args: '' })
  } catch (err) {
    clearSeen = false
    throw err
  } finally {
    clearing = false
  }
}

// Starts the /finish watch. Whatever the record holds now belongs to an
// earlier run, so its steps count as shown: only what this /finish writes is
// toasted.
async function watchFinish($: EngineInterface) {
  const before = await readFinish($)
  if (before !== undefined) {
    finishShown.add(`${before.id}:started`)
    finishShown.add(`${before.id}:${before.step}`)
  }
  finishWatch = $.clock.every(FINISH_POLL_MS, () => followFinish($))
}

// One read of the record: toast a run's start and its outcome once each, keep
// the band's gate while a gate runs under a live pid, and end the watch once
// the turn is over with nothing running. A step whose pid is gone was left by
// a run that was killed: it is over, whatever it says.
async function followFinish($: EngineInterface) {
  const record = await readFinish($)
  let live = false
  let gate: typeof finishGate
  if (record !== undefined) {
    const outcome = FINISH_OUTCOMES.has(record.step)
    const key = `${record.id}:${outcome ? record.step : 'started'}`
    if (!finishShown.has(key)) {
      finishShown.add(key)
      $.ui.toast(finishToast(record))
    }
    live = !outcome && (await pidAlive($, record.pid))
    if (live && record.step === 'gate' && record.gate_started !== undefined) gate = { task: record.task, since: record.gate_started }
  }
  // While the band shows, every read redraws it: its elapsed time moves.
  if (gate !== undefined || finishGate !== undefined) $.ui.invalidate('ui.render')
  finishGate = gate
  if (finishTurnOver && !live) {
    finishWatch?.cancel()
    finishWatch = undefined
  }
}

// The toast for a record: the run starting, or its outcome.
export function finishToast(record: FinishRecord): string {
  const task = cutTask(record.task)
  switch (record.step) {
    case 'landed': return `landed ${task} ${record.sha.slice(0, 7)} -> ${(record.result ?? '').slice(0, 7)}`
    case 'refused': return `/finish ${task} refused: ${record.reason ?? ''}`
    case 'retired': return `retired ${task}`
    default: return `finishing ${task}`
  }
}

// The record as cs wrote it, from the vault's store first, as queueRunning
// reads; undefined when there is none. One cs did not write (hand-edited, or
// from another version) is said once and otherwise read as no record, since
// the watch would only repeat the complaint every second.
async function readFinish($: EngineInterface): Promise<FinishRecord | undefined> {
  const cwd = await $.session.cwd()
  for (const dir of ['private', 'local']) {
    let text: string
    try {
      text = await $.fs.read(`${cwd}/.cs/${dir}/${FINISH_RECORD}`)
    } catch {
      continue // absent, or behind a locked vault
    }
    const record = parseFinish(text)
    if (record === undefined) finishProblem($, TOASTS.finishRecordUnread(dir))
    return record
  }
  return undefined
}

export function parseFinish(text: string): FinishRecord | undefined {
  let r: unknown
  try {
    r = JSON.parse(text)
  } catch {
    return undefined
  }
  if (typeof r !== 'object' || r === null) return undefined
  const o = r as Record<string, unknown>
  if (typeof o.id !== 'string' || typeof o.task !== 'string' || typeof o.sha !== 'string' || typeof o.step !== 'string') return undefined
  if (typeof o.pid !== 'number' || !Number.isInteger(o.pid) || o.pid <= 0) return undefined
  if (o.gate_started !== undefined && typeof o.gate_started !== 'number') return undefined
  if (o.step === 'landed' && typeof o.result !== 'string') return undefined
  if (o.step === 'refused' && typeof o.reason !== 'string') return undefined
  return {
    id: o.id, pid: o.pid, task: o.task, sha: o.sha, step: o.step,
    gate_started: o.gate_started as number | undefined,
    result: typeof o.result === 'string' ? o.result : undefined,
    reason: typeof o.reason === 'string' ? o.reason : undefined,
  }
}

// Whether the cs process that wrote a step still runs: `kill -0` sends no
// signal, it only asks. A check that cannot run is said once and counts as
// not running, so a band never outlives what it stands for.
async function pidAlive($: EngineInterface, pid: number): Promise<boolean> {
  try {
    return (await $.process.run(['kill', '-0', String(pid)])).exitCode === 0
  } catch (err) {
    finishProblem($, TOASTS.finishPidUnknown(String(err instanceof Error ? err.message : err)))
    return false
  }
}

function finishProblem($: EngineInterface, toast: string) {
  if (finishProblemShown) return
  finishProblemShown = true
  $.ui.toast(toast)
}

// The time since a gate started, as the band shows it: 42s, 1m 05s.
export function gateElapsed(secs: number): string {
  if (secs < 60) return `${secs}s`
  return `${Math.floor(secs / 60)}m ${String(secs % 60).padStart(2, '0')}s`
}

// The band's word while a /finish gate runs: the task and the time since
// the gate started; undefined at any other time.
async function gateWord($: EngineInterface): Promise<string | undefined> {
  if (finishGate === undefined) return undefined
  const secs = Math.max(0, Math.floor((await $.clock.now()) / 1000) - finishGate.since)
  return `finishing ${cutTask(finishGate.task)} \u00b7 gate ${gateElapsed(secs)}`
}
