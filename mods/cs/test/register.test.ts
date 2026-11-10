// ABOUTME: Unit tests for the cs mod against a fake engine `$`.
// ABOUTME: Covers the band's gate (crit, working, survey), the three presses and the wrap key's two-press guard, the armed handoff and its next-step toast, the heartbeat, /queue, and the /finish toasts and gate word.
import { test, expect, beforeEach } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { labels as filterChatLabels } from '../../cs-filter-chat/hooks/words.ts'

// The plugin realm provides `h` and `Fragment` as globals; the test does the same.
;(globalThis as any).h = (type: any, props: any, ...children: any[]) => ({ type, props: props ?? {}, children })
;(globalThis as any).Fragment = 'Fragment'

import { register, buildBandEntries, drawBand, fitBand, entriesAt, drawFooterKeys, keysRoute, isCycleHint, noticeCells, parseStatusWidth, modesWidth, keysWidth, STATUS_WIDTH, FOOTER_POLL_MS, FILTER_CHAT_MODE, type BandView, parsePrompts, RAIL_TEXT_CHARS, DEFAULT_PERCENT, GRACE_SECONDS, NEXT_STEP_CHARS, WRAP_QUESTION, WRAP_YES, QUEUE_START, QUEUE_COMPACT, QUEUE_KICK, QUEUE_MODE_QUESTION, QUEUE_HERE, QUEUE_SUBAGENTS, QUEUE_WORKFLOWS, nextStepLine, isUnconsumed, TOASTS, LOGS, REPLIES, finishToast, parseFeatures, featuresWordOf } from '../hooks/register.tsx'

type Hook = ($: any, e: any, next: (e: any) => Promise<any>) => Promise<any>
const hooks: Record<string, Hook> = {}
const on = (event: string, a: any, b?: any) => {
  const matcher = b ? a : undefined
  const fn: Hook = b ?? a
  const narrowed = matcher?.component ?? matcher?.command ?? matcher?.skill
  hooks[narrowed ? `${event}:${narrowed}` : event] = fn
}

let percent: number | undefined
let filled: any[]
let ran: any[]
let written: Record<string, string>
// Directories `$.fs.exists` finds and `$.fs.stat` answers, beside the files.
let existing: Set<string>
// Symbolic links whose target is gone: `$.fs.exists` misses one, as it follows
// the link, and `$.fs.stat` answers the link itself.
let danglingLinks: Set<string>
let files: Record<string, string>
let sessionId: string
let envVars: Record<string, string | undefined>
// The conversation's working directory, and where each path lands as `$.fs.stat` resolves it
// (a path absent here does not exist).
let cwdPath: string
let realPaths: Record<string, string>
let timers: { ms: number; fn: () => void; kind: 'after' | 'every'; cancelled: boolean }[]
let invalidated: string[]
let toasts: string[]
let logs: string[]
let asks: { question: string; options: any }[]
// Every pane call the mod makes: it opens, closes and lists none.
let panes: { op: 'open' | 'close' | 'panes'; args?: any }[]
// What the person does with the next dialog: a label, or a rejection (dismissed, or a `-p` run).
let answer: string | Error
// What the person answers to the queue's "how should the tasks run" question.
let modeAnswer: string | Error
// What `$.process.run` was asked to run, and what it answers with (or rejects with).
let runs: { argv: string[]; init: any }[]
let runResult: { exitCode: number; stdout: string; stderr: string } | Error
// Answers for the next runs in order, ahead of runResult; empty means runResult answers.
let nextRuns: ({ exitCode: number; stdout: string; stderr: string } | Error)[]
// Each `cs -config list --porcelain` the mod ran, apart from `runs`, and what it answers with (or rejects with).
let settingsRuns: string[][]
let settingsResult: { exitCode: number; stdout: string; stderr: string } | Promise<{ exitCode: number; stdout: string; stderr: string }> | Error
// What `$.prompt.submit` was handed.
let submitted: any[]
// How many process runs had happened when `$.session.compact` was called, and what it answers with (or rejects with).
let compactedAt: number[]
let compactResult: any
let commands: any[]
let availableCommands: { name: string; source: string; plugin?: string }[]
// What `$.ui.scroll` was asked, and what it answers; the paths `$.fs.read` was given; each file's mtime.
let scrolls: any[]
let scrollResult: any
let reads: string[]
let mtimes: Record<string, number>
// The clock `$.clock.now` reads, and the pids `kill -0` finds alive.
let nowMs: number
let livePids: Set<string>
// The pid a process the mod runs reports as its parent: this Claude Code's.
let claudePid: string | Error
const timer = (kind: 'after' | 'every') => (ms: number, fn: () => void) => {
  const t = { ms, fn, kind, cancelled: false }
  timers.push(t)
  return { cancel: () => { t.cancelled = true } }
}
const $ = {
  env: { get: async (name: string) => envVars[name] },
  session: {
    usage: async () => ({ context: { percent } }),
    cwd: async () => cwdPath,
    id: async () => sessionId,
    compact: async () => {
      compactedAt.push(runs.length)
      if (compactResult instanceof Error) throw compactResult
      return compactResult
    },
  },
  prompt: {
    fill: async (args: any) => { filled.push(args); return { isFilled: true } },
    submit: async (args: any) => { submitted.push(args); return {} },
  },
  command: {
    list: async () => availableCommands,
    run: async (args: any) => { ran.push(args); return { text: '' } },
    register: async (spec: any) => { commands.push(spec); return { command: spec.name } },
  },
  process: {
    run: async (argv: string[], init: any) => {
      if (argv[0] === 'kill' && argv[1] === '-0') return { exitCode: livePids.has(argv[2]) ? 0 : 1, stdout: '', stderr: '' }
      if (argv[0] === '/bin/sh' && argv[2] === 'echo $PPID') {
        if (claudePid instanceof Error) throw claudePid
        return { exitCode: 0, stdout: `${claudePid}\n`, stderr: '' }
      }
      if (argv[1] === '-config') {
        settingsRuns.push(argv)
        if (settingsResult instanceof Error) throw settingsResult
        return settingsResult
      }
      runs.push({ argv, init })
      const r = nextRuns.length > 0 ? nextRuns.shift()! : runResult
      if (r instanceof Error === false && r.exitCode === 0 && argv[2] === '-config' && argv[3] === 'set') files[`${cwdPath}/.cs/local/config`] = `${argv[4]}=${argv[5]}\n`
      if (r instanceof Error) throw r
      return r
    },
  },
  ui: {
    resolve: async () => ({ Box: 'Box', Text: 'Text', Button: 'Button' }),
    invalidate: (event: string) => { invalidated.push(event) },
    toast: (text: string) => { toasts.push(text) },
    scroll: async (args: any) => { scrolls.push(args); return scrollResult },
    log: (text: string) => { logs.push(text) },
    open: async (args: any) => { panes.push({ op: 'open', args }) },
    close: async (args: any) => { panes.push({ op: 'close', args }) },
    panes: async () => { panes.push({ op: 'panes' }); return [] },
    ask: async (question: string, options: any) => {
      asks.push({ question, options })
      const reply = question === QUEUE_MODE_QUESTION ? modeAnswer : answer
      if (reply instanceof Error) throw reply
      return reply
    },
  },
  clock: { after: timer('after'), every: timer('every'), now: async () => nowMs },
  fs: {
    write: async (path: string, text: string) => { written[path] = text; files[path] = text },
    exists: async (path: string) => existing.has(path) || path in files,
    read: async (path: string) => { reads.push(path); if (path in files) return files[path]; throw new Error(`cs: $.fs.read(${path}) failed: ENOENT`) },
    // A directory is listed from the files under it, a deeper file standing
    // for the directory that holds it; one with none is absent.
    list: async (path: string) => {
      const prefix = `${path.replace(/\/+$/, '')}/`
      const under = Object.keys(files).filter(k => k.startsWith(prefix)).map(k => k.slice(prefix.length))
      if (under.length === 0) throw new Error(`ENOENT ${path}`)
      const names = [...new Set(under.map(rest => rest.split('/')[0]))]
      return names.map(name => under.includes(name)
        ? { name, kind: 'file', size: files[prefix + name].length, isLink: false }
        : { name, kind: 'directory', size: 0, isLink: false })
    },
    stat: async (path: string, options?: { resolve?: boolean }) => {
      if (path in files) return { kind: 'file', size: files[path].length, mtimeMs: mtimes[path] ?? 0, isLink: false }
      if (danglingLinks.has(path)) return { kind: 'other', size: 0, mtimeMs: 0, isLink: true }
      if (existing.has(path) && !(path in realPaths)) return { kind: 'directory', size: 0, mtimeMs: 0, isLink: false }
      if (!(path in realPaths)) throw new Error(`ENOENT ${path}`)
      return { kind: 'directory', size: 0, mtimeMs: 0, isLink: false, ...(options?.resolve ? { realPath: realPaths[path] } : {}) }
    },
  },
}

// cs's prompt-bar settings as the launch environment pins them, with the bars
// turned on, as most tests here are about them; cs's defaults leave them off.
const OPTIONS = { CS_BAND_PROMPTS: '1' }
// The band following the reader's scroll, and drawing every bar that fits.
const READING = { ...OPTIONS, CS_BAND_PROMPT: 'read' }
const UNCAPPED = { ...OPTIONS, CS_BAND_BARS: '100' }
const DRAWN = { type: 'Survey', props: {}, children: [] }
// What every terminal render event says of the screen (measured on 2.1.322):
// the fullscreen layout, 110 columns wide unless a test says otherwise.
type View = { columns: number; rows: number; isFullscreen: boolean } | undefined
const viewOf = (columns: number | null, isFullscreen = true): View => columns === null ? undefined : { columns, rows: 35, isFullscreen }
// `null` is an event with no viewport: a surface nobody has measured.
type BandProps = Partial<{ isWorking: boolean; hasSurvey: boolean; bodyColumns: number }>
// How the band was last raised: a tick of the count raises it that way again.
let lastBand: [BandProps, string, View | null]
const band = (props: BandProps = {}, surface = 'terminal', viewport: View | null = viewOf(110)) => {
  lastBand = [props, surface, viewport]
  return hooks['ui.render:AbovePrompt']($, { surface, viewport: viewport ?? undefined, props: { isWorking: false, hasSurvey: false, bodyColumns: 110, ...props } }, async () => DRAWN)
}

function buttons(tree: any): any[] {
  if (!tree || typeof tree !== 'object') return []
  if (Array.isArray(tree)) return tree.flatMap(buttons)
  if (tree.type === 'Button') return [tree]
  return (tree.children ?? []).flatMap(buttons)
}
const findButton = (tree: any) => buttons(tree)[0]

// The footer under the prompt: the engine's mode labels and its hint, each as
// the engine draws it, and the status line's record of its width.
const MODES_DRAWN = { type: 'engine', ref: 1 }
const HINT_DRAWN = { type: 'Hint', props: {}, children: [] }
const WIDTH = '/work/.cs/local/statusline-width'
const CYCLE = '(shift+tab to cycle)'
const footerMode = (columns: number | null = 110, modes: string[] = [], drawn: unknown = MODES_DRAWN, isFullscreen = true) =>
  hooks['ui.render:SessionMode']($, { surface: 'terminal', viewport: viewOf(columns, isFullscreen), props: { modes } }, async () => drawn)
const footerHint = (columns: number | null = 110, hint = CYCLE, isWorking = false, isFullscreen = true) =>
  hooks['ui.render:PromptHint']($, { surface: 'terminal', viewport: viewOf(columns, isFullscreen), props: { isDraft: false, isWorking, hint } }, async () => HINT_DRAWN)
// The keys under the prompt once the band above it has drawn: with no width
// recorded they stand in the hint's place, and with no key the hint is the engine's.
const keys = async (props: Parameters<typeof band>[0] = {}) => { await band(props); return footerHint() }

beforeEach(() => {
  for (const k of Object.keys(hooks)) delete hooks[k]
  percent = undefined; filled = []; ran = []; written = {}; existing = new Set(['/work/.cs/local']); danglingLinks = new Set()
  timers = []; invalidated = []; toasts = []; logs = []; asks = []; answer = WRAP_YES; modeAnswer = QUEUE_HERE; panes = []
  runs = []; runResult = { exitCode: 0, stdout: '', stderr: '' }; nextRuns = []; submitted = []; commands = []
  settingsRuns = []; settingsResult = { exitCode: 0, stdout: '', stderr: '' }
  compactedAt = []; compactResult = { messages: [] }
  availableCommands = []
  scrolls = []; scrollResult = {}; reads = []; mtimes = {}
  nowMs = 1_800_000_000_000; livePids = new Set(); claudePid = '4242'
  lastBand = [{}, 'terminal', viewOf(110)]
  // The default fixture is the lead conversation of a cs session.
  sessionId = 'uuid-lead'
  // /work sits under the default sessions root by its own name, and the launch
  // said where cs is, as every cs launch does.
  envVars = { HOME: '/home', CS_BIN: '/opt/cs/bin/cs', ...OPTIONS }
  cwdPath = '/work'
  realPaths = { '/work': '/work', '/home/.claude-sessions/work': '/work' }
  files = { '/work/.cs/local/state': 'claude_session_color: red\nclaude_session_id: uuid-lead\n' }
  register(on as any)
})

test('the default threshold is the statusline warn band', () => {
  expect(DEFAULT_PERCENT).toBe(40)
})

test('CS_STATUSLINE_CTX_WARN moves the band with the bar', async () => {
  envVars.CS_STATUSLINE_CTX_WARN = '50'
  percent = 49
  expect(await keys()).toBe(HINT_DRAWN)
  percent = 50
  expect(findButton(await keys())).toBeDefined()
  envVars.CS_ROTATE_BUTTON_CTX = '10'
  percent = 10
  expect(findButton(await keys())).toBeDefined()
})

test('below the threshold the band passes the drawn tree through untouched', async () => {
  percent = 39
  expect(await keys()).toBe(HINT_DRAWN)
})

test('CS_ROTATE_BUTTON_CTX in the process environment sets the threshold', async () => {
  envVars.CS_ROTATE_BUTTON_CTX = '55'
  percent = 54
  expect(await keys()).toBe(HINT_DRAWN)
  percent = 55
  expect(findButton(await keys())).toBeDefined()
})

test('an unusable CS_ROTATE_BUTTON_CTX falls back to the default', async () => {
  envVars.CS_ROTATE_BUTTON_CTX = 'soon'
  percent = 39
  expect(await keys()).toBe(HINT_DRAWN)
  percent = 40
  expect(findButton(await keys())).toBeDefined()
})

test('a quoted claude_session_id in state still names the lead', async () => {
  files['/work/.cs/local/state'] = 'claude_session_id: "uuid-lead"  \n'
  percent = 40
  expect(findButton(await keys())).toBeDefined()
})

test('at the threshold the rotate key draws under the prompt on the strip:jump1 action, first, and the band above adds nothing', async () => {
  percent = 40
  expect(await band()).toBe(DRAWN)
  const tree = await footerHint()
  expect(tree).not.toBe(HINT_DRAWN)
  expect(buttons(tree)).toHaveLength(2)
  const button = findButton(tree)
  expect(button.props.action).toBe('strip:jump1')
  // No bare digit: a hotkey fires from an empty composer, where a digit typed
  // as an answer to a numbered question belongs (measured live).
  expect(button.props.hotkey).toBeUndefined()
  expect(button.props.plain).toBe(true)
  expect(button.props.label).toBe('rotate')
  expect(JSON.stringify(tree)).not.toContain('borderStyle')
})

const KEYS = '/home/.claude/keybindings.json'
const bindKeys = (bindings: Record<string, string | null>, context = 'Global') => {
  files[KEYS] = JSON.stringify({ bindings: [{ context, bindings }] })
}
const words = (tree: any): string[] => texts(tree).map(textOf)
// Button labels are visible text even when the fake renderer has no children.
const bandWords = (tree: any): string[] => {
  if (!tree || typeof tree !== 'object') return []
  if (Array.isArray(tree)) return tree.flatMap(bandWords)
  if (tree.type === 'Text') return [textOf(tree)]
  if (tree.type === 'Button') return [tree.props.label]
  return (tree.children ?? []).flatMap(bandWords)
}
// The words drawn while no pointer rests on the band: a hover card's stay hidden,
// and a Button's ink is part of its press, not a word.
const restingWords = (tree: any): string[] => {
  if (!tree || typeof tree !== 'object') return []
  if (Array.isArray(tree)) return tree.flatMap(restingWords)
  if (tree.props?.display === 'none' || tree.type === 'Button') return []
  if (tree.type === 'Text') return [textOf(tree)]
  return (tree.children ?? []).flatMap(restingWords)
}

// The footer's row has no cells for a chord: under the prompt the keys draw
// as their words, whatever keybindings.json binds, and keep the actions a
// chord presses.
test('under the prompt the keys spell no chord, bound or not, and keep the actions a chord presses', async () => {
  percent = 40
  const cases: (() => void)[] = [
    () => { delete files[KEYS] },
    () => bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' }),
    () => bindKeys({ 'Ctrl+K 9': 'strip:jump1' }),
  ]
  for (const arrange of cases) {
    arrange()
    const tree = await keys()
    expect(bandWords(tree)).toEqual(['rotate', ' · ', 'wrap'])
    expect(buttons(tree).map((b: any) => b.props.action)).toEqual(['strip:jump1', 'strip:jump2'])
  }
})

// Where the footer has no safe place for them the keys draw on the band, as
// before they had one under the prompt: a footer nobody has measured is the
// plainest such case. The engine draws a Button with no hotkey as its label
// alone, so the band spells the key itself: the chord the person's
// keybindings.json gives the Button's action, as written there, and nothing
// when no chord presses it.
const keysOnBand = (props: Parameters<typeof band>[0] = {}) => band(props, 'terminal', null)

// Chords that share a prefix (`ctrl+x 1`, `ctrl+x 2`) spell the prefix once,
// dim, and each Button's own key beside its label: `ctrl+x 1 rotate   2 wrap`.
test('the band spells a shared chord prefix once and each Button\'s own key beside it', async () => {
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2', 'ctrl+x r': 'command:rotate' })
  percent = 40
  expect(words(await keysOnBand())).toEqual(['ctrl+x', '1', '   ', '2'])
  arm()
  expect(words(await keysOnBand())).toEqual(['ctrl+x', '1'])
})

test('chords with different prefixes are spelled whole, as slice 1 drew them', async () => {
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+w 2': 'strip:jump2' })
  percent = 40
  expect(words(await keysOnBand())).toEqual(['ctrl+x 1', '   ', 'ctrl+w 2'])
})

test('a chord bound elsewhere is spelled as the person wrote it', async () => {
  bindKeys({ 'Ctrl+K 9': 'strip:jump1' })
  percent = 40
  const drawn = words(await keysOnBand())
  expect(drawn).toEqual(['Ctrl+K', '9', '   '])
  expect(drawn.join(' ')).not.toContain('ctrl+x')
})

test('with no chord bound the band draws no key, and the Buttons stay', async () => {
  percent = 40
  const cases: (() => void)[] = [
    () => { delete files[KEYS] },
    () => { files[KEYS] = '{ not json' },
    () => { files[KEYS] = '[]' },
    () => bindKeys({ 'ctrl+x 1': null, 'ctrl+x 2': 'command:wrap' }),
    () => bindKeys({ 'ctrl+x 1': 'strip:jump1' }, 'Transcript'),
  ]
  for (const arrange of cases) {
    arrange()
    const tree = await keysOnBand()
    expect(buttons(tree)).toHaveLength(2)
    expect(words(tree).join(' ')).not.toContain('+')
  }
})

test('CLAUDE_CONFIG_DIR names the keybindings.json the band reads, as it does for Claude Code', async () => {
  envVars.CLAUDE_CONFIG_DIR = '/cfg'
  bindKeys({ 'ctrl+x 1': 'strip:jump1' })
  percent = 40
  expect(words(await keysOnBand()).join(' ')).not.toContain('ctrl+x 1')
  files['/cfg/keybindings.json'] = files[KEYS]
  expect(words(await keysOnBand())).toEqual(['ctrl+x', '1', '   '])
})

test('the band draws no context gauge: the status bar already carries it', async () => {
  percent = 71
  const tree = JSON.stringify([await band(), await footerHint()])
  expect(tree).not.toContain('ctx')
  expect(tree).not.toContain('71%')
})

// Claude Code draws its footer (the status bar and the mode line) two columns
// in from the prompt's rule (measured on 2.1.292); the band starts in the same
// column so the twins line up.
const boxes = (tree: any): any[] => {
  if (!tree || typeof tree !== 'object') return []
  if (Array.isArray(tree)) return tree.flatMap(boxes)
  const own = tree.type === 'Box' ? [tree] : []
  return [...own, ...(tree.children ?? []).flatMap(boxes)]
}

test('the band starts in the status bar\'s column, two in from the prompt\'s rule', async () => {
  files['/work/.cs/local/mail/new/one.json'] = '{}'
  const tree = await band()
  expect(boxes(tree).find((b: any) => b.props.key === 'cs-rotate-band').props.marginLeft).toBe(2)
})

// The chord is the one pressable thing a word has, so it alone wears the
// session colour; the labels are the engine's plain Buttons and the
// separators dim. The handler's band holds no chord now; a view that does
// (drawBand is also a design tool's) still draws them so.
test('the keys are in the session colour, the prefix bold light gray, the separators dim, and nothing else is coloured', () => {
  const tree: any = drawBand(view({ entries: buildBandEntries({ ...quiet, rotating: true, wrapping: true }) }), EL)
  for (const key of ['1', '2']) {
    expect(texts(tree).find((t: any) => textOf(t) === key).props).toMatchObject({ bold: true, color: 'rgb(220,38,38)' })
  }
  expect(texts(tree).find((t: any) => textOf(t) === 'ctrl+x').props).toEqual({ bold: true, color: 'subtle' })
  const separators = texts(tree).filter((t: any) => textOf(t) === '   ')
  expect(separators).toHaveLength(1)
  expect(separators[0].props).toEqual({ dimColor: true })
  expect(texts(tree).filter((t: any) => t.props.color !== undefined && t.props.color !== 'subtle').map(textOf)).toEqual(['1', '2'])
})

test('the band draws no rule: its first word stands where the line starts', () => {
  const tree: any = drawBand(view({ entries: buildBandEntries({ ...quiet, rotating: true, wrapping: true }) }), EL)
  expect(JSON.stringify(tree)).not.toContain('\u258c')
  expect(words(tree)[0]).toBe('ctrl+x')
})

test('with no palette colour the keys are bold in the terminal\'s ink, and nothing is coloured', () => {
  const tree: any = drawBand(view({ entries: buildBandEntries({ ...quiet, rotating: true, wrapping: true }), own: undefined }), EL)
  expect(texts(tree).filter((t: any) => t.props.bold).map(textOf)).toEqual(['ctrl+x', '1', '2'])
  expect(texts(tree).filter((t: any) => t.props.color !== undefined && t.props.color !== 'subtle').map(textOf)).toEqual([])
})

// With a handoff armed and its count running, the keys read
// `/clear now in 20s`: the key first, then the count it stops, a space between.
test('armed and counting, the countdown follows its clear key, a space between them', async () => {
  await startGrace()
  const tree = await keys()
  expect(bandWords(tree)).toEqual(['/clear now', ' ', `in ${GRACE_SECONDS}s`])
  expect(buttons(tree).map((b: any) => [b.props.label, b.props.action])).toEqual([['/clear now', 'strip:jump1']])
})

// One thin line, a blank line above it: no fill, whatever the terminal
// background measures, no chip, no caps, no border, no Claude mark. The key
// stays: it is the band's identity.
test('the band is one thin line: a keyed box with no fill, chip, caps, border, hover or Claude mark', async () => {
  envVars.CS_TERM_BG_RGB = '252;247;229'
  envVars.CS_STATUSLINE_CAPS = '1'
  files['/work/.cs/local/mail/new/one.json'] = '{}'
  const tree = JSON.stringify(await band())
  expect(tree).toContain('"marginTop":1')
  expect(tree).toContain('"key":"cs-rotate-band"')
  expect(tree).not.toContain('backgroundColor')
  expect(tree).not.toContain('"cs"')
  expect(tree).not.toContain('\ue0b6')
  expect(tree).not.toContain('\ue0b4')
  expect(tree).not.toContain('borderStyle')
  expect(tree).not.toContain('borderColor')
  expect(tree).not.toContain('hover')
  expect(tree).not.toContain('\u2733')
  expect(tree).not.toContain('"claude"')
})


test('while a turn runs the button is hidden', async () => {
  percent = 90
  expect(await keys({ isWorking: true })).toBe(HINT_DRAWN)
})

test('while a survey holds the band the hook yields', async () => {
  percent = 90
  expect(await keys({ hasSurvey: true })).toBe(HINT_DRAWN)
})

test('an unknown percentage draws nothing', async () => {
  percent = undefined
  expect(await keys()).toBe(HINT_DRAWN)
})

test('a press runs the rotate skill and fills nothing', async () => {
  percent = 80
  const button = findButton(await keys())
  await button.props.onPress()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
  expect(filled).toEqual([])
})

// The skill ends by arming a marker in .cs/local, so the press asks cs first,
// as the clear button and the forced /rotate do.
test('while git tracks a control file, a press runs no rotation', async () => {
  percent = 80
  runResult = tracked
  await findButton(await keys()).props.onPress()
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(ran).toEqual([])
})

test('outside a cs session the band draws nothing at crit', async () => {
  percent = 90
  existing = new Set(); files = {}
  expect(await keys()).toBe(HINT_DRAWN)
})

test('a session opted out with .cs/local/disabled gets no button', async () => {
  percent = 90
  existing.add('/work/.cs/local/disabled')
  expect(await keys()).toBe(HINT_DRAWN)
})

test('a teammate conversation (not the one .cs/local/state names) gets no button', async () => {
  percent = 90
  sessionId = 'uuid-teammate'
  expect(await keys()).toBe(HINT_DRAWN)
})

test('with no state file to name the lead the band draws nothing', async () => {
  percent = 90
  files = {}
  expect(await keys()).toBe(HINT_DRAWN)
})

const MARKER = '/work/.cs/local/pending-handoff'
const HANDOFF = '/work/.cs/handoffs/2026-09-15-next-step.md'
const UNCONSUMED = '---\nparent: uuid-lead\nstatus: unconsumed\n---\n\n## 1. Next Step\n'
// Armed the way the rotate skill leaves it: an unconsumed handoff, then the marker.
const arm = () => { files[HANDOFF] = UNCONSUMED; files[MARKER] = '2026-09-15-next-step.md\n' }

test('an armed handoff turns the button into the clear button, whatever the context', async () => {
  arm()
  for (const p of [undefined, 3, 90]) {
    percent = p
    const tree = await keys()
    expect(buttons(tree)).toHaveLength(1)
    const button = findButton(tree)
    expect(button.props.action).toBe('strip:jump1')
    expect(button.props.hotkey).toBeUndefined()
    expect(button.props.plain).toBe(true)
    expect(findButton(tree).props.label).toBe('/clear now')
    const json = JSON.stringify(tree)
    expect(json).not.toContain('borderStyle')
    expect(json).not.toContain('borderColor')
    expect(json).not.toContain('undefined')
    expect(json).not.toContain('ctx')
  }
})

test('pressing the clear button runs /clear and fills nothing', async () => {
  arm(); percent = 3
  await findButton(await keys()).props.onPress()
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  expect(filled).toEqual([])
})

test('the rotate press never clears', async () => {
  percent = 80
  await findButton(await keys()).props.onPress()
  expect(ran).not.toContainEqual({ command: 'clear', args: '' })
})

test('an armed handoff is still lead-only and yields to a running turn', async () => {
  arm(); percent = 90
  expect(await keys({ isWorking: true })).toBe(HINT_DRAWN)
  expect(await keys({ hasSurvey: true })).toBe(HINT_DRAWN)
  sessionId = 'uuid-teammate'
  expect(await keys()).toBe(HINT_DRAWN)
})

test('a marker naming a handoff that is gone, consumed, or outside the store does not arm', async () => {
  percent = 39
  arm(); delete files[HANDOFF]
  expect(await keys()).toBe(HINT_DRAWN)
  arm(); files[HANDOFF] = UNCONSUMED.replace('status: unconsumed', 'status: consumed')
  expect(await keys()).toBe(HINT_DRAWN)
  arm(); files[HANDOFF] = '## no frontmatter\nstatus: unconsumed\n'
  expect(await keys()).toBe(HINT_DRAWN)
  arm(); files[MARKER] = '../local/state\n'
  expect(await keys()).toBe(HINT_DRAWN)
  percent = 40
  expect(findButton(await keys()).props.label).toBe('rotate')
})

// cs loads only a handoff whose file name is plain (letters, digits and ._@-,
// at most 160 characters), so a marker naming any other, even an unconsumed
// handoff that exists, arms nothing: the /clear would load nothing.
test('a marker naming a handoff whose name is not plain does not arm', async () => {
  percent = 39
  for (const name of ['2026-09-15-e\x1b[1mb\x07.md', '2026-09-15 next.md', 'a'.repeat(158) + '.md']) {
    files = { ...files, [`/work/.cs/handoffs/${name}`]: UNCONSUMED, [MARKER]: `${name}\n` }
    expect(await keys()).toBe(HINT_DRAWN)
  }
  const longest = 'a'.repeat(157) + '.md'
  files = { ...files, [`/work/.cs/handoffs/${longest}`]: UNCONSUMED, [MARKER]: `${longest}\n` }
  expect(findButton(await keys()).props.label).toBe('/clear now')
})

// The marker is read as the SessionStart hook reads it (tr -d '[:space:]' in
// the C locale): ASCII whitespace is dropped and nothing else, so a marker
// whose name starts with U+FEFF, U+00A0 or U+2028 names a file the hook will
// not load, and arms nothing.
test('a marker is read as the hook reads it: only ASCII whitespace is dropped', async () => {
  percent = 39
  for (const lead of ['﻿', ' ', ' ']) {
    arm(); files[MARKER] = `${lead}2026-09-15-next-step.md\n`
    expect(await keys()).toBe(HINT_DRAWN)
  }
  arm(); files[MARKER] = '\t 2026-09-15-next-step.md\r\n'
  expect(findButton(await keys()).props.label).toBe('/clear now')
})

// An encrypted session keeps the marker and its handoffs behind .cs/private.
const PRIVATE_MARKER = '/work/.cs/private/pending-handoff'
const PRIVATE_HANDOFF = '/work/.cs/private/handoffs/2026-09-15-next-step.md'

test('an encrypted session arms from the marker and handoff behind .cs/private', async () => {
  files[PRIVATE_HANDOFF] = UNCONSUMED; files[PRIVATE_MARKER] = '2026-09-15-next-step.md\n'
  percent = 3
  expect(findButton(await keys()).props.label).toBe('/clear now')
})

test('a private marker never arms from the plaintext handoff store', async () => {
  files[HANDOFF] = UNCONSUMED; files[PRIVATE_MARKER] = '2026-09-15-next-step.md\n'
  percent = 39
  expect(await keys()).toBe(HINT_DRAWN)
})

// cs judges whether it trusts the session's control files: a marker git tracks
// (a pull brought it in) names a rotation the SessionStart hook refuses, so it
// arms nothing, and the band says why, once per answer.
const VETTED = { exitCode: 0, stdout: '', stderr: '' }
const TRACKED = "Error: .cs/local/pending-handoff is tracked in git (per-actor state must stay local). Fix with: git -C /work --literal-pathspecs rm -r --cached -- .cs/local && git -C /work commit -m 'stop tracking .cs/local'"
const tracked = { exitCode: 1, stdout: '', stderr: `${TRACKED}\n` }

test('the band asks cs nothing as it draws, however often it redraws', async () => {
  arm(); percent = 3
  for (let i = 0; i < 5; i++) expect(findButton(await keys()).props.label).toBe('/clear now')
  expect(runs).toEqual([])
})

test('pressing the clear button asks cs about the session, and a tracked control file clears nothing', async () => {
  arm(); percent = 3
  runResult = tracked
  await findButton(await keys()).props.onPress()
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(ran).toEqual([])
  expect(toasts).toEqual([`no rotation in this session: ${TRACKED}`])
  // the band then draws the session as unarmed (below the threshold: nothing),
  // and the same refusal at the next turn's end is not said again
  expect(await keys()).toBe(HINT_DRAWN)
  envVars.CS_ROTATE_FORCE_CTX = '70'
  await turnComplete()
  expect(runs).toHaveLength(2)
  expect(toasts).toHaveLength(1)
})

test('once cs trusts the session again, the next press clears', async () => {
  arm(); percent = 3
  runResult = tracked
  await findButton(await keys()).props.onPress()
  runResult = VETTED
  envVars.CS_ROTATE_FORCE_CTX = '70'; percent = 80
  await turnComplete()
  expect(findButton(await keys()).props.label).toBe('/clear now')
  await findButton(await keys()).props.onPress()
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('a turn ending with a tracked control file starts no countdown and forces no /rotate', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  runResult = tracked
  await turnComplete()
  await fireAfter()
  expect(timers.filter(t => t.kind === 'every')).toEqual([])
  expect(ran).toEqual([])
  expect(Object.keys(written)).toEqual([])
  // with no handoff armed, the same turn's end past the threshold forces nothing either
  delete files[MARKER]
  await turnComplete()
  await fireAfter()
  expect(ran).toEqual([])
  expect(Object.keys(written)).toEqual([])
})

test('a control file git starts tracking during the count clears nothing at zero', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  runResult = tracked
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([])
  expect(toasts).toEqual([`no rotation in this session: ${TRACKED}`])
})

test('a press while cs is still answering, then the count reaching zero, clears once', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const zero = ticker()!
  const run = $.process.run
  let answer: (r: any) => void = () => {}
  let asked: () => void = () => {}
  const reached = new Promise<void>(r => { asked = r })
  $.process.run = async (argv: string[], init: any) => {
    $.process.run = run
    runs.push({ argv, init })
    asked()
    return new Promise(r => { answer = r })
  }
  try {
    const press = findButton(await keys()).props.onPress()
    await reached
    await zero.fn()
    answer(VETTED)
    await press
  } finally {
    $.process.run = run
  }
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('with the forcing off, a prompt after a refusal asks cs afresh at the next press', async () => {
  envVars.CS_ROTATE_FORCE_CTX = 'off'
  arm(); percent = 3
  runResult = tracked
  await findButton(await keys()).props.onPress()
  expect(await keys()).toBe(HINT_DRAWN)
  runResult = VETTED
  await promptSubmit()
  expect(findButton(await keys()).props.label).toBe('/clear now')
  await findButton(await keys()).props.onPress()
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('when cs cannot answer, a press clears nothing and the band says why', async () => {
  arm(); percent = 3
  delete envVars.CS_BIN
  await findButton(await keys()).props.onPress()
  expect(runs).toHaveLength(0)
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = new Error('spawn ENOENT')
  envVars.CS_ROTATE_FORCE_CTX = '70'; percent = 80
  await turnComplete()
  expect(ran).toEqual([])
  expect(toasts).toEqual([
    'no rotation in this session: the launch did not say where cs is (CS_BIN)',
    'no rotation in this session: cs -vet-session did not run: spawn ENOENT',
  ])
})

test('an empty marker names no handoff, so the band behaves as unarmed', async () => {
  files[MARKER] = '\n'
  percent = 39
  expect(await keys()).toBe(HINT_DRAWN)
  percent = 40
  expect(findButton(await keys()).props.label).toBe('rotate')
})

test('session.start writes a heartbeat under the session meta dir', async () => {
  const r = await hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(r).toEqual({ cwd: '/work' })
  const text = written['/work/.cs/local/cs.heartbeat']
  expect(text).toMatch(/^\d{4}-\d{2}-\d{2}T.*Z\n$/)
})

// While git tracks the session's control files the mod adds nothing there: cs
// is asked before the heartbeat lands, and its refusal is said once.
test('a session whose control files git tracks gets no heartbeat', async () => {
  runResult = tracked
  await hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(written).toEqual({})
  expect(toasts).toEqual([`no rotation in this session: ${TRACKED}`])
})

test('outside a cs session no heartbeat is written', async () => {
  await hooks['session.start']($, { cwd: '/plain', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})

// The sessions root names a session; nothing inside a directory can, since a
// cloned repository may carry any file under .cs/. The cwd is a cs session
// when <root>/<its name> is the cwd itself.
test('a directory with .cs/local that the sessions root does not name gets no heartbeat', async () => {
  cwdPath = '/clone'
  existing = new Set(['/clone/.cs/local'])
  realPaths = { '/clone': '/clone' }
  await hooks['session.start']($, { cwd: '/clone', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})

test('a root entry of the same name that is another directory does not make the cwd a session', async () => {
  cwdPath = '/clone/work'
  existing = new Set(['/clone/work/.cs/local'])
  realPaths = { '/clone/work': '/clone/work', '/home/.claude-sessions/work': '/work' }
  await hooks['session.start']($, { cwd: '/clone/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})

test('CS_SESSIONS_ROOT names the sessions root', async () => {
  envVars.CS_SESSIONS_ROOT = '/roots'
  realPaths = { '/work': '/work', '/roots/work': '/work' }
  await hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual(['/work/.cs/local/cs.heartbeat'])
  realPaths = { '/work': '/work', '/home/.claude-sessions/work': '/work' }
  written = {}
  await hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})

test('an adopted session is named by the session_name its state records, and the root entry must be the cwd', async () => {
  cwdPath = '/code/project'
  existing = new Set(['/code/project/.cs/local'])
  files = { '/code/project/.cs/local/state': 'session_name: alias\nclaude_session_id: uuid-lead\n' }
  realPaths = { '/code/project': '/code/project', '/home/.claude-sessions/alias': '/code/project' }
  await hooks['session.start']($, { cwd: '/code/project', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual(['/code/project/.cs/local/cs.heartbeat'])
  realPaths['/home/.claude-sessions/alias'] = '/elsewhere'
  written = {}
  await hooks['session.start']($, { cwd: '/code/project', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})

test('the lead of a directory the sessions root does not name gets no button', async () => {
  percent = 90
  realPaths = { '/work': '/work' }
  expect(await keys()).toBe(HINT_DRAWN)
})

// A turn's end, the way the engine reports it: answered on the main loop unless said otherwise.
const turnComplete = (e: Partial<{ reason: string; agentId: string }> = {}) =>
  hooks['turn.complete']($, { reason: 'answer', answer: 'ok', durationMs: 1, isAborted: false, turnId: 't1', ...e }, async () => ({ text: 'ok' }))
// The pending `after` timers, run the way the clock would run them.
const fireAfter = async () => { for (const t of timers.filter(t => t.kind === 'after' && !t.cancelled)) { t.cancelled = true; await t.fn() } }
// Every one-shot timer run, and those they start: after a launch's first
// draw the mod has asked which Claude Code it runs in, from a timer, and read
// the width its status line recorded.
const settleTimers = async () => { for (let rounds = 0; rounds < 6 && timers.some(t => t.kind === 'after' && !t.cancelled); rounds++) await fireAfter() }

test('with CS_ROTATE_FORCE_CTX set, a turn ending past it schedules /rotate from a timer, not from the hook', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 70
  await turnComplete()
  expect(ran).toEqual([])
  expect(timers.map(t => t.kind)).toEqual(['after'])
  await fireAfter()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
})

test('without CS_ROTATE_FORCE_CTX a turn ending past the 80% default forces a rotation', async () => {
  percent = 80
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  await fireAfter()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
})

test('under the default a turn ending below 80% forces nothing', async () => {
  percent = 79
  await turnComplete()
  expect(timers).toEqual([])
  expect(ran).toEqual([])
})

test('CS_ROTATE_FORCE_CTX=off, and 0, turn the forcing off entirely', async () => {
  for (const value of ['off', 'OFF', '0']) {
    envVars.CS_ROTATE_FORCE_CTX = value
    percent = 100
    await turnComplete()
    expect(timers).toEqual([])
    expect(ran).toEqual([])
  }
})

test('below the force threshold, or with an unusable value, a turn ending forces nothing', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 69
  await turnComplete()
  // An unusable value is the default, not "off": a typo must not quietly
  // disable a rotation the person is relying on. 100 is past 80, so it forces.
  envVars.CS_ROTATE_FORCE_CTX = 'critical'
  percent = 100
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
})

test('a whole number outside 1..100 is the default 80, not a threshold no turn can reach', async () => {
  for (const value of ['101', '150', '999']) {
    envVars.CS_ROTATE_FORCE_CTX = value
    percent = 79
    await turnComplete()
    expect(timers).toEqual([])
  }
  percent = 80
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  await fireAfter()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
})

test('a forced rotation runs once per conversation, and a failed /rotate is not retried', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 80
  await turnComplete()
  expect(written['/work/.cs/local/cs.forced']).toBe('uuid-lead\n')
  await turnComplete(); await turnComplete()
  expect(timers).toHaveLength(1)
  // the marker is written before the timer is scheduled, so a rejected run stays rejected
  $.command.run = async () => { throw new Error('unknown command') }
  await fireAfter()
  expect(toasts).toEqual(['/rotate did not run: Error: unknown command'])
  await turnComplete()
  expect(timers).toHaveLength(1)
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  // a marker from an earlier conversation of the session does not count
  files['/work/.cs/local/cs.forced'] ='uuid-earlier\n'
  await turnComplete()
  expect(timers).toHaveLength(2)
})

test('a subagent\'s turn, an aborted, errored or refused one, a teammate, or an unarmed non-cs directory forces nothing', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 90
  await turnComplete({ agentId: 'agent-1' })
  await turnComplete({ reason: 'aborted' })
  await turnComplete({ reason: 'error' })
  await turnComplete({ reason: 'refusal' })
  sessionId = 'uuid-teammate'
  await turnComplete()
  sessionId = 'uuid-lead'; existing = new Set(); files = {}
  await turnComplete()
  expect(timers).toEqual([])
  expect(Object.keys(written)).toEqual([])
})

// The rotate button runs /rotate for the person in one key, so that rotation
// must not stop to ask either: before it runs, the press writes the
// conversation's id to .cs/local/cs.pressed, which cs -archive-tasks plan
// reads as a forced rotation. The end of the next main-loop turn empties it,
// whatever ended that turn, so a /rotate typed later in the conversation asks
// as a manual one does; a run the engine refuses empties it at once.
const PRESSED = '/work/.cs/local/cs.pressed'

test('a press names the conversation in cs.pressed before /rotate runs, and the end of the main loop\'s turn empties it', async () => {
  percent = 80
  let atRun: string | undefined
  const run = $.command.run
  $.command.run = async (args: any) => { atRun = files[PRESSED]; ran.push(args); return { text: '' } }
  try {
    await findButton(await keys()).props.onPress()
  } finally {
    $.command.run = run
  }
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
  expect(atRun).toBe('uuid-lead\n')
  await turnComplete({ agentId: 'agent-1' })
  expect(files[PRESSED]).toBe('uuid-lead\n')
  await turnComplete({ reason: 'aborted' })
  expect(files[PRESSED]).toBe('')
})

test('a press whose /rotate the engine refuses empties cs.pressed at once', async () => {
  percent = 80
  const run = $.command.run
  $.command.run = async () => { throw new Error('unknown command') }
  let refused: unknown
  try {
    await findButton(await keys()).props.onPress()
  } catch (err) {
    refused = err
  } finally {
    $.command.run = run
  }
  expect(String(refused)).toBe('Error: unknown command')
  expect(files[PRESSED]).toBe('')
})

test('the end of a turn leaves a press marker naming another conversation, and one git tracks, as they are', async () => {
  files[PRESSED] = 'uuid-earlier\n'
  await turnComplete()
  expect(runs).toEqual([])
  expect(files[PRESSED]).toBe('uuid-earlier\n')
  files[PRESSED] = 'uuid-lead\n'
  runResult = tracked
  await turnComplete()
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(files[PRESSED]).toBe('uuid-lead\n')
  expect(written).toEqual({})
})

// A marker that cannot be emptied would make a later typed /rotate read as
// pressed, so the failure is said; the turn's end goes on to what follows it.
test('a press marker the turn end cannot empty is said, and the turn end goes on', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 80
  files[PRESSED] = 'uuid-lead\n'
  const write = $.fs.write
  $.fs.write = async (path: string, text: string) => {
    if (path === PRESSED) throw new Error('EACCES')
    return write(path, text)
  }
  let result: any
  try {
    result = await turnComplete()
  } finally {
    $.fs.write = write
  }
  expect(toasts).toEqual(['could not empty .cs/local/cs.pressed: Error: EACCES'])
  expect(files[PRESSED]).toBe('uuid-lead\n')
  expect(result).toEqual({ text: 'ok' })
  expect(timers.map(t => t.kind)).toEqual(['after'])
})

test('a turn ending past the force threshold with a handoff already armed runs no second /rotate', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 90
  arm()
  await turnComplete()
  await fireAfter()
  expect(ran).toEqual([])
})

// The countdown's ticker, and one tick of it as the clock would run it.
// The countdown's clock, a tick a second; the footer's reads the status line's width on a slower one.
const ticker = () => timers.find(t => t.kind === 'every' && t.ms === 1000 && !t.cancelled)
// Each tick asks for a redraw, and the engine raises the band again within
// the second (measured on 2.1.322: 5 to 19 ms after the tick), as it was last
// raised. While another mod answers the band without passing it on, the mod's
// hook is not reached: the ticks go by unseen.
const tickUnseen = async (n = 1) => { for (let i = 0; i < n; i++) await ticker()!.fn() }
const tick = async (n = 1) => { for (let i = 0; i < n; i++) { await tickUnseen(); await band(...lastBand) } }
const promptSubmit = (text = 'keep going') =>
  hooks['prompt.submit']($, { text, wait: false, origin: { kind: 'composer' } }, async (e) => ({ text: e.text }))

test('with the handoff armed and force on, a turn ending starts a countdown the band shows, one redraw a second', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  expect(ticker()?.ms).toBe(1000)
  expect(GRACE_SECONDS).toBe(20)
  expect(JSON.stringify(await keys())).toContain(`"in ${GRACE_SECONDS}s"`)
  await tick(3)
  expect(invalidated).toEqual(['ui.render', 'ui.render', 'ui.render'])
  expect(JSON.stringify(await keys())).toContain(`"in ${GRACE_SECONDS - 3}s"`)
  expect(ran).toEqual([])
  // one countdown at a time: another turn ending does not start a second
  await turnComplete()
  expect(timers.filter(t => t.kind === 'every' && t.ms === 1000)).toHaveLength(1)
})

test('at zero the countdown runs /clear, once, and stops ticking', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  const t = ticker()!
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  expect(t.cancelled).toBe(true)
  expect(JSON.stringify(await keys())).not.toMatch(/"in -?\d+s"/)
  // the band drew the count at every tick: nothing more to say
  expect(toasts).toEqual([])
})

// A mod loaded before this one may answer the band's render without passing
// it on (measured: a council run's band, a link prompt's). The mod's hook is
// then not reached, whatever the count's redraws ask for, and what the band
// last said of a turn stays as it was. The toast follows the /clear: one shown
// before it leaves the screen with the conversation (measured), and a /clear
// the engine rejects has only its own to say. The toast names both things
// measured to keep the band from being raised with no question open: another
// mod's band, and a picker such as /model's, behind which the engine holds
// the /clear until it closes.
const CLEAR_UNSEEN = 'the count to /clear ran unseen: another mod or a picker had the band above the prompt; /clear has run'
const CLEAR = { command: 'clear', args: '' }

test('a band another mod takes mid-turn does not stop the count: at zero /clear runs, once, and a toast then says the count ran unseen', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band({ isWorking: true })
  await turnComplete()
  const t = ticker()!
  let toastsAtClear: string[] | undefined
  const run = $.command.run
  $.command.run = async (args: any) => { toastsAtClear = [...toasts]; return run(args) }
  try {
    await tickUnseen(GRACE_SECONDS)
  } finally {
    $.command.run = run
  }
  expect(ran).toEqual([CLEAR])
  expect(toastsAtClear).toEqual([])
  expect(toasts).toEqual([CLEAR_UNSEEN])
  expect(t.cancelled).toBe(true)
  // a /clear the engine rejects under another mod's band says only that
  toasts = []
  await turnComplete()
  $.command.run = async () => { throw new Error('no session') }
  try {
    await tickUnseen(GRACE_SECONDS)
  } finally {
    $.command.run = run
  }
  expect(toasts).toEqual(['/clear did not run: Error: no session'])
})

test('a band another mod takes while the count runs changes nothing either, whether it last drew idle or a command running', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  for (const last of [{}, { isWorking: true }]) {
    arm(); percent = 80; ran = []; toasts = []
    await keys()
    await turnComplete()
    await tick(5)
    // A typed command draws the band as working for a moment (measured), and
    // the hint under the prompt goes on saying no turn runs.
    await keys(last)
    await tickUnseen(GRACE_SECONDS - 5)
    expect([last, ran]).toEqual([last, [CLEAR]])
    expect([last, toasts]).toEqual([last, [CLEAR_UNSEEN]])
    // and the key the band last put under the prompt is not left there
    expect([last, await footerHint()]).toEqual([last, HINT_DRAWN])
  }
})

// The keys under the prompt are what the band last put there, the count's
// seconds among them: once another mod has the band nothing redraws them
// (measured: `/clear now in 16s` stood through the count and after the /clear).
test('while another mod has the band the clear key and its count leave the row under the prompt, and come back with the band', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  await tick()
  expect(bandWords(await footerHint())).toEqual(['/clear now', ' ', `in ${GRACE_SECONDS - 1}s`])
  await tickUnseen(2)
  expect(await footerHint()).toBe(HINT_DRAWN)
  await tick()
  expect(bandWords(await footerHint())).toEqual(['/clear now', ' ', `in ${GRACE_SECONDS - 4}s`])
  expect(ran).toEqual([])
  expect(toasts).toEqual([])
})

// A survey is a question to the person, and the engine draws it whoever has
// the band (measured). What the band last said of one stands once another mod
// takes the band: nothing else tells the mod a survey is up.
test('a survey above the prompt at zero keeps the /clear from running and a toast says so, also when another mod took the band after the survey drew', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  const cases: [typeof tick, string][] = [
    [tick, '/clear did not run: a survey is waiting above the prompt'],
    [tickUnseen, '/clear did not run: a survey was waiting above the prompt when the band last drew'],
  ]
  for (const [count, said] of cases) {
    arm(); percent = 80; toasts = []
    await band()
    await turnComplete()
    const t = ticker()!
    await band({ hasSurvey: true })
    await count(GRACE_SECONDS)
    expect(ran).toEqual([])
    expect(toasts).toEqual([said])
    expect(t.cancelled).toBe(true)
  }
})

// The engine's question dialog takes the prompt's place, the band's with it:
// while one is open the band is not raised and the dialog is, at every redraw
// (measured on 2.1.322, a plugin's question asked while idle; a /clear run
// under it is not refused).
const DIALOG_DRAWN = { type: 'engine', ref: 2 }
const dialog = () => hooks['ui.render:AskUserQuestion']?.($, { surface: 'terminal', props: { tool: 'AskUserQuestion', questions: [] } }, async () => DIALOG_DRAWN)
const tickUnderDialog = async (n = 1) => { for (let i = 0; i < n; i++) { await tickUnseen(); await dialog() } }

test('a question dialog open at zero keeps the /clear from running and a toast says so; one answered before zero changes nothing', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  await tick(5)
  const t = ticker()!
  await tickUnderDialog(GRACE_SECONDS - 5)
  expect(ran).toEqual([])
  expect(toasts).toEqual(['/clear did not run: a question is waiting for an answer'])
  expect(t.cancelled).toBe(true)
  toasts = []
  await turnComplete()
  await tickUnderDialog(5)
  await tick(GRACE_SECONDS - 5)
  expect(ran).toEqual([CLEAR])
  expect(toasts).toEqual([])
  // the dialog itself draws as the engine's
  expect(await dialog()).toBe(DIALOG_DRAWN)
})

test('a conversation that is no longer the lead at zero clears nothing and says so', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-other\n'
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([])
  expect(toasts).toEqual(["/clear did not run: this conversation is no longer the session's lead"])
  expect(ticker()).toBeUndefined()
})

test('a prompt entering the session stops the countdown and passes through', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  await tick(2)
  const t = ticker()!
  expect(await promptSubmit('one more thing')).toEqual({ text: 'one more thing' })
  expect(t.cancelled).toBe(true)
  expect(JSON.stringify(await keys())).not.toMatch(/"in -?\d+s"/)
  expect(ran).toEqual([])
  // the next turn ending restarts it from the top
  await turnComplete()
  expect(JSON.stringify(await keys())).toContain(`"in ${GRACE_SECONDS}s"`)
})

test('pressing the clear button mid-countdown stops the ticker before it clears', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  await tick(2)
  const t = ticker()!
  await findButton(await keys()).props.onPress()
  expect(t.cancelled).toBe(true)
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('a countdown reaching zero while the band draws a turn running or a survey clears nothing, stops, and says which', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  const cases: [BandProps, string][] = [
    [{ isWorking: true }, '/clear did not run: a turn is running'],
    [{ hasSurvey: true }, '/clear did not run: a survey is waiting above the prompt'],
  ]
  for (const [props, said] of cases) {
    toasts = []
    await band()
    await turnComplete()
    const t = ticker()!
    await band(props)
    await tick(GRACE_SECONDS)
    expect(ran).toEqual([])
    expect(t.cancelled).toBe(true)
    expect(toasts).toEqual([said])
  }
})

test('a countdown reaching zero re-checks the handoff: one consumed meanwhile clears nothing', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await band()
  await turnComplete()
  files[HANDOFF] = UNCONSUMED.replace('status: unconsumed', 'status: consumed')
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([])
  expect(toasts).toEqual(['/clear did not run: the handoff is no longer armed'])
})

test('with the forcing off, or outside the lead, an armed handoff starts no countdown and prompt.submit passes through', async () => {
  envVars.CS_ROTATE_FORCE_CTX = 'off'
  arm(); percent = 80
  await turnComplete()
  envVars.CS_ROTATE_FORCE_CTX = '70'
  sessionId = 'uuid-teammate'
  await turnComplete()
  expect(timers).toEqual([])
  expect(toasts).toEqual([])
  expect(await promptSubmit()).toEqual({ text: 'keep going' })
})

test('a prompt arriving while the zero tick is still checking the handoff wins: nothing clears', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const zero = tick()
  await promptSubmit('wait, one more thing')
  await zero
  expect(ran).toEqual([])
  // and a press racing the zero tick clears once, not twice
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const button = findButton(await keys())
  const zero2 = tick()
  await button.props.onPress()
  await zero2
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('a /clear run from anywhere else ends the countdown, so no timer outlives the conversation', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  const t = ticker()!
  const e = { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }
  expect(await hooks['command.run:clear']($, e, async () => ({ text: '' }))).toEqual({ text: '' })
  expect(t.cancelled).toBe(true)
  expect(JSON.stringify(await keys())).not.toMatch(/"in -?\d+s"/)
})

test('a rejected /clear at zero shows a toast and clears nothing else', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  await fireAfter() // the handoff pane's open, spent
  $.command.run = async () => { throw new Error('no session') }
  await tick(GRACE_SECONDS)
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  expect(toasts).toEqual(['/clear did not run: Error: no session'])
  expect(ran).toEqual([])
})

test('a read that throws at zero ends the count and a toast says the /clear did not run', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const t = ticker()!
  const exists = $.fs.exists
  $.fs.exists = async () => { throw new Error('EIO') }
  try {
    await tickUnseen()
  } finally {
    $.fs.exists = exists
  }
  expect(t.cancelled).toBe(true)
  expect(toasts).toEqual(['/clear did not run: Error: EIO'])
  expect(ran).toEqual([])
  expect(JSON.stringify(await keys())).not.toMatch(/"in -?\d+s"/)
})

// The SessionStart hook's own rule (_handoff_is_unconsumed): the frontmatter
// must close, and the status must sit inside it.
test('isUnconsumed follows the hook: unclosed frontmatter, or a status after it, is not armed', () => {
  expect(isUnconsumed('---\nstatus: unconsumed\n---\n')).toBe(true)
  expect(isUnconsumed('---\nstatus: unconsumed\n')).toBe(false)
  expect(isUnconsumed('---\nparent: x\n---\nstatus: unconsumed\n')).toBe(false)
  expect(isUnconsumed('---\nstatus: consumed\n---\n')).toBe(false)
  expect(isUnconsumed('')).toBe(false)
})

test('a tick that lands while the zero tick is still reading does not push the count negative or clear twice', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  await tick(GRACE_SECONDS - 1)
  const t = ticker()!
  const first = t.fn()
  const second = t.fn()
  await first; await second
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  expect(JSON.stringify(await keys())).not.toContain('"in -')
})


test('a conversation met at load is forced whatever it started at; one born of a /clear that starts past the threshold is not, and says so once', async () => {
  // resumed (or launched) already past the line: forced, as asked
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
  // the successor wakes past the line: that is the loop, and it stops here
  await clearRun()
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-next\n'
  percent = 71
  await turnComplete(); await turnComplete()
  expect(timers).toHaveLength(1)
  expect(toasts).toEqual(['CS_ROTATE_FORCE_CTX=70 is below this conversation\'s starting context (71%); not forcing a rotation'])
  // a teammate past the line is not the lead: no rotation, and no toast about one
  sessionId = 'uuid-teammate'
  percent = 90
  await turnComplete()
  expect(timers).toHaveLength(1)
  expect(toasts).toHaveLength(1)
  // a successor that starts below and works its way past is forced as usual
  sessionId = 'uuid-later'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-later\n'
  percent = 30
  await turnComplete()
  percent = 90
  await turnComplete()
  expect(timers).toHaveLength(2)
  // a reload forgets: the conversation it meets next is adopted, whatever it reads
  register(on as any)
  sessionId = 'uuid-reloaded'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-reloaded\n'
  percent = 95
  await turnComplete()
  expect(timers).toHaveLength(3)
})

const clearRun = () =>
  hooks['command.run:clear']($, { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }, async () => ({ text: '' }))

test('the first conversation leaves its session color to the launch', async () => {
  await band()
  await band()
  await turnComplete()
  expect(ran).toEqual([])
})

test('a conversation without a session color runs no color command', async () => {
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-lead\n'
  await band()
  await clearRun()
  sessionId = 'uuid-next'
  await band()
  expect(ran).toEqual([])
})

test('a conversation with an unknown session color runs no color command', async () => {
  await band()
  for (const color of ['mauve', 'constructor']) {
    files['/work/.cs/local/state'] = `claude_session_color: ${color}\nclaude_session_id: uuid-lead\n`
    await clearRun()
    sessionId = `uuid-${color}`
    await band()
  }
  expect(ran).toEqual([])
  expect(logs).toEqual([])
})

test('a conversation outside a cs session runs no color command', async () => {
  delete realPaths['/home/.claude-sessions/work']
  await band()
  await clearRun()
  sessionId = 'uuid-next'
  await band()
  expect(ran).toEqual([])
})

test('a conversation after /clear reapplies the session color once', async () => {
  await band()
  await clearRun()
  sessionId = 'uuid-next'
  expect(await band()).toBe(DRAWN)
  await band()
  await turnComplete()
  expect(ran).toEqual([{ command: 'color', args: 'red' }])
})

test('a /clear after a plugin reload reapplies the session color once', async () => {
  await band()
  // The harness captures hooks by matcher without the engine's On overloads.
  register(on as any)
  await clearRun()
  sessionId = 'uuid-next'
  await band()
  await band()
  expect(ran).toEqual([{ command: 'color', args: 'red' }])
})

test('a refused session color leaves the drawn tree intact and logs once', async () => {
  await band()
  await clearRun()
  sessionId = 'uuid-next'
  const run = $.command.run
  $.command.run = async (args) => { ran.push(args); throw new Error('command refused') }
  try {
    expect(await band()).toBe(DRAWN)
    expect(await band()).toBe(DRAWN)
  } finally {
    $.command.run = run
  }
  expect(ran).toEqual([{ command: 'color', args: 'red' }])
  expect(logs).toEqual(['/color red did not run: Error: command refused'])
})

test('a pending session color leaves rendering and running-turn guards responsive', async () => {
  arm(); percent = 80
  await band()
  await turnComplete()
  sessionId = 'uuid-fork'
  files['/work/.cs/local/state'] = 'claude_session_color: red\nclaude_session_id: uuid-fork\n'
  const run = $.command.run
  $.command.run = (args) => {
    if (args.command !== 'color') return run(args)
    ran.push(args)
    return new Promise(() => {})
  }
  try {
    const rendered = await Promise.race([band({ isWorking: true }), settle().then(() => 'render blocked')])
    expect(rendered).toBe(DRAWN)
    await tick(GRACE_SECONDS)
    expect(ran).toEqual([{ command: 'color', args: 'red' }])
    runResult = LISTED
    answer = QUEUE_START
    await queue('')
    await settle()
    expect(runs.map(x => x.argv[2])).toEqual(['/work', 'list', 'start'])
    expect(submitted).toEqual([])
    expect(logs).toEqual([])
  } finally {
    $.command.run = run
  }
})

test('a successor that starts past the threshold still gets the countdown once the person arms a handoff themselves', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  await clearRun()
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-next\n'
  percent = 75
  await turnComplete()
  expect(timers).toEqual([])
  arm()
  await turnComplete()
  expect(ticker()).toBeDefined()
})

test('a /clear before any turn ends still marks the next conversation as /clear-born: past the threshold it is not forced', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  await clearRun()
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-next\n'
  percent = 75
  await turnComplete()
  expect(timers).toEqual([])
  expect(toasts).toHaveLength(1)
})

test('a new conversation id with no /clear seen in this process is a resume: adopted and forced as asked', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  sessionId = 'uuid-resumed'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-resumed\n'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
})

test('the /clear the mod runs itself marks the successor as /clear-born too, so a wake past the threshold is not forced', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  await fireAfter() // the handoff pane's open, spent
  await findButton(await keys()).props.onPress()
  await fireAfter() // the footer's redraw for the count, spent
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  files = { '/work/.cs/local/state': 'claude_session_id: uuid-next\n' }
  sessionId = 'uuid-next'
  percent = 75
  await turnComplete()
  expect(timers.filter(t => t.kind === 'after' && !t.cancelled)).toEqual([])
  expect(toasts).toHaveLength(1)
})

test('a /clear whose successor never answers does not mark a later /resume as /clear-born: the band drawn in the successor consumes the birth', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  await clearRun()
  sessionId = 'uuid-wake'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-wake\n'
  await band()
  sessionId = 'uuid-resumed'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-resumed\n'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
})

test('resuming a conversation that was once judged adopts it afresh: the old judgment is dropped', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  await clearRun()
  sessionId = 'uuid-judged'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-judged\n'
  percent = 75
  await turnComplete()
  expect(timers).toEqual([])
  sessionId = 'uuid-other'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-other\n'
  percent = 20
  await turnComplete()
  sessionId = 'uuid-judged'
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-judged\n'
  percent = 75
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toHaveLength(1)
})

test('a /clear the mod runs itself that is rejected leaves no birth behind: a later /resume past the threshold is forced', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); percent = 80
  await keys()
  await turnComplete()
  await fireAfter() // the handoff pane's open, spent
  $.command.run = async () => { throw new Error('no session') }
  await tick(GRACE_SECONDS)
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  expect(toasts).toEqual(['/clear did not run: Error: no session'])
  await fireAfter() // the redraw the count's last tick asked for, spent
  files = { '/work/.cs/local/state': 'claude_session_id: uuid-resumed\n' }
  sessionId = 'uuid-resumed'
  percent = 72
  await turnComplete()
  expect(timers.filter(t => t.kind === 'after' && !t.cancelled)).toHaveLength(1)
  expect(toasts).toHaveLength(1)
})

test('a typed /clear that the engine refuses leaves no birth behind either', async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  percent = 30
  await turnComplete()
  const e = { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }
  await expect(hooks['command.run:clear']($, e, async () => { throw new Error('refused') })).rejects.toThrow('refused')
  files = { '/work/.cs/local/state': 'claude_session_id: uuid-resumed\n' }
  sessionId = 'uuid-resumed'
  percent = 72
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
  expect(toasts).toEqual([])
})

// The wrap key: a second button on the strip:jump2 action that runs /wrap. It
// draws only where the band draws unarmed; once a handoff is armed the band's
// one job is the /clear.
const wrapButton = (tree: any) => buttons(tree).find((b: any) => b.props.action === 'strip:jump2')
test('at the threshold the band adds a second button on strip:jump2 that reads as the wrap key, after the rotate key', async () => {
  percent = 40
  const tree = await keys()
  expect(buttons(tree)).toHaveLength(2)
  expect(buttons(tree)[0].props.action).toBe('strip:jump1')
  const button = wrapButton(tree)
  expect(button.props.hotkey).toBeUndefined()
  expect(button.props.plain).toBe(true)
  expect(wrapButton(tree).props.label).toBe('wrap')
})

// One key, then the engine's own dialog. /wrap replaces .cs/summary.md and
// runs two Opus passes, so the press asks rather than acts; a held `2` repeats
// on keydown (contract) and each repeat only re-opens the same question.
test('pressing 2 asks before /wrap, and only the yes runs it', async () => {
  percent = 40
  answer = WRAP_YES
  await wrapButton(await keys()).props.onPress()
  expect(asks).toEqual([{ question: WRAP_QUESTION, options: { header: 'Wrap', options: [WRAP_YES, 'Not now'] } }])
  expect(ran).toEqual([{ command: 'wrap', args: '' }])

  answer = 'Not now'
  await wrapButton(await keys()).props.onPress()
  expect(asks).toHaveLength(2)
  expect(ran).toHaveLength(1)

  // dismissed, or a `-p` run with nobody to ask: nothing runs and nothing is said
  answer = new Error('dismissed')
  await wrapButton(await keys()).props.onPress()
  expect(ran).toHaveLength(1)
  expect(toasts).toEqual([])
})

test('a /wrap the answer runs that the engine refuses is said once', async () => {
  percent = 40
  answer = WRAP_YES
  $.command.run = async () => { throw new Error('no session') }
  await wrapButton(await keys()).props.onPress()
  $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  expect(toasts).toEqual(['/wrap did not run: Error: no session'])
  expect(ran).toEqual([])
})

// A wrap that finished leaves nothing for the key to do until the conversation
// moves on. /wrap's last pass writes .cs/local/wrapped naming the conversation
// it ran in; the band draws the rotate key alone while the marker names this
// one, and the next turn that starts from a prompt empties it. A continuation
// (a turn started with no prompt, as a Stop hook's feedback starts one) does not.
// A summary written any other way proves nothing.
const WRAPPED = '/work/.cs/local/wrapped'
const turnStart = (text: string) => hooks['turn.start']($, { text, turnId: `turn-${text.length}` }, async (e: any) => ({ turnId: e.turnId }))
// A main-loop turn from its start to its end: the keys draw again once it is over.
const turn = async (text: string) => { await turnStart(text); await turnComplete() }

test('a finished wrap hides the wrap key until a turn starts from a prompt', async () => {
  percent = 40
  await turn('please wrap up')
  files[WRAPPED] = 'uuid-lead\n'
  expect(wrapButton(await keys())).toBeUndefined()
  expect(findButton(await keys()).props.action).toBe('strip:jump1')

  await turn('')
  expect(wrapButton(await keys())).toBeUndefined()

  await turn('next thing')
  expect(files[WRAPPED]).toBe('')
  expect(wrapButton(await keys())).toBeDefined()
})

// Work queued behind the wrap starts its own turn, and a second wrap that fails
// a pass writes no marker of its own: either way the first wrap's marker is gone.
test('queued work, or a second wrap that fails, brings the key back', async () => {
  percent = 40
  files[WRAPPED] = 'uuid-lead\n'
  await turn('and then fix the tests')
  expect(wrapButton(await keys())).toBeDefined()

  files[WRAPPED] = 'uuid-lead\n'
  await turn('/wrap')
  expect(wrapButton(await keys())).toBeDefined()
})

test('while git tracks the control files, a prompt leaves the wrap marker as git has it', async () => {
  percent = 40
  files[WRAPPED] = 'uuid-lead\n'
  runResult = tracked
  await turnStart('next thing')
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(written).toEqual({})
  expect(files[WRAPPED]).toBe('uuid-lead\n')
})

test('a summary with no wrap marker, or a marker naming another conversation, keeps the wrap key', async () => {
  percent = 40
  files['/work/.cs/summary.md'] = '# Session Summary\n'
  expect(wrapButton(await keys())).toBeDefined()
  files[WRAPPED] = 'uuid-teammate\n'
  expect(wrapButton(await keys())).toBeDefined()
  await turnStart('x')
  expect(files[WRAPPED]).toBe('uuid-teammate\n')
})

test('an armed handoff draws the clear key alone: no wrap key', async () => {
  arm(); percent = 90
  expect(buttons(await keys())).toHaveLength(1)
  expect(wrapButton(await keys())).toBeUndefined()
})

// The engine refuses a tree with a Button under an inline element (measured
// on 2.1.273: "Button inside an inline element; drawing the engine's own"),
// and the whole band vanishes with it.
function buttonsUnderText(tree: any, inText = false): number {
  if (!tree || typeof tree !== 'object') return 0
  // A list of children the fixture's h kept nested, as a map's result is.
  if (Array.isArray(tree)) return tree.reduce((n: number, c: any) => n + buttonsUnderText(c, inText), 0)
  if (tree.type === 'Button' && inText) return 1
  const inline = inText || tree.type === 'Text'
  return (tree.children ?? []).reduce((n: number, c: any) => n + buttonsUnderText(c, inline), 0)
}

test('no button is ever nested in a Text, armed or not, above the prompt or under it', async () => {
  // The count sees a Button under a Text through a nested list of children.
  expect(buttonsUnderText({ type: 'Text', props: {}, children: [[{ type: 'Button', props: {}, children: [] }]] })).toBe(1)
  files[WIDTH] = 'uuid-lead 60 4242\n'
  percent = 40
  queueTasks(2)
  const sites = async () => {
    const above = await band()
    const right = await footerMode(110)
    const inline = await footerHint(64)
    expect([above, right, inline].map(tree => buttons(tree).length)).toEqual([1, 2, 2])
    return [above, right, inline].map(tree => buttonsUnderText(tree))
  }
  await band()
  await settleTimers()
  expect(await sites()).toEqual([0, 0, 0])
  arm()
  const armed = [await band(), await footerMode(110), await footerHint(64)]
  expect(armed.map(tree => buttons(tree).length)).toEqual([0, 1, 1])
  expect(armed.map(tree => buttonsUnderText(tree))).toEqual([0, 0, 0])
})

// The contract lets a held key repeat on keydown, and a digit with no button
// on it lands in the composer (measured: a second `2` while armed typed `2`,
// and a non-empty composer takes every hotkey with it). So `2` keeps a button
// while armed: each press only re-arms, the window restarts, nothing is typed,
// and the confirmation sits on `3`.

// The count's colour ramp: the session's own colour while there is time, the
// bar's amber from ten seconds, its crit red under five. Inks KEEP IN SYNC
// with _sgr in bin/cs-statusline (tests/test_mod_rotate.sh pins them).
function texts(tree: any): any[] {
  if (!tree || typeof tree !== 'object') return []
  if (Array.isArray(tree)) return tree.flatMap(texts)
  const own = tree.type === 'Text' ? [tree] : []
  return [...own, ...(tree.children ?? []).flatMap(texts)]
}
// A Text's words, a Text nested in it (an inked lead) read in its place.
const textOf = (node: any): string => (node.children ?? []).map((c: any) => typeof c === 'string' ? c : c?.type === 'Text' ? textOf(c) : '').join('')
const HANDOFF_WITH_STEP = '---\nparent: uuid-lead\nstatus: unconsumed\n---\n\n# Next Step\n\nRun the secrets suites solo.\nTriage the store file.\n\n# Settled\n\nNothing.\n'
const countText = (tree: any) => texts(tree).find(t => /^in \d+s$/.test(textOf(t)))
const startGrace = async () => {
  envVars.CS_ROTATE_FORCE_CTX = '70'
  arm(); files[HANDOFF] = HANDOFF_WITH_STEP; percent = 80
  await band()
  await turnComplete()
}

test('the band\'s count ramps: session colour past ten seconds, amber from ten to five, crit red under five', async () => {
  envVars.CS_TERM_BG_RGB = '252;247;229'
  await startGrace()
  let count = countText(await keys())
  expect(count.props).toMatchObject({ bold: true, color: 'rgb(220,38,38)' })
  await tick(9) // 11 s left
  expect(countText(await keys()).props.color).toBe('rgb(220,38,38)')
  await tick(1) // 10
  expect(countText(await keys()).props.color).toBe('rgb(180,83,9)')
  await tick(5) // 5
  expect(countText(await keys()).props.color).toBe('rgb(180,83,9)')
  await tick(1) // 4
  count = countText(await keys())
  expect(textOf(count)).toBe('in 4s')
  expect(count.props.color).toBe('rgb(215,0,21)')
})

test('on a dark terminal the ramp takes the bar\'s dark inks', async () => {
  envVars.CS_TERM_BG_RGB = '30;30;30'
  envVars.CS_TERM_THEME = 'dark'
  files['/work/.cs/local/state'] = 'claude_session_color: cyan\nclaude_session_id: uuid-lead\n'
  await startGrace()
  expect(countText(await keys()).props.color).toBe('rgb(8,145,178)')
  await tick(10)
  expect(countText(await keys()).props.color).toBe('rgb(251,191,36)')
  await tick(6)
  expect(countText(await keys()).props.color).toBe('rgb(255,69,58)')
})

test('a session with no colour, or one outside the palette, keeps the band\'s own ink until the amber', async () => {
  files['/work/.cs/local/state'] = 'claude_session_color: chartreuse\nclaude_session_id: uuid-lead\n'
  await startGrace()
  expect(countText(await keys()).props.color).toBeUndefined()
  files['/work/.cs/local/state'] = 'claude_session_id: uuid-lead\n'
  expect(countText(await keys()).props.color).toBeUndefined()
  await tick(10)
  // no measured background and no theme: the light amber, as the bar picks
  expect(countText(await keys()).props.color).toBe('rgb(180,83,9)')
})


// The count's start toasts the handoff's next step, from a timer (the count
// starts inside the turn's own hook), so the twenty seconds are spent knowing
// what the next conversation will do. One toast per armed handoff: the band's
// redraws, and a count restarted for the same handoff, say nothing more.
test('the first count on an armed handoff toasts its next step once, from a timer', async () => {
  await startGrace()
  expect(toasts).toEqual([])
  await fireAfter()
  expect(toasts).toEqual(['next step: Run the secrets suites solo.'])
  await band(); await tick(2); await band()
  expect(toasts).toHaveLength(1)
  await promptSubmit()
  await turnComplete(); await fireAfter()
  expect(ticker()).toBeDefined()
  expect(toasts).toHaveLength(1)
})

test('a handoff armed after the /clear, in the same process, is toasted in its turn', async () => {
  await startGrace(); await fireAfter()
  await tick(GRACE_SECONDS)
  expect(ran).toEqual([{ command: 'clear', args: '' }])
  files[HANDOFF] = '---\nparent: uuid-two\nstatus: unconsumed\n---\n\n## 1. Next Step\n\nShip it.\n'
  sessionId = 'uuid-two'; percent = 10
  files['/work/.cs/local/state'] = 'claude_session_color: red\nclaude_session_id: uuid-two\n'
  await keys(); await turnComplete(); await fireAfter()
  expect(toasts).toEqual(['next step: Run the secrets suites solo.', 'next step: Ship it.'])
})

test('a count that ends before its timer fires, or a handoff with no next step, toasts nothing', async () => {
  await startGrace()
  await promptSubmit()
  await fireAfter()
  expect(toasts).toEqual([])
  register(on as any)
  arm(); files[HANDOFF] = '---\nparent: uuid-lead\nstatus: unconsumed\n---\n\nNo heading here.\n'
  await band(); await turnComplete(); await fireAfter()
  expect(ticker()).toBeDefined()
  expect(toasts).toEqual([])
})

// The count opens no pane and the /clear paths wait on none: nothing of the
// mod's opens, closes or lists a pane.
test('no path of the mod opens, closes or lists a pane', async () => {
  await startGrace(); await fireAfter()
  await promptSubmit()
  await turnComplete(); await fireAfter()
  await findButton(await keys()).props.onPress()
  await hooks['command.run:clear']($, { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }, async () => ({ text: '' }))
  register(on as any); arm()
  await keys(); await turnComplete(); await tick(GRACE_SECONDS)
  expect(ran.filter(r => r.command === 'clear')).toHaveLength(2)
  expect(panes).toEqual([])
  expect(hooks['ui.render:Pane']).toBeUndefined()
})

test('nextStepLine is the first line of the Next Step section, however the heading is numbered', () => {
  expect(nextStepLine(HANDOFF_WITH_STEP)).toBe('Run the secrets suites solo.')
  expect(nextStepLine('---\nstatus: unconsumed\n---\n\n## 1. Next Step\n\n  One thing.  \n\n- a\n')).toBe('One thing.')
  expect(nextStepLine('---\nstatus: unconsumed\n---\n\nNo heading here.\n')).toBeUndefined()
  expect(nextStepLine('# Next Step\n\n\n# Settled\n\nNothing.\n')).toBeUndefined()
})

test('a first line past the toast\'s length is cut there with an ellipsis', () => {
  const long = 'x'.repeat(NEXT_STEP_CHARS) + 'y'.repeat(10)
  expect(nextStepLine(`# Next Step\n\n${long}\nnext line\n`)).toBe('x'.repeat(NEXT_STEP_CHARS) + '\u2026')
  expect(nextStepLine(`# Next Step\n\n${'x'.repeat(NEXT_STEP_CHARS)}\n`)).toBe('x'.repeat(NEXT_STEP_CHARS))
})

test('a # line inside a fenced block belongs to the step, and a fence line is not the step\'s first line', () => {
  expect(nextStepLine('## Next Step\n\n```bash\n# build first\n./build.sh\n```\n\n## Settled\n')).toBe('# build first')
  expect(nextStepLine('## Next Step\n\n~~~\n```\n## not a heading\n~~~\nThen merge.\n')).toBe('```')
  expect(nextStepLine('## Next Step\n\n~~~\n\n## not a heading\n~~~\n')).toBe('## not a heading')
})

// /queue hands the task to `cs -queue add` by the path the launch exported,
// which resolves this session's queue from the environment claude inherited.
const startSession = () => hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
const queue = (args: string) => hooks['command.run:queue']($, { command: 'queue', args }, async () => ({ text: 'unhandled' }))

test('the mod registers /queue at load, to run at once even mid-turn', async () => {
  await startSession()
  expect(commands).toHaveLength(2)
  expect(commands[0]).toMatchObject({ name: 'queue', immediate: true, argumentHint: '[task]' })
  expect(commands[1]).toMatchObject({ name: 'cs', immediate: true, argumentHint: '[next|prev|first|last|<n>]' })
})

test('/queue with a task runs cs -queue add with the task as one argument and says it is queued', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  const r = await queue('fix the flaky "rotate" test; then rerun it')
  expect(runs.map(x => x.argv)).toEqual([['/opt/cs/bin/cs', '-queue', 'add', 'fix the flaky "rotate" test; then rerun it']])
  expect(r).toEqual({ text: 'Queued: fix the flaky "rotate" test; then rerun it' })
  expect(toasts).toEqual(['queued: fix the flaky "rotate" test; then rerun it'])
  await settle()
  expect(asks).toEqual([])
})

// The toast is one line under the prompt; a long task is cut so it fits.
test('/queue with a long task confirms it in a toast cut to 60 characters', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  const task = 'a'.repeat(59) + 'bc' + ' tail'
  await queue(`  ${task}  `)
  expect(toasts).toEqual([`queued: ${'a'.repeat(59)}b…`])
})

test('/queue with no task, or only spaces, prints cs -queue list', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = { exitCode: 0, stdout: 'Queued:\n  1. first\n  2. second\n', stderr: '' }
  expect(await queue('')).toEqual({ text: 'Queued:\n  1. first\n  2. second' })
  expect(await queue('   ')).toEqual({ text: 'Queued:\n  1. first\n  2. second' })
  expect(runs.map(x => x.argv)).toEqual([['/opt/cs/bin/cs', '-queue', 'list'], ['/opt/cs/bin/cs', '-queue', 'list']])
  expect(toasts).toEqual([])
})

// The offer is made after the listing is back on screen, so the person reads
// the tasks before answering; the drain itself belongs to the Stop hook.
const settle = () => new Promise(r => setTimeout(r, 0))
const LISTED = { exitCode: 0, stdout: 'Queued (2)\n  1. first\n  2. second\n\nDone (1)\n  - shipped\n', stderr: '' }

test('/queue with pending tasks offers to start them; Start while idle arms the queue and starts a turn', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_START
  expect(await queue('')).toEqual({ text: 'Queued (2)\n  1. first\n  2. second\n\nDone (1)\n  - shipped' })
  await settle()
  expect(asks).toEqual([
    { question: 'Start the 2 queued tasks now?', options: { header: 'Queue', options: [QUEUE_START, 'Not yet', QUEUE_COMPACT] } },
    { question: QUEUE_MODE_QUESTION, options: { header: 'Queue', options: [QUEUE_HERE, QUEUE_SUBAGENTS, QUEUE_WORKFLOWS] } },
  ])
  expect(runs.map(x => x.argv)).toEqual([['/opt/cs/bin/cs', '-queue', 'list'], ['/opt/cs/bin/cs', '-queue', 'start']])
  expect(submitted).toEqual([{ text: QUEUE_KICK }])
})

// Start also asks how the tasks run: here, each in a subagent, or each as a
// workflow; the answer rides on cs -queue start.
test('Start then In subagents or As workflows arms the queue in that mode', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_START
  modeAnswer = QUEUE_SUBAGENTS
  await queue('')
  await settle()
  modeAnswer = QUEUE_WORKFLOWS
  await queue('')
  await settle()
  expect(runs.map(x => x.argv.slice(1))).toEqual([['-queue', 'list'], ['-queue', 'start', 'subagents'], ['-queue', 'list'], ['-queue', 'start', 'workflow']])
})

test('Not yet asks nothing more', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = 'Not yet'
  await queue('')
  await settle()
  expect(asks.map(a => a.question)).toEqual(['Start the 2 queued tasks now?'])
})

// A dismissed second question starts nothing and compacts nothing, as a
// dismissed first one does.
test('a dismissed mode question starts nothing', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  modeAnswer = new Error('dismissed')
  for (const a of [QUEUE_START, QUEUE_COMPACT]) {
    answer = a
    await queue('')
    await settle()
  }
  expect(runs.map(x => x.argv[2])).toEqual(['list', 'list'])
  expect(compactedAt).toEqual([])
  expect(submitted).toEqual([])
})

// Free text typed under "Other" names no mode cs knows, so nothing starts.
test('an answer that is no mode starts nothing and says so', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_START
  modeAnswer = 'in parallel please'
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
  expect(toasts).toEqual(["'in parallel please' is not a way to run the queue; it is not started"])
})

test('Compact asks the mode before compacting, then starts in it', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_COMPACT
  modeAnswer = QUEUE_WORKFLOWS
  await queue('')
  await settle()
  expect(asks.map(a => a.question)).toEqual(['Start the 2 queued tasks now?', QUEUE_MODE_QUESTION])
  expect(compactedAt).toEqual([1])
  expect(runs.map(x => x.argv.slice(1))).toEqual([['-queue', 'list'], ['-queue', 'start', 'workflow']])
})

// A turn already running reaches a stop on its own, where the Stop hook hands
// over the first task; a prompt sent now would wait out the whole drain.
test('Start while a turn is running arms the queue and sends no prompt', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_START
  await band({ isWorking: true })
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list', 'start'])
  expect(submitted).toEqual([])
})

// Not yet leaves the queue as it is: the band keeps offering its start key.
test('Not yet runs nothing and sends no prompt', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = 'Not yet'
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
  expect(submitted).toEqual([])
})

test('a queue already armed or draining is listed without an offer', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  for (const state of ['armed\n', 'draining\n']) {
    files['/work/.cs/local/queue.state'] = state
    await queue('')
    await settle()
  }
  expect(asks).toEqual([])
  expect(runs.map(x => x.argv[2])).toEqual(['list', 'list'])
})

test('an encrypted session\'s queue state is read behind .cs/private', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  files['/work/.cs/private/queue.state'] = 'draining\n'
  await queue('')
  await settle()
  expect(asks).toEqual([])
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
})

test('an empty queue is listed without an offer', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = { exitCode: 0, stdout: 'Queue is empty.\n\nDone (1)\n  - shipped\n', stderr: '' }
  await queue('')
  await settle()
  expect(asks).toEqual([])
})

test('a start cs refuses, or one that cannot run, says so and sends no prompt', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  answer = QUEUE_START
  nextRuns = [LISTED, { exitCode: 1, stdout: '', stderr: 'Error: the queue is locked\n' }, LISTED, new Error('spawn ENOENT')]
  await queue('')
  await settle()
  await queue('')
  await settle()
  expect(toasts).toEqual(['cs -queue start exited 1: Error: the queue is locked', 'cs -queue start did not run: spawn ENOENT'])
  expect(submitted).toEqual([])
})

test('a prompt the engine refuses is shown, not dropped', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_START
  $.prompt.submit = async () => { throw new Error('session closed') }
  try {
    await queue('')
    await settle()
  } finally {
    $.prompt.submit = async (args: any) => { submitted.push(args); return {} }
  }
  expect(toasts).toEqual(['the queue is armed, but its first turn did not start: session closed'])
})

// Compact frees the context the drain will need first: the conversation is
// compacted before the queue is armed, so a compaction that does not happen
// leaves the queue exactly as it was.
test('Compact compacts the conversation, then arms the queue and starts a turn', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_COMPACT
  await queue('')
  await settle()
  expect(compactedAt).toEqual([1])
  expect(runs.map(x => x.argv[2])).toEqual(['list', 'start'])
  expect(submitted).toEqual([{ text: QUEUE_KICK }])
  expect(toasts).toEqual([])
})

test('a compaction a hook vetoes leaves the queue unarmed and says why', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_COMPACT
  compactResult = { skip: 'a PreCompact hook blocked it' }
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
  expect(submitted).toEqual([])
  expect(toasts).toEqual(['the conversation was not compacted (a PreCompact hook blocked it); the queue is not started'])
})

// The engine refuses a compaction while a turn runs.
test('a compaction the engine refuses leaves the queue unarmed and says so', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = QUEUE_COMPACT
  compactResult = new Error('a turn is running')
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
  expect(submitted).toEqual([])
  expect(toasts).toEqual(['the conversation was not compacted (a turn is running); the queue is not started'])
})

test('a dismissed offer runs nothing more', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = LISTED
  answer = new Error('dismissed')
  await queue('')
  await settle()
  expect(runs.map(x => x.argv[2])).toEqual(['list'])
  expect(submitted).toEqual([])
  expect(toasts).toEqual([])
})

test('a refused add prints the exit code and cs\'s own stderr, verbatim', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = { exitCode: 1, stdout: '', stderr: "warning: an earlier line\n\nError: task bodies must be a single line (the queue's done log and listing are line-oriented)\n" }
  const r = await queue('one\ntwo')
  expect(runs[0].argv).toEqual(['/opt/cs/bin/cs', '-queue', 'add', 'one\ntwo'])
  expect(r).toEqual({ text: "cs -queue add exited 1.\nwarning: an earlier line\nError: task bodies must be a single line (the queue's done log and listing are line-oriented)" })
  expect(toasts).toEqual([])
})

test('a run that cannot start says why', async () => {
  envVars.CS_BIN = '/opt/cs/bin/cs'
  runResult = new Error('spawn ENOENT')
  expect(await queue('')).toEqual({ text: 'cs -queue list did not run: spawn ENOENT' })
})

test('without CS_BIN /queue says the launch did not say where cs is, and runs nothing', async () => {
  delete envVars.CS_BIN
  const r = await queue('something')
  expect(runs).toHaveLength(0)
  expect(r).toEqual({ text: 'The launch did not say where cs is (CS_BIN); run `cs -queue add "<task>"` from a shell in this session.' })
})

// The band's start key: tasks queued and nothing running them. cs writes one
// file per task in the queue directory, behind .cs/private in an encrypted
// session and in .cs/local otherwise.
const QDIR = '/work/.cs/local/queue'
const queueTasks = (n: number, dir = QDIR) => { for (let i = 1; i <= n; i++) files[`${dir}/000000000${i}-seed`] = `task ${i}\n` }
const queueKey = (tree: any) => buttons(tree).find((b: any) => b.props.key === 'cs-queue')
// The band body's elements in order, with the conditional gaps left out:
// the actions, the spacer, then the right edge's own elements in its place.
const bandBody = (tree: any): any[] => {
  if (!tree || typeof tree !== 'object') return []
  const kept = (node: any) => (node.children ?? []).flat(Infinity).filter((c: any) => c && typeof c === 'object')
  if (tree.props?.key === 'cs-rotate-band') return kept(tree).flatMap((c: any) => c.props?.key === 'cs-status' ? kept(c) : [c])
  return (tree.children ?? []).flatMap(bandBody)
}

test('a queue with tasks and nothing running them draws a start key, below the threshold too', async () => {
  queueTasks(2)
  const tree = await band()
  expect(buttons(tree).map((b: any) => b.props.label)).toEqual(['\u25a4 run 2 queued tasks'])
  expect(queueKey(tree).props).toMatchObject({ key: 'cs-queue', plain: true })
  expect(queueKey(tree).props.action).toBeUndefined()
  expect(buttonsUnderText(tree)).toBe(0)
})

test('the start key is gone while the queue is armed or draining, and while it is empty', async () => {
  expect(await band()).toBe(DRAWN)
  queueTasks(1)
  for (const state of ['armed\n', 'draining\n']) {
    files['/work/.cs/local/queue.state'] = state
    expect(queueKey(await band())).toBeUndefined()
  }
  files['/work/.cs/local/queue.state'] = 'idle\n'
  expect(queueKey(await band()).props.label).toBe('\u25a4 run 1 queued task')
})

test('past the threshold the start key stands alone on the band, and the rotate and wrap keys under the prompt', async () => {
  percent = 40
  queueTasks(3)
  const tree = await band()
  expect(buttons(tree).map((b: any) => b.props.key)).toEqual(['cs-queue'])
  expect(bandBody(tree)).toEqual([queueKey(tree)])
  expect(buttonsUnderText(tree)).toBe(0)
  expect(buttons(await footerHint()).map((b: any) => b.props.key)).toEqual(['cs-rotate', 'cs-wrap'])
})

test('an armed handoff draws the clear key alone, whatever is queued', async () => {
  arm()
  queueTasks(2)
  expect(buttons(await keys()).map((b: any) => b.props.key)).toEqual(['cs-rotate'])
})

test('a teammate conversation, or one cs did not launch, gets no start key', async () => {
  queueTasks(2)
  sessionId = 'uuid-teammate'
  expect(await band()).toBe(DRAWN)
  sessionId = 'uuid-lead'
  cwdPath = '/elsewhere'
  expect(await band()).toBe(DRAWN)
})

test('an encrypted session counts its tasks, and reads its state, behind .cs/private', async () => {
  existing.add('/work/.cs/private')
  queueTasks(5)
  queueTasks(2, '/work/.cs/private/queue')
  expect(queueKey(await band()).props.label).toBe('\u25a4 run 2 queued tasks')
  files['/work/.cs/private/queue.state'] = 'draining\n'
  const tree = await band()
  expect(queueKey(tree)).toBeUndefined()
  expect(restingWords(tree)).toEqual(['\u25a4 queue 2 running'])
})

test('pressing the start key asks to start and how, then starts the queue and its first turn', async () => {
  queueTasks(2)
  answer = QUEUE_START
  modeAnswer = QUEUE_SUBAGENTS
  queueKey(await band()).props.onPress()
  await settle()
  expect(asks).toEqual([
    { question: 'Start the 2 queued tasks now?', options: { header: 'Queue', options: [QUEUE_START, 'Not yet', QUEUE_COMPACT] } },
    { question: QUEUE_MODE_QUESTION, options: { header: 'Queue', options: [QUEUE_HERE, QUEUE_SUBAGENTS, QUEUE_WORKFLOWS] } },
  ])
  expect(runs.map(r => r.argv)).toEqual([['/opt/cs/bin/cs', '-queue', 'start', 'subagents']])
  expect(submitted).toEqual([{ text: QUEUE_KICK }])
})

test('a press after the queue was started, or emptied, asks nothing', async () => {
  queueTasks(1)
  const key = queueKey(await band())
  files['/work/.cs/local/queue.state'] = 'armed\n'
  key.props.onPress()
  await settle()
  delete files['/work/.cs/local/queue.state']
  delete files[`${QDIR}/0000000001-seed`]
  key.props.onPress()
  await settle()
  expect(asks).toEqual([])
  expect(runs).toEqual([])
})

test('without CS_BIN a press says where to start the queue, and runs nothing', async () => {
  queueTasks(1)
  delete envVars.CS_BIN
  queueKey(await band()).props.onPress()
  await settle()
  expect(asks).toEqual([])
  expect(runs).toEqual([])
  expect(toasts).toEqual(['the launch did not say where cs is (CS_BIN); run cs -queue start from a shell in this session'])
})

// /finish progress: cs writes one record per step while it integrates and
// retires; the mod reads it on a one-second watch that /finish starts.
const RECORD = '/work/.cs/local/finish-progress.json'
const SHA = '1234567' + 'f'.repeat(33)
const RESULT = '89abcde' + '0'.repeat(33)
const NOW = 1_800_000_000
const record = (r: any, path = RECORD) => { files[path] = JSON.stringify(r) }
const running = (step: string, extra: any = {}) => ({ id: '4242-1799999990', pid: 4242, task: 'fix-auth', sha: SHA, step, ts: NOW, ...extra })
const startFinish = () => hooks['skill.prompt:finish']($, { skill: 'finish', text: 'land it' }, async (e: any) => ({ text: e.text }))
const watches = () => timers.filter(t => t.kind === 'every' && t.ms === 1000)
const watchTick = async () => {
  const live = watches().filter(t => !t.cancelled)
  expect(live).toHaveLength(1)
  await live[0].fn()
}

test('/finish starts one watch, passes its prompt through, and never toasts the outcome of an earlier run', async () => {
  record({ id: '100-1', pid: 100, task: 'old-task', sha: SHA, step: 'landed', result: RESULT, ts: 1 })
  expect(await startFinish()).toEqual({ text: 'land it' })
  await startFinish()
  expect(watches()).toHaveLength(1)
  await watchTick()
  expect(toasts).toEqual([])
})

test('a /finish that starts toasts its task once, however many steps follow', async () => {
  livePids.add('4242')
  await startFinish()
  record(running('started'))
  await watchTick()
  record(running('merging'))
  await watchTick()
  record(running('fast-forward'))
  await watchTick()
  expect(toasts).toEqual(['finishing fix-auth'])
})

test('each outcome toasts once, in its own words, and not again on the next tick', async () => {
  await startFinish()
  record(running('landed', { result: RESULT }))
  await watchTick()
  await watchTick()
  record({ id: '5151-1800000001', pid: 5151, task: 'fix-auth', sha: SHA, step: 'refused', reason: 'Base /work moved during the gates (was abc, now def); re-run /finish fix-auth', ts: NOW })
  await watchTick()
  await watchTick()
  record({ id: '6161-1800000002', pid: 6161, task: 'fix-auth', sha: SHA, step: 'retired', ts: NOW })
  await watchTick()
  await watchTick()
  expect(toasts).toEqual([
    'landed fix-auth 1234567 -> 89abcde',
    '/finish fix-auth refused: Base /work moved during the gates (was abc, now def); re-run /finish fix-auth',
    'retired fix-auth',
  ])
})

test('a long task is cut in the toast as /queue cuts it', async () => {
  livePids.add('4242')
  await startFinish()
  record(running('started', { task: 'a'.repeat(59) + 'bc tail' }))
  await watchTick()
  expect(toasts).toEqual([`finishing ${'a'.repeat(59)}b…`])
})

test('an encrypted session\'s record is read behind .cs/private', async () => {
  await startFinish()
  record({ id: '6161-1800000002', pid: 6161, task: 'fix-auth', sha: SHA, step: 'retired', ts: NOW }, '/work/.cs/private/finish-progress.json')
  await watchTick()
  expect(toasts).toEqual(['retired fix-auth'])
})

test('while a gate runs under a live pid the band shows the task and the time since the gate started, even mid-turn', async () => {
  livePids.add('4242')
  nowMs = NOW * 1000
  await startFinish()
  record(running('gate', { gate_started: NOW - 75 }))
  await watchTick()
  expect(invalidated).toContain('ui.render')
  const tree = JSON.stringify(await band({ isWorking: true }))
  expect(tree).toContain('"Survey"')
  expect(tree).toContain('finishing fix-auth · gate 1m 15s')
  nowMs += 10_000
  expect(JSON.stringify(await band({ isWorking: true }))).toContain('finishing fix-auth · gate 1m 25s')
  nowMs = (NOW - 75 + 42) * 1000
  expect(JSON.stringify(await band({ isWorking: true }))).toContain('finishing fix-auth · gate 42s')
})

test('a gate whose pid is dead, or a record past its gate, draws no band', async () => {
  nowMs = NOW * 1000
  await startFinish()
  record(running('gate', { gate_started: NOW - 5 }))
  await watchTick()
  expect(await band({ isWorking: true })).toBe(DRAWN)
  livePids.add('4242')
  await watchTick()
  expect(JSON.stringify(await band({ isWorking: true }))).toContain('gate 5s')
  record(running('fast-forward', { gate_started: NOW - 5 }))
  invalidated = []
  await watchTick()
  expect(invalidated).toContain('ui.render')
  expect(await band({ isWorking: true })).toBe(DRAWN)
  record(running('gate', { gate_started: NOW - 5 }))
  await watchTick()
  record(running('landed', { gate_started: NOW - 5, result: RESULT }))
  await watchTick()
  expect(await band({ isWorking: true })).toBe(DRAWN)
})

test('with the rotation keys up, the gate word is the band\'s last word, dim, across the spacer at the right edge, and both keys stay under the prompt', async () => {
  livePids.add('4242')
  nowMs = NOW * 1000
  percent = 40
  await startFinish()
  record(running('gate', { gate_started: NOW - 3 }))
  await watchTick()
  const tree = await band()
  expect(buttons(await footerHint())).toHaveLength(2)
  const body = bandBody(tree)
  expect(body.at(-1)).toMatchObject({ type: 'Text', props: { dimColor: true }, children: ['finishing fix-auth · gate 3s'] })
  expect(body.at(-2)).toMatchObject({ type: 'Box', props: { key: 'cs-spacer', flexGrow: 1 }, children: [] })
  expect(boxes(tree).filter((b: any) => b.props.key === 'cs-rotate-band')).toHaveLength(1)
  expect(JSON.stringify(tree)).not.toContain('backgroundColor')
})

test('alone, the gate word draws on the thin line with no separator', async () => {
  livePids.add('4242')
  nowMs = NOW * 1000
  await startFinish()
  record(running('gate', { gate_started: NOW - 3 }))
  await watchTick()
  const tree = await band({ isWorking: true })
  expect(buttons(tree)).toEqual([])
  expect(words(tree)).toEqual(['finishing fix-auth · gate 3s'])
  expect(boxes(tree).find((b: any) => b.props.key === 'cs-rotate-band').props.marginLeft).toBe(2)
})

test('the watch ends once the turn is over and nothing runs, and not while a step still runs', async () => {
  livePids.add('4242')
  await startFinish()
  record(running('gate', { gate_started: NOW }))
  await watchTick()
  await hooks['turn.complete']($, { reason: 'answer' }, async () => ({ text: '' }))
  await watchTick()
  expect(watches()[0].cancelled).toBe(false)
  record({ id: '6161-1800000002', pid: 6161, task: 'fix-auth', sha: SHA, step: 'retired', ts: NOW })
  await watchTick()
  expect(toasts).toEqual(['finishing fix-auth', 'retired fix-auth'])
  expect(watches()[0].cancelled).toBe(true)
  // the next /finish watches afresh
  await startFinish()
  expect(watches().filter(t => !t.cancelled)).toHaveLength(1)
})

// ---------------------------------------------------------------------------
// The rail: one tick per prompt on the transcript's live branch.

// The session's transcript: Claude Code keeps it under ~/.claude/projects/<slug>/<id>.jsonl,
// the slug the cwd with every character outside [A-Za-z0-9] made `-`.
const TRANSCRIPT = '/home/.claude/projects/-work/uuid-lead.jsonl'
const row = (o: Record<string, unknown>) => JSON.stringify(o)
const prompt = (uuid: string, parent: string | null, text: unknown, extra: Record<string, unknown> = {}) =>
  row({ uuid, parentUuid: parent, type: 'user', message: { role: 'user', content: text }, ...extra })
const reply = (uuid: string, parent: string) =>
  row({ uuid, parentUuid: parent, type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'ok' }] } })
const LINEAR = [
  prompt('u1', null, 'say one'), reply('a1', 'u1'),
  prompt('u2', 'a1', 'say two'), reply('a2', 'u2'),
  prompt('u3', 'a2', 'say three\nwith a second line'), reply('a3', 'u3'),
  prompt('u4', 'a3', '  say four  '), reply('a4', 'u4'),
]
const transcript = (lines: string[], mtime = 1) => { files[TRANSCRIPT] = `${lines.join('\n')}\n`; mtimes[TRANSCRIPT] = mtime }
const sessionStart = () => hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e: any) => ({ cwd: e.cwd }))
// A UserMessage row as the engine draws it, reporting what of it is on screen.
const drawRow = (requestId: string, text: string, onScreen: any) =>
  hooks['ui.render:UserMessage']($, { requestId, component: 'UserMessage', surface: 'terminal', props: { text, origin: { kind: 'composer' }, isExpanded: false, onScreen } }, async (e: any) => e)
const cs = (args: string) => hooks['command.run:cs']($, { command: 'cs', args }, async () => ({ text: 'unhandled' }))
// The rail's glyphs in order: the `…N` run (a Text in the Box that holds the cell after it), then each tick's label (a Button, or the Text the named prompt's tick is).
const rail = (tree: any): string[] => {
  const box = boxes(tree).find((b: any) => b.props.key === 'cs-rail')
  if (box === undefined) return []
  return (box.children ?? []).flat().filter((c: any) => c && typeof c === 'object')
    .map((c: any) => (c.type === 'Button' ? c.props.label : c.type === 'Box' ? c.children.map(textOf).join('') : textOf(c)))
}
const tickButtons = (tree: any) => buttons(tree).filter((b: any) => /^cs-rail-\d+$/.test(b.props.key))

test('the live branch of a linear transcript lists every prompt, first line trimmed and cut to 80 characters', () => {
  const long = prompt('u5', 'a4', 'x'.repeat(100))
  expect(parsePrompts(`${[...LINEAR, long].join('\n')}\n`)).toEqual([
    { uuid: 'u1', text: 'say one' }, { uuid: 'u2', text: 'say two' }, { uuid: 'u3', text: 'say three' }, { uuid: 'u4', text: 'say four' },
    { uuid: 'u5', text: `${'x'.repeat(RAIL_TEXT_CHARS - 1)}\u2026` },
  ])
})

test('the cut keeps whole graphemes: an emoji at the cut is kept whole, never half a surrogate pair', () => {
  const long = prompt('u5', 'a4', `${'a'.repeat(RAIL_TEXT_CHARS - 2)}\u{1F600}${'b'.repeat(10)}`)
  const text = parsePrompts(`${[...LINEAR, long].join('\n')}\n`).at(-1)!.text
  expect(text).toBe(`${'a'.repeat(RAIL_TEXT_CHARS - 2)}\u{1F600}…`)
  expect(text.isWellFormed()).toBe(true)
})

test('a /rewind leaves its abandoned prompts off the branch: the walk follows parentUuid back from the last row', () => {
  const forked = [...LINEAR, prompt('u5', 'a2', 'say five instead'), reply('a5', 'u5')]
  expect(parsePrompts(forked.join('\n')).map(p => p.text)).toEqual(['say one', 'say two', 'say five instead'])
})

test('a /compact boundary row links the branch on through logicalParentUuid', () => {
  const compacted = [
    ...LINEAR,
    row({ uuid: 'b1', parentUuid: null, logicalParentUuid: 'a4', type: 'system', subtype: 'compact_boundary' }),
    prompt('s1', 'b1', 'This session is being continued from a previous conversation', { isCompactSummary: true }),
    prompt('u5', 's1', 'say five'), reply('a5', 'u5'),
  ]
  expect(parsePrompts(compacted.join('\n')).map(p => p.text)).toEqual(['say one', 'say two', 'say three', 'say four', 'say five'])
})

test('tool results, command echoes, meta rows, sidechains, system-origin rows and a torn line are not prompts', () => {
  const noisy = [
    prompt('u1', null, 'say one'), reply('a1', 'u1'),
    prompt('t1', 'a1', [{ type: 'tool_result', tool_use_id: 'x', content: 'done' }]), reply('a2', 't1'),
    prompt('c1', 'a2', '<command-message>rotate</command-message>\n<command-name>/rotate</command-name>'), reply('a3', 'c1'),
    prompt('m1', 'a3', 'Stop hook feedback: narrative check', { isMeta: true }), reply('a4', 'm1'),
    prompt('n1', 'a4', '<task-notification>\n<task-id>b1</task-id>\n</task-notification>', { origin: { kind: 'task-notification' } }), reply('a5', 'n1'),
    prompt('side', 'a5', 'a subagent prompt', { isSidechain: true }),
    prompt('u2', 'a5', [{ type: 'text', text: 'say two' }]), reply('a6', 'u2'),
    '{"uuid":"torn","parentUuid":"a6","type":"us',
  ]
  expect(parsePrompts(noisy.join('\n')).map(p => p.text)).toEqual(['say one', 'say two'])
})

test('after a turn ends the band draws one tick per prompt, the newest thick while no row has reported', async () => {
  transcript(LINEAR)
  await turnComplete()
  expect(invalidated).toContain('ui.render')
  const tree = await band()
  expect(rail(tree)).toEqual(['\u2502', '\u2502', '\u2502', '\u2503'])
  expect(tickButtons(tree).map((b: any) => b.props.key)).toEqual(['cs-rail-0', 'cs-rail-1', 'cs-rail-2'])
  for (const b of tickButtons(tree)) expect(b.props).toMatchObject({ plain: true, dimColor: true })
  expect(tickButtons(tree).some((b: any) => b.props.hotkey !== undefined)).toBe(false)
  expect(buttonsUnderText(tree)).toBe(0)
  expect(texts(boxes(tree).find((b: any) => b.props.key === 'cs-rail')).find((t: any) => textOf(t) === '\u2503').props).toEqual({ dimColor: true })
  // Below the threshold the rail still draws, with no key words, its last bar in the line's last cell and the
  // read prompt three cells before it; the name holds the widest prompt a bar can swap in, `#3 say three`.
  expect(restingWords(tree)).toEqual([' #4 say four', '\u2503'])
  expect(bandLine(tree, 110)).toBe(`  ${' '.repeat(90)}#4 say four   \u2502\u2502\u2502\u2503`)
})

test('a conversation with one prompt draws no rail', async () => {
  transcript(LINEAR.slice(0, 2))
  percent = 40
  await turnComplete()
  expect(await band()).toBe(DRAWN)
})

test('the transcript is read again only when its size or mtime changed', async () => {
  transcript(LINEAR)
  await turnComplete()
  await turnComplete()
  expect(reads.filter(p => p === TRANSCRIPT)).toHaveLength(1)
  transcript(LINEAR, 2)
  await turnComplete()
  expect(reads.filter(p => p === TRANSCRIPT)).toHaveLength(2)
  files[TRANSCRIPT] += prompt('u5', 'a4', 'say five')
  await turnComplete()
  expect(reads.filter(p => p === TRANSCRIPT)).toHaveLength(3)
  expect(rail(await band())).toHaveLength(5)
})

test('CS_TRANSCRIPTS_DIR and a session\'s own claude-config move the transcript; the slug follows the resolved cwd', async () => {
  envVars.CS_TRANSCRIPTS_DIR = '/elsewhere'
  files['/elsewhere/-work/uuid-lead.jsonl'] = `${LINEAR.join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(4)
  delete envVars.CS_TRANSCRIPTS_DIR
  existing.add('/work/.cs/claude-config')
  files['/work/.cs/claude-config/projects/-work/uuid-lead.jsonl'] = `${LINEAR.slice(0, 6).join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(3)
  existing.delete('/work/.cs/claude-config')
  realPaths['/work'] = '/Volumes/data/work.dir'; realPaths['/home/.claude-sessions/work'] = '/Volumes/data/work.dir'
  files['/home/.claude/projects/-Volumes-data-work-dir/uuid-lead.jsonl'] = `${LINEAR.slice(0, 4).join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(2)
})

test('a CLAUDE_CONFIG_DIR the person exported holds the transcript, after CS_TRANSCRIPTS_DIR and the session\'s own claude-config', async () => {
  envVars.CLAUDE_CONFIG_DIR = '/cfg'
  files['/cfg/projects/-work/uuid-lead.jsonl'] = `${LINEAR.join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(4)
  envVars.CS_TRANSCRIPTS_DIR = '/elsewhere'
  files['/elsewhere/-work/uuid-lead.jsonl'] = `${LINEAR.slice(0, 6).join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(3)
  existing.add('/work/.cs/claude-config')
  files['/work/.cs/claude-config/projects/-work/uuid-lead.jsonl'] = `${LINEAR.slice(0, 4).join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(2)
})

test('this claude\'s CLAUDE_CONFIG_DIR holds its transcript even when it names another session\'s .cs/claude-config; neither ~/.claude nor CLAUDE_SECURESTORAGE_CONFIG_DIR stands in', async () => {
  envVars.CLAUDE_CONFIG_DIR = '/other/.cs/claude-config'
  files['/other/.cs/claude-config/projects/-work/uuid-lead.jsonl'] = `${LINEAR.join('\n')}\n`
  files[TRANSCRIPT] = `${LINEAR.slice(0, 6).join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(4)
  envVars.CLAUDE_SECURESTORAGE_CONFIG_DIR = '/shell'
  files['/shell/projects/-work/uuid-lead.jsonl'] = `${LINEAR.slice(0, 4).join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(4)
})

test('a session\'s own claude-config whose link dangles, its vault locked, still names the transcript\'s dir; the shell\'s never stands in', async () => {
  danglingLinks.add('/work/.cs/claude-config')
  envVars.CLAUDE_CONFIG_DIR = '/work/.cs/claude-config'
  transcript(LINEAR)
  await turnComplete()
  expect(rail(await band())).toHaveLength(0)
  expect(reads).not.toContain(TRANSCRIPT)
  danglingLinks.delete('/work/.cs/claude-config')
  existing.add('/work/.cs/claude-config')
  files['/work/.cs/claude-config/projects/-work/uuid-lead.jsonl'] = `${LINEAR.slice(0, 6).join('\n')}\n`
  await turnComplete()
  expect(rail(await band())).toHaveLength(3)
})

test('past the width budget the oldest prompts collapse into one dim …N run at the left', async () => {
  register(on as any)
  Object.assign(envVars, UNCAPPED)
  const many = [prompt('u1', null, 'p1')]
  for (let i = 2; i <= 30; i++) many.push(reply(`a${i - 1}`, `u${i - 1}`), prompt(`u${i}`, `a${i - 1}`, `p${i}`))
  transcript(many)
  await turnComplete()
  // After the two-column inset 8 columns leave 6 cells for 30 ticks, so 28
  // collapse into `…28`, a cell, and two ticks follow.
  const glyphs = rail(await band({ bodyColumns: 8 }))
  expect(glyphs).toEqual(['\u202628', '\u2502', '\u2503'])
  expect(tickButtons(await band({ bodyColumns: 8 })).map((b: any) => b.props.key)).toEqual(['cs-rail-28'])
  expect(texts(await band({ bodyColumns: 8 })).find((t: any) => textOf(t) === '\u202628').props).toEqual({ dimColor: true })
  expect(bandLine(await band({ bodyColumns: 8 }), 8)).toBe('  \u202628 \u2502\u2503')
  // A cell fewer folds one more: the cell after the run is the run's to keep.
  expect(bandLine(await band({ bodyColumns: 7 }), 7)).toBe('  \u202629 \u2503')
  // Wide enough, every tick draws.
  expect(rail(await band({ bodyColumns: 110 }))).toHaveLength(30)
})

test('the prompt being read is the on-screen row drawn highest, the earliest on ties; a first null report leaves nothing, a later one removes the report; placeholder is ignored', async () => {
  register(on as any)
  Object.assign(envVars, READING)
  transcript(LINEAR)
  await turnComplete()
  await drawRow('placeholder', 'say four', { first: 0, last: 1, of: 2 })
  await drawRow('u1', 'say one', { first: 0, last: 1, of: 2 })
  await drawRow('u2', 'say two', { first: 3, last: 5, of: 6 })
  // A row's first render reports null before it is laid out: nothing changes.
  await drawRow('r3', 'say three\nwith a second line', null)
  expect(rail(await band())).toEqual(['\u2502', '\u2503', '\u2502', '\u2502'])
  // A null after a report is the row scrolled out of view: its report goes.
  await drawRow('u2', 'say two', null)
  expect(rail(await band())).toEqual(['\u2503', '\u2502', '\u2502', '\u2502'])
  // Everything visible reports 0: the topmost, the earliest of them, is being read.
  await drawRow('u2', 'say two', { first: 0, last: 5, of: 6 })
  await drawRow('r3', 'say three\nwith a second line', { first: 0, last: 1, of: 2 })
  expect(rail(await band())).toEqual(['\u2503', '\u2502', '\u2502', '\u2502'])
  // The person scrolled up: the first prompt's row is now the one cut at the top.
  await drawRow('u1', 'say one', { first: 2, last: 4, of: 6 })
  expect(rail(await band())).toEqual(['\u2503', '\u2502', '\u2502', '\u2502'])
})

test('a report that moves the read prompt redraws the band from a timer, never from the render itself', async () => {
  register(on as any)
  Object.assign(envVars, READING)
  transcript(LINEAR)
  await turnComplete()
  await band()
  invalidated = []
  await drawRow('u1', 'say one', { first: 0, last: 1, of: 2 })
  expect(invalidated).toEqual([])
  await fireAfter()
  expect(invalidated).toEqual(['ui.render'])
})

test('a tick\'s press scrolls the transcript to the prompt\'s row; a refusal marks the tick dotted and is toasted once a session', async () => {
  register(on as any)
  Object.assign(envVars, READING)
  transcript(LINEAR)
  await turnComplete()
  await drawRow('u1', 'say one', { first: 0, last: 1, of: 2 })
  await drawRow('r3', 'say three\nwith a second line', { first: 0, last: 1, of: 2 })
  // Both rows whole: the topmost, the first prompt, is being read, so its tick is no Button.
  const tree = await band()
  expect(rail(tree)).toEqual(['\u2503', '\u2502', '\u2502', '\u2502'])
  await tickButtons(tree)[0].props.onPress()
  expect(scrolls).toEqual([{ to: { requestId: 'u2' }, block: 'start' }])
  scrollResult = { deny: 'the window moved meanwhile' }
  await tickButtons(tree)[1].props.onPress()
  await tickButtons(tree)[1].props.onPress()
  expect(scrolls.slice(1)).toEqual([{ to: { requestId: 'r3' }, block: 'start' }, { to: { requestId: 'r3' }, block: 'start' }])
  expect(toasts).toEqual(['the window moved meanwhile'])
  expect(rail(await band())).toEqual(['\u2503', '\u2502', '\u2506', '\u2502'])
})

test('a prompt no row has drawn since a resume is dim, and its press says so once', async () => {
  transcript(LINEAR)
  await turnComplete()
  scrollResult = { deny: 'nothing drawn under that requestId' }
  const tree = await band()
  await tickButtons(tree)[1].props.onPress()
  await tickButtons(tree)[1].props.onPress()
  expect(scrolls).toEqual([{ to: { requestId: 'u2' }, block: 'start' }, { to: { requestId: 'u2' }, block: 'start' }])
  expect(toasts).toEqual(['that prompt is not on screen yet'])
  expect(rail(await band())).toEqual(['\u2502', '\u2502', '\u2502', '\u2503'])
})

test('/cs next, prev, first, last and N move along the rail from the prompt being read', async () => {
  await sessionStart()
  expect(commands.find(c => c.name === 'cs')).toMatchObject({ immediate: true })
  expect(await cs('next')).toEqual({ text: 'the rail has no prompts' })
  transcript(LINEAR)
  await turnComplete()
  for (const [id, text] of [['u1', 'say one'], ['u2', 'say two'], ['u3', 'say three\nwith a second line'], ['u4', '  say four  ']]) await drawRow(id, text, null)
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  expect(await cs('next')).toEqual({})
  expect(await cs('prev')).toEqual({})
  expect(await cs('first')).toEqual({})
  expect(await cs('last')).toEqual({})
  expect(await cs('3')).toEqual({})
  expect(scrolls.map(s => s.to.requestId)).toEqual(['u3', 'u1', 'u1', 'u4', 'u3'])
  expect(await cs('9')).toEqual({ text: 'the rail has 4 prompts' })
  expect(await cs('sideways')).toEqual({ text: 'usage: /cs next|prev|first|last|<n>' })
  await drawRow('u4', '  say four  ', { first: 0, last: 1, of: 2 })
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  await drawRow('u1', 'say one', { first: 4, last: 6, of: 7 })
  expect(await cs('prev')).toEqual({ text: 'no prompt before this one' })
})

// Bare /cs is the cs panel's: this hook hands it on, whichever plugin's hook
// sits below, and answers only a form with an argument.
test('bare /cs, blank or spaces, goes to the next hook untouched and returns its answer', async () => {
  for (const args of ['', '   ']) {
    const answer = { text: 'the next hook' }
    const handed: any[] = []
    const got = await hooks['command.run:cs']($, { command: 'cs', args }, async (e: any) => { handed.push(e); return answer })
    expect(got).toBe(answer)
    expect(handed).toEqual([{ command: 'cs', args }])
  }
  expect(scrolls).toEqual([])
})

test('rows drawn where the band is not the lead\'s, or under a survey, redraw once at most: the read tick settles even when the rail is not drawn', async () => {
  register(on as any)
  Object.assign(envVars, READING)
  transcript(LINEAR)
  await turnComplete()
  const pending = () => timers.filter(t => t.kind === 'after' && !t.cancelled).length
  sessionId = 'uuid-teammate'
  await band()
  const before = pending()
  for (let i = 0; i < 3; i++) await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  expect(pending()).toBe(before + 1)
  await fireAfter()
  await band()
  for (let i = 0; i < 3; i++) await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  expect(pending()).toBe(0)
  sessionId = 'uuid-lead'
  await band({ hasSurvey: true })
  for (let i = 0; i < 3; i++) await drawRow('u1', 'say one', { first: 4, last: 6, of: 7 })
  expect(pending()).toBe(1)
  await fireAfter()
  await band({ hasSurvey: true })
  for (let i = 0; i < 3; i++) await drawRow('u1', 'say one', { first: 4, last: 6, of: 7 })
  expect(pending()).toBe(0)
})

test('with no prompt row left in the viewport, the read tick stays on the prompt last read, not the newest', async () => {
  register(on as any)
  Object.assign(envVars, READING)
  transcript(LINEAR)
  await turnComplete()
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  await fireAfter()
  expect(rail(await band())).toEqual(['│', '┃', '│', '│'])
  await drawRow('u2', 'say two', null)
  await fireAfter()
  expect(rail(await band())).toEqual(['│', '┃', '│', '│'])
  expect(await cs('prev')).toEqual({})
  expect(scrolls.map(s => s.to.requestId)).toEqual(['u1'])
})

test('a prompt whose row has not been drawn is matched by its text only when that text is its alone', async () => {
  register(on as any)
  Object.assign(envVars, READING)
  transcript([
    prompt('u1', null, 'continue'), reply('a1', 'u1'),
    prompt('u2', 'a1', 'continue'), reply('a2', 'u2'),
    prompt('u3', 'a2', 'continue'), reply('a3', 'u3'),
    prompt('u4', 'a3', 'say four'), reply('a4', 'u4'),
  ])
  await turnComplete()
  await drawRow('u3', 'continue', { first: 0, last: 1, of: 2 })
  await drawRow('row-of-u4', 'say four', null)
  await fireAfter()
  expect(rail(await band())).toEqual(['│', '│', '┃', '│'])
  expect(await cs('1')).toEqual({})
  expect(await cs('4')).toEqual({})
  expect(scrolls.map(s => s.to.requestId)).toEqual(['u1', 'row-of-u4'])
})

test('an interrupt row is not a prompt, and a prompt that opens with a tag on a line of its own words is', () => {
  const rows = [
    prompt('u1', null, 'say one'), reply('a1', 'u1'),
    prompt('i1', 'a1', [{ type: 'text', text: '[Request interrupted by user for tool use]' }]), reply('a2', 'i1'),
    prompt('i2', 'a2', '[Request interrupted by user]'), reply('a3', 'i2'),
    prompt('u2', 'a3', '<div class="x"> renders empty'), reply('a4', 'u2'),
    prompt('f1', 'a4', '<teammate-message teammate_id="x">\nhello\n</teammate-message>'), reply('a5', 'f1'),
    prompt('f2', 'a5', '<local-command-stdout>ok</local-command-stdout>'), reply('a6', 'f2'),
  ]
  expect(parsePrompts(rows.join('\n')).map(p => p.text)).toEqual(['say one', '<div class="x"> renders empty'])
})

test('a /clear empties the rail: the next conversation draws none of the last one\'s prompts', async () => {
  transcript(LINEAR)
  await turnComplete()
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  const e = { command: 'clear', args: '', origin: { kind: 'composer' }, presentation: { layout: 'main', columns: 80 } }
  invalidated = []
  expect(await hooks['command.run:clear']($, e, async () => ({ text: '' }))).toEqual({ text: '' })
  expect(invalidated).toEqual(['ui.render'])
  expect(rail(await band())).toEqual([])
  expect(await cs('next')).toEqual({ text: 'the rail has no prompts' })
  await turnComplete()
  expect(rail(await band())).toEqual(['│', '│', '│', '┃'])
})

test('a line too narrow for any tick, with nothing else to say, draws nothing', async () => {
  transcript(LINEAR)
  await turnComplete()
  expect(await band({ bodyColumns: 4 })).toBe(DRAWN)
})

test('the rail ends in the line\'s last cell across the spacer from the words, as upright bars, and the read prompt stands before it', async () => {
  transcript(LINEAR)
  queueTasks(2)
  await turnComplete()
  const tree = await band()
  const kids = bandBody(tree)
  expect(kids.slice(-3).map((k: any) => k.props.key ?? 'label')).toEqual(['cs-spacer', 'label', 'cs-rail'])
  expect(texts(kids[kids.length - 2]).includes(gapLabel(tree))).toBe(true)
  expect(boxes(tree).filter((b: any) => b.props.flexGrow !== undefined).map((b: any) => b.props)).toEqual([{ key: 'cs-spacer', flexGrow: 1 }])
  expect(rail(tree)).toEqual(['│', '│', '│', '┃'])
  // 108 cells after the inset: `▤ run 2 queued tasks` (20), three cells, the name sized to
  // `#3 say three` (12), three cells and the bars (4) leave 66 between the zones; the name is padded on its left.
  expect(textOf(gapLabel(tree))).toBe(' #4 say four')
  expect(bandLine(tree, 110)).toBe(`  ▤ run 2 queued tasks${' '.repeat(70)}#4 say four   │││┃`)
})

test('the focus ring never lands on a rail tick: the keyboard route is /cs', async () => {
  const e = (element: string) => ({ component: 'AbovePrompt', requestId: 'band', plugin: 'cs', element, origin: { kind: 'person' } })
  expect(await hooks['ui.focus:AbovePrompt']($, e('cs-rail-2'), async () => ({}))).toEqual({ deny: 'cs: the rail takes clicks and /cs, not the focus ring' })
  expect(await hooks['ui.focus:AbovePrompt']($, e('cs-rotate'), async () => ({ moved: true }))).toEqual({ moved: true })
})

// Before the rail the band names a prompt: the one being read, light gray italic; a
// bar under the pointer swaps in its own.
const gapLabel = (tree: any) => texts(tree).find((t: any) => t.props.italic && t.props.color === 'subtle')

test('before the bars the band names the prompt being read, light gray italic, whether or not words stand before them', async () => {
  register(on as any)
  Object.assign(envVars, READING)
  transcript(LINEAR)
  await turnComplete()
  const tree = await band()
  // Three cells before the bars, as wide as the widest prompt a bar can swap in, `#3 say three` (12), padded on its left.
  expect(textOf(gapLabel(tree))).toBe(' #4 say four')
  const kids = bandBody(tree)
  expect(kids.slice(-2).map((k: any) => k.props.key ?? 'label')).toEqual(['label', 'cs-rail'])
  expect(kids[kids.length - 2].props).toEqual({ width: 12, marginLeft: 0 })
  expect(kids[kids.length - 1].props).toEqual({ key: 'cs-rail', marginLeft: 3 })
  expect(kids[kids.length - 2].children.filter((c: any) => c.type === 'Text' && c.props.color === 'subtle').map(textOf)).toEqual([' #4 say four'])
  // A row reporting moves the name with the read bar, and the bars stay in their column.
  expect(bandLine(tree, 110)).toBe(`  ${' '.repeat(90)}#4 say four   │││┃`)
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  const moved = await band()
  expect(textOf(gapLabel(moved))).toBe('  #2 say two')
  expect(bandLine(moved, 110)).toBe(`  ${' '.repeat(91)}#2 say two   │┃││`)
  // A word on the left leaves the bars and the prompt where they stand: 108 cells less `▤ run 1 queued task`
  // (19), three cells, the name (12), three cells and the bars (4) leave 67 between them.
  queueTasks(1)
  const queued = await band()
  expect(textOf(gapLabel(queued))).toBe('  #2 say two')
  expect(bandLine(queued, 110)).toBe(`  ▤ run 1 queued task${' '.repeat(72)}#2 say two   │┃││`)
})

test('each bar under the pointer swaps its own prompt into the gap, italic, covering the read one, and the bars hold still', async () => {
  transcript(LINEAR)
  await turnComplete()
  const tree = await band()
  // Bar i heats group cs-rail-<i>; the read bar is a Text the label already names.
  expect(tickButtons(tree).map((b: any) => b.props.hover)).toEqual([0, 1, 2].map(i => ({ scope: `cs-rail-${i}`, dimColor: false })))
  const cards = boxes(tree).filter((b: any) => b.props.display === 'none')
  expect(cards.map((c: any) => c.props)).toEqual([0, 1, 2].map(i => ({
    position: 'absolute', top: 0, left: 0, display: 'none', hover: { scope: `cs-rail-${i}`, display: 'flex' },
  })))
  expect(cards.map((c: any) => texts(c).map((t: any) => [textOf(t), t.props]))).toEqual([
    [['  #1 say one', { color: 'subtle', italic: true, wrap: 'truncate-end' }]],
    [['  #2 say two', { color: 'subtle', italic: true, wrap: 'truncate-end' }]],
    [['#3 say three', { color: 'subtle', italic: true, wrap: 'truncate-end' }]],
  ])
  // The cards sit in the label's own Box, as wide as the widest of them, so a card covers the read
  // prompt cell for cell and a swap moves nothing.
  const labelBox = boxes(tree).find((b: any) => b.props.width === 12)
  expect(boxes(labelBox).filter((b: any) => b.props.display === 'none')).toHaveLength(3)
  // The row as drawn at rest and with the pointer on each bar: only the name's cells change.
  expect(bandRows(tree, 110)).toEqual([`  ${' '.repeat(90)}#4 say four   │││┃`])
  expect(bandRows(tree, 110, 'cs-rail-0')).toEqual([`  ${' '.repeat(91)}#1 say one   │││┃`])
  expect(bandRows(tree, 110, 'cs-rail-2')).toEqual([`  ${' '.repeat(89)}#3 say three   │││┃`])
})

test('the gap\'s prompt is cut to the gap with an ellipsis; a gap under ten cells names none and the bars heat nothing', async () => {
  transcript([...LINEAR, prompt('u5', 'a4', 'x'.repeat(40))])
  await turnComplete()
  // 27 columns: 25 after the inset, three cells and five bars leave 17.
  const cut = await band({ bodyColumns: 27 })
  expect(textOf(gapLabel(cut))).toBe(`#5 ${'x'.repeat(13)}…`)
  expect(texts(boxes(cut).find((b: any) => b.props.hover?.scope === 'cs-rail-0')).map(textOf)).toEqual(['#1 say one'.padStart(17)])
  expect(bandLine(cut, 27)).toBe(`  #5 ${'x'.repeat(13)}…   ││││┃`)
  // 20 columns leave exactly ten.
  expect(textOf(gapLabel(await band({ bodyColumns: 20 })))).toBe(`#5 ${'x'.repeat(6)}…`)
  // 19 leave nine: the bars alone at the right edge, no card, no hover group.
  const bare = await band({ bodyColumns: 19 })
  expect(bandLine(bare, 19)).toBe(`  ${' '.repeat(12)}││││┃`)
  expect(gapLabel(bare)).toBeUndefined()
  expect(boxes(bare).filter((b: any) => b.props.display === 'none')).toEqual([])
  expect(tickButtons(bare).map((b: any) => b.props.hover)).toEqual([undefined, undefined, undefined, undefined])
  expect(rail(bare)).toEqual(['│', '│', '│', '│', '┃'])
})

test('a rail past its budget takes the whole gap: no prompt is named beside a collapsed run', async () => {
  register(on as any)
  Object.assign(envVars, UNCAPPED)
  const many = [prompt('u1', null, 'p1')]
  for (let i = 2; i <= 30; i++) many.push(reply(`a${i - 1}`, `u${i - 1}`), prompt(`u${i}`, `a${i - 1}`, `p${i}`))
  transcript(many)
  await turnComplete()
  // 27 columns leave 25 cells after the inset for 30 bars: `…8`, its cell and 22 bars, no gap.
  const tree = await band({ bodyColumns: 27 })
  expect(rail(tree)[0]).toBe('…8')
  expect(bandLine(tree, 27)).toBe(`  …8 ${'│'.repeat(21)}┃`)
  expect(gapLabel(tree)).toBeUndefined()
  expect(boxes(tree).filter((b: any) => b.props.display === 'none')).toEqual([])
  // 38 leave 36: every bar, the three-cell gap and three cells, under ten, so none either.
  expect(gapLabel(await band({ bodyColumns: 38 }))).toBeUndefined()
  // 45 leave ten, and the name takes the seven its widest prompt needs; 44 leave nine.
  expect(textOf(gapLabel(await band({ bodyColumns: 45 })))).toBe('#30 p30')
  expect(gapLabel(await band({ bodyColumns: 44 }))).toBeUndefined()
})

// The desktop app paints a card over the line without hiding what is under it
// (prompt-rail's CHANGELOG), so the two prompts would read as one.
test('off the terminal the gap names the prompt being read and draws no hover cards over it', async () => {
  transcript(LINEAR)
  await turnComplete()
  for (const surface of ['desktop', 'vscode', 'mobile']) {
    const tree = await band({}, surface)
    expect(textOf(gapLabel(tree))).toBe('#4 say four')
    expect(boxes(tree).find((b: any) => (b.children ?? []).flat(Infinity).includes(gapLabel(tree))).props.width).toBe(11)
    expect(boxes(tree).filter((b: any) => b.props.display === 'none')).toEqual([])
    expect(tickButtons(tree).map((b: any) => b.props.hover)).toEqual([undefined, undefined, undefined])
  }
})

// The gap is counted in terminal cells: a wide character takes two, and a cut
// never splits one.
test('the gap\'s prompt is measured and cut in cells: wide characters take two, an emoji is never split', async () => {
  transcript([...LINEAR, prompt('u5', 'a4', '\u4e00'.repeat(60))])
  await turnComplete()
  // Five bars and the three cells before them leave 100: `#5 ` and 48 two-cell characters are 99, a 49th would pass the 99 left before `…`.
  expect(textOf(gapLabel(await band()))).toBe(`#5 ${'\u4e00'.repeat(48)}\u2026`)
  transcript([...LINEAR, prompt('u5', 'a4', `${'x'.repeat(13)}\u{1F600}tail`)], 2)
  await turnComplete()
  // 18 cells: `#5 ` and 13 x are 16, the emoji would pass the 17 left before `…`, and the cell left over pads the left.
  const cut = textOf(gapLabel(await band({ bodyColumns: 28 })))
  expect(cut).toBe(` #5 ${'x'.repeat(13)}\u2026`)
  expect(cut.isWellFormed()).toBe(true)
  // A Text the engine measures wider than this count would wrap the band onto a second line.
  expect(gapLabel(await band()).props.wrap).toBe('truncate-end')
})

test('the right edge keeps its margins: three cells after the actions, three between the status words and the name, three between the name and the bars', async () => {
  transcript(LINEAR)
  await turnComplete()
  const margins = (tree: any) => {
    const statusBox = boxes(tree).find((b: any) => b.props.key === 'cs-status')
    const railBox = boxes(tree).find((b: any) => b.props.key === 'cs-rail')
    const labelBox = boxes(tree).find((b: any) => (b.children ?? []).flat(Infinity).includes(gapLabel(tree)))
    return [statusBox.props.marginLeft, labelBox?.props.marginLeft, railBox.props.marginLeft]
  }
  expect(margins(await band())).toEqual([0, 0, 3])
  queueTasks(2)
  expect(margins(await band())).toEqual([3, 0, 3])
  files['/work/.cs/local/mail/new/one.json'] = '{}'
  expect(margins(await band())).toEqual([3, 3, 3])
  delete files['/work/.cs/local/mail/new/one.json']
  // No room to name a prompt: the bars alone, three cells after the actions.
  expect(margins(await band({ bodyColumns: 40 }))).toEqual([3, undefined, 0])
  expect(bandLine(await band({ bodyColumns: 40 }), 40)).toBe(`  ▤ run 2 queued tasks${' '.repeat(14)}│││┃`)
})

// ---------------------------------------------------------------------------
// The features word: the state of the session's feature worktrees, from
// `cs <base> -features --porcelain` (task branch ahead merged ff wt_dirty
// untracked base_dirty lock state), first at the band's right edge.

const feature = (task: string, ahead: number, state: string, { untracked = '0', lock = 'none' } = {}) =>
  [task, `cs/${task}`, String(ahead), '0', '1', '0', untracked, '0', lock, state].join('\t')
const porcelain = (...records: string[]) => { runResult = { exitCode: 0, stdout: records.map(r => `${r}\n`).join(''), stderr: '' } }
const featureRuns = () => runs.filter(r => r.argv[2] === '-features')
const featuresKey = (tree: any) => buttons(tree).find((b: any) => b.props.key === 'cs-features')
// The turn end reads cs without waiting on it; every fake answers at once, so
// one macrotask lets that reading finish.
const settled = () => new Promise(resolve => setTimeout(resolve, 0))
const featuresTurn = async () => { await turnComplete(); await settled() }
// A feature's directory at the sessions root, as cs names it: `<base>@<task>`.
const featureDir = (task: string, base = 'work') => { files[`/home/.claude-sessions/${base}@${task}`] = '' }

test('a base with one feature ready names it at the line\'s right edge, and a press runs /finish on it', async () => {
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'ready'))
  await featuresTurn()
  expect(featureRuns().map(r => r.argv)).toEqual([['/opt/cs/bin/cs', 'work', '-features', '--porcelain']])
  const tree = await band()
  expect(featuresKey(tree).props).toMatchObject({ key: 'cs-features', plain: true, label: '1 feature · fix-auth ready' })
  expect(bandBody(tree).map((k: any) => k.props.key)).toEqual(['cs-spacer', 'cs-features'])
  // 108 cells after the inset less the word (26) leave the spacer 82.
  expect(bandLine(tree, 110)).toBe(`  ${' '.repeat(82)}1 feature · fix-auth ready`)
  await featuresKey(tree).props.onPress()
  expect(ran).toEqual([{ command: 'finish', args: 'fix-auth' }])
})

test('a base names its one ready feature among several, counts two or more ready with a bare /finish, and names none with no press', async () => {
  featureDir('fix-auth'); featureDir('docs'); featureDir('perf')
  porcelain(feature('fix-auth', 2, 'dirty'), feature('docs', 1, 'ready'), feature('perf', 4, 'merged'))
  await featuresTurn()
  let tree = await band()
  expect(featuresKey(tree).props.label).toBe('3 features · docs ready')
  await featuresKey(tree).props.onPress()
  porcelain(feature('fix-auth', 2, 'ready'), feature('docs', 1, 'ready'), feature('perf', 4, 'merged'))
  await featuresTurn()
  tree = await band()
  expect(featuresKey(tree).props.label).toBe('3 features · 2 ready')
  await featuresKey(tree).props.onPress()
  expect(ran).toEqual([{ command: 'finish', args: 'docs' }, { command: 'finish', args: '' }])
  porcelain(feature('fix-auth', 2, 'dirty'), feature('docs', 0, 'ready'), feature('perf', 4, 'staged'))
  await featuresTurn()
  tree = await band()
  expect(featuresKey(tree)).toBeUndefined()
  expect(restingWords(tree)).toEqual(['3 features · none ready'])
  expect(texts(tree).find((t: any) => textOf(t) === '3 features · none ready').props).toEqual({ dimColor: true })
})

// A record of every state _feature_readiness prints, with what a person reads
// for it, and the lock and count sides each sentence turns on.
const FEATURE_SENTENCES: [string, string][] = [
  [feature('fix-auth', 3, 'ready'), 'ready'],
  [feature('fix-auth', 0, 'ready'), 'no commits'],
  [feature('fix-auth', 0, 'merged'), 'merged'],
  [feature('fix-auth', 2, 'staged', { lock: 'worktree' }), 'retire staged'],
  [feature('fix-auth', 2, 'untracked', { untracked: '1' }), '1 file untracked'],
  [feature('fix-auth', 2, 'untracked', { untracked: '3' }), '3 files untracked'],
  [feature('fix-auth', 2, 'locked', { lock: 'base' }), 'base session is live'],
  [feature('fix-auth', 2, 'locked', { lock: 'worktree' }), 'worktree session is live'],
  [feature('fix-auth', 2, 'dirty'), 'uncommitted changes'],
  [feature('fix-auth', 5, 'base-dirty'), 'base has uncommitted changes'],
  [feature('fix-auth', 1, 'vault-locked'), 'base vault is locked'],
]

test('one feature not ready says its state as a sentence; ready with nothing ahead of the base reads no commits', async () => {
  featureDir('fix-auth')
  for (const [record, sentence] of FEATURE_SENTENCES.filter(([, sentence]) => sentence !== 'ready')) {
    porcelain(record)
    await featuresTurn()
    const tree = await band()
    expect(restingWords(tree)).toEqual([`1 feature · fix-auth ${sentence}`])
    expect(featuresKey(tree)).toBeUndefined()
  }
})

test('the band and lib/30-worktree.sh say every state alike, and know the same states', () => {
  const lib = fileURLToPath(new URL('../../../lib/30-worktree.sh', import.meta.url))
  const printed = [...readFileSync(lib, 'utf8').matchAll(/\bstate="([a-z-]+)"/g)].map(match => match[1])
  const tried = new Set(FEATURE_SENTENCES.map(([record]) => record.split('\t')[9]))
  expect([...tried].sort()).toEqual([...new Set(printed)].sort())
  for (const [record, sentence] of FEATURE_SENTENCES) {
    const [, , ahead, , , , untracked, , lock, state] = record.split('\t')
    const shell = spawnSync('bash', ['-c', 'source "$1"; shift; _feature_state_sentence "$@"', 'bash', lib, state, lock, untracked, ahead], { encoding: 'utf8' })
    expect({ status: shell.status, stdout: shell.stdout, stderr: shell.stderr }).toEqual({ status: 0, stdout: `${sentence}\n`, stderr: '' })
    const parsed = parseFeatures(`${record}\n`)
    if ('unreadable' in parsed) throw new Error(`the band cannot read ${record}`)
    expect(featuresWordOf(parsed)?.label).toBe(`1 feature · fix-auth ${sentence}`)
  }
})

test('a feature session draws no features word and asks cs nothing: /finish lands a feature from its base', async () => {
  cwdPath = '/feat'
  realPaths['/feat'] = '/feat'; realPaths['/home/.claude-sessions/work@fix-auth'] = '/feat'
  existing.add('/feat/.cs/local')
  files['/feat/.cs/local/state'] = 'session_name: work@fix-auth\nclaude_session_id: uuid-lead\n'
  porcelain(feature('fix-auth', 3, 'ready'))
  // The rail draws here, so the band is this conversation's to draw.
  files['/home/.claude/projects/-feat/uuid-lead.jsonl'] = `${LINEAR.join('\n')}\n`
  await featuresTurn()
  expect(rail(await band())).toHaveLength(4)
  expect(featureRuns()).toEqual([])
  expect(timers.filter(t => t.kind === 'every' && t.ms === 30000)).toEqual([])
  expect(restingWords(await band())).toEqual([' #4 say four', '\u2503'])
})

test('a cs that fails, cannot start, or prints a record the band cannot read draws no word and is logged once each', async () => {
  featureDir('fix-auth')
  const record = feature('fix-auth', 3, 'ready')
  const answers: any[] = [
    { exitCode: 2, stdout: '', stderr: 'error: no such session\n' },
    { exitCode: 2, stdout: '', stderr: 'error: no such session\n' },
    new Error('spawn ENOENT'),
    { exitCode: 0, stdout: `${record}\textra\n`, stderr: '' },
    { exitCode: 0, stdout: record.replace('\t3\t', '\tthree\t') + '\n', stderr: '' },
    { exitCode: 0, stdout: record.replace(/ready$/, 'landed') + '\n', stderr: '' },
    { exitCode: 0, stdout: feature('fix-auth', 3, 'untracked', { untracked: 'some' }) + '\n', stderr: '' },
    { exitCode: 0, stdout: feature('fix-auth', 3, 'locked', { lock: 'elsewhere' }) + '\n', stderr: '' },
  ]
  for (const answer of answers) {
    runResult = answer
    await featuresTurn()
    expect(await band()).toBe(DRAWN)
  }
  expect(logs).toEqual([
    'cs work -features exited 2: error: no such session',
    'cs work -features did not answer: spawn ENOENT',
    `cs work -features gave a record the band cannot read: ${record}\textra`,
    `cs work -features gave a record the band cannot read: ${record.replace('\t3\t', '\tthree\t')}`,
    `cs work -features gave a record the band cannot read: ${record.replace(/ready$/, 'landed')}`,
    `cs work -features gave a record the band cannot read: ${feature('fix-auth', 3, 'untracked', { untracked: 'some' })}`,
    `cs work -features gave a record the band cannot read: ${feature('fix-auth', 3, 'locked', { lock: 'elsewhere' })}`,
  ])
})

test('the features word leads the right edge before the rail, yields to a running gate, and the keys under the prompt take none of the line', async () => {
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'ready'))
  transcript(LINEAR)
  await featuresTurn()
  // 108 cells after the inset less the word (26), three cells, the name sized to `#3 say three`
  // (12), three cells and the bars (4) leave the spacer 60.
  let tree = await band()
  expect(textOf(gapLabel(tree))).toBe(' #4 say four')
  expect(bandLine(tree, 110)).toBe(`  ${' '.repeat(60)}1 feature · fix-auth ready    #4 say four   │││┃`)
  percent = 80
  tree = await band()
  expect(bandLine(tree, 110)).toBe(`  ${' '.repeat(60)}1 feature · fix-auth ready    #4 say four   │││┃`)
  expect(buttons(await footerHint()).map((b: any) => b.props.key)).toEqual(['cs-rotate', 'cs-wrap'])
  percent = undefined
  queueTasks(1)
  tree = await band()
  expect(buttons(tree).map((b: any) => b.props.key)).toEqual(['cs-queue', 'cs-features', 'cs-rail-0', 'cs-rail-1', 'cs-rail-2'])
  delete files[`${QDIR}/0000000001-seed`]
  livePids.add('4242')
  nowMs = NOW * 1000
  await startFinish()
  record(running('gate', { gate_started: NOW - 3 }))
  await watchTick()
  tree = await band({ isWorking: true })
  expect(featuresKey(tree)).toBeUndefined()
  expect(restingWords(tree).slice(0, 1)).toEqual(['finishing fix-auth \u00b7 gate 3s'])
})

test('an idle band asks cs again every 30 s, never while a turn runs, never twice at once, and not at all with no feature', async () => {
  await featuresTurn()
  expect(timers.filter(t => t.kind === 'every' && t.ms === 30000)).toEqual([])
  expect(featureRuns()).toEqual([])
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'dirty'))
  await featuresTurn()
  await featuresTurn()
  const clocks = timers.filter(t => t.kind === 'every' && t.ms === 30000)
  expect(clocks).toHaveLength(1)
  expect(featureRuns()).toHaveLength(2)
  await band({ isWorking: true })
  await clocks[0].fn()
  expect(featureRuns()).toHaveLength(2)
  await band()
  porcelain(feature('fix-auth', 3, 'ready'))
  await clocks[0].fn()
  expect(featureRuns()).toHaveLength(3)
  expect(featuresKey(await band()).props.label).toBe('1 feature · fix-auth ready')
  // A reading still running is not doubled by the next tick.
  const run = $.process.run
  let release: () => void = () => {}
  $.process.run = async (argv: string[], init: any) => {
    if (argv[2] !== '-features') return run(argv, init)
    runs.push({ argv, init })
    await new Promise<void>(r => { release = r })
    return { exitCode: 0, stdout: `${feature('fix-auth', 3, 'ready')}\n`, stderr: '' }
  }
  try {
    const first = clocks[0].fn()
    for (let i = 0; i < 100 && featureRuns().length < 4; i++) await Promise.resolve()
    expect(featureRuns()).toHaveLength(4)
    await clocks[0].fn()
    expect(featureRuns()).toHaveLength(4)
    release()
    await first
  } finally {
    $.process.run = run
  }
  expect(featureRuns().at(-1)?.init).toEqual({ timeoutMs: 20000 })
})

test('a reading that did not answer in its budget stops the 30 s clock; the next turn asks once more', async () => {
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'ready'))
  await featuresTurn()
  const clocks = () => timers.filter(t => t.kind === 'every' && t.ms === 30000 && !t.cancelled)
  expect(clocks()).toHaveLength(1)
  runResult = new Error('cs: $.process.run(/opt/cs/bin/cs) aborted: still running after 20000ms')
  await band()
  await clocks()[0].fn()
  expect(featureRuns()).toHaveLength(2)
  expect(clocks()).toEqual([])
  expect(logs).toEqual(['cs work -features did not answer: cs: $.process.run(/opt/cs/bin/cs) aborted: still running after 20000ms'])
  porcelain(feature('fix-auth', 3, 'ready'))
  await featuresTurn()
  expect(featureRuns()).toHaveLength(3)
  expect(clocks()).toHaveLength(1)
  expect(logs).toHaveLength(1)
})

test('a survey owns the band: no features word under one', async () => {
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'ready'))
  await featuresTurn()
  expect(await band({ hasSurvey: true })).toBe(DRAWN)
})

test('while a turn runs the features word draws dim with no press; one press is all a word takes until cs answers again', async () => {
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'ready'))
  await featuresTurn()
  let tree = await band({ isWorking: true })
  expect(featuresKey(tree)).toBeUndefined()
  expect(texts(tree).find((t: any) => textOf(t) === '1 feature · fix-auth ready').props).toEqual({ dimColor: true })
  tree = await band()
  await featuresKey(tree).props.onPress()
  tree = await band()
  expect(featuresKey(tree)).toBeUndefined()
  expect(restingWords(tree)).toEqual(['1 feature · fix-auth ready'])
  expect(ran).toEqual([{ command: 'finish', args: 'fix-auth' }])
  await featuresTurn()
  expect(featuresKey(await band())).toBeDefined()
})

test('a /finish the engine refuses is toasted, not thrown', async () => {
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 3, 'ready'))
  await featuresTurn()
  $.command.run = async (args: any) => { ran.push(args); throw new Error('a turn is running') }
  try {
    await featuresKey(await band()).props.onPress()
  } finally {
    $.command.run = async (args: any) => { ran.push(args); return { text: '' } }
  }
  expect(toasts).toEqual(['/finish fix-auth did not run: a turn is running'])
})

test('a base with no feature asks cs nothing and runs no clock; the turn a feature is made in reads it', async () => {
  await featuresTurn()
  expect(timers.filter(t => t.kind === 'every' && t.ms === 30000)).toEqual([])
  expect(featureRuns()).toEqual([])
  featureDir('fix-auth')
  porcelain(feature('fix-auth', 0, 'ready'))
  await featuresTurn()
  expect(restingWords(await band())).toEqual(['1 feature \u00b7 fix-auth no commits'])
  expect(timers.filter(t => t.kind === 'every' && t.ms === 30000)).toHaveLength(1)
})

test('the turn end does not wait on cs: it returns while the features reading still runs, and the band redraws when cs answers', async () => {
  featureDir('fix-auth')
  const run = $.process.run
  let answer: () => void = () => {}
  $.process.run = async (argv: string[], init: any) => {
    if (argv[2] !== '-features') return run(argv, init)
    runs.push({ argv, init })
    await new Promise<void>(r => { answer = r })
    return { exitCode: 0, stdout: `${feature('fix-auth', 3, 'ready')}\n`, stderr: '' }
  }
  try {
    expect(await turnComplete()).toEqual({ text: 'ok' })
    await settled()
    expect(featureRuns()).toHaveLength(1)
    expect(featuresKey(await band())).toBeUndefined()
    invalidated = []
    answer()
    await settled()
  } finally {
    $.process.run = run
  }
  expect(invalidated).toEqual(['ui.render'])
  expect(featuresKey(await band()).props.label).toBe('1 feature · fix-auth ready')
})

// ---------------------------------------------------------------------------
// The cs queue's count while its start key is not offered, at the left where
// the start key stands, then unread mail at the right edge, when there are any.

// The queue word's parts as drawn: its glyph in the queue's amber, the rest dim.
const queueWordInks = (tree: any) => texts(tree).filter((t: any) => t.children.some((c: any) => c?.type === 'Text'))
  .flatMap((t: any) => t.children.map((c: any) => [c.props, textOf(c)]))

test('tasks queued while the queue runs, or while a turn runs, draw a queue word where the start key would be, its glyph amber and the rest dim', async () => {
  queueTasks(3)
  for (const state of ['armed\n', 'draining\n']) {
    files['/work/.cs/local/queue.state'] = state
    const tree = await band()
    expect(restingWords(tree)).toEqual(['▤ queue 3 running'])
    expect(queueWordInks(tree)).toEqual([[{ color: 'rgb(180,83,9)' }, '▤'], [{ dimColor: true }, ' queue 3 running']])
    expect(buttons(tree)).toEqual([])
  }
  files['/work/.cs/local/queue.state'] = 'idle\n'
  const working = await band({ isWorking: true })
  expect(restingWords(working)).toEqual(['▤ queue 3'])
  expect(queueWordInks(working)).toEqual([[{ color: 'rgb(180,83,9)' }, '▤'], [{ dimColor: true }, ' queue 3']])
  const idle = await band()
  expect(queueKey(idle).props.label).toBe('▤ run 3 queued tasks')
  expect(restingWords(idle)).toEqual([])
  files['/work/.cs/local/queue.state'] = 'armed\n'
  sessionId = 'uuid-teammate'
  expect(await band()).toBe(DRAWN)
})

test('the queue word stands at the left, alone past the threshold too, and draws no right edge', async () => {
  queueTasks(2)
  files['/work/.cs/local/queue.state'] = 'armed\n'
  expect(restingWords(await band())).toEqual(['▤ queue 2 running'])
  percent = 40
  const tree = await band()
  expect(buttons(tree)).toEqual([])
  expect(bandBody(tree).map((k: any) => k.props.key ?? textOf(k))).toEqual(['▤ queue 2 running'])
  expect(boxes(tree).filter((b: any) => ['cs-spacer', 'cs-status'].includes(b.props.key))).toEqual([])
  expect(bandLine(tree, 110)).toBe('  ▤ queue 2 running')
})

test('the queue glyph takes the status line\'s amber, light on a dark terminal and dark on a light one, on the start key and the queue word alike', async () => {
  queueTasks(2)
  envVars.CS_TERM_THEME = 'dark'
  expect(queueKey(await band()).children).toEqual([{ type: 'Text', props: { color: 'rgb(251,191,36)' }, children: ['▤'] }, ' run 2 queued tasks'])
  // A measured light background outranks the theme's name.
  envVars.CS_TERM_BG_RGB = '252;247;229'
  expect(queueKey(await band()).children).toEqual([{ type: 'Text', props: { color: 'rgb(180,83,9)' }, children: ['▤'] }, ' run 2 queued tasks'])
  delete envVars.CS_TERM_BG_RGB
  files['/work/.cs/local/queue.state'] = 'draining\n'
  expect(queueWordInks(await band())).toEqual([[{ color: 'rgb(251,191,36)' }, '▤'], [{ dimColor: true }, ' queue 2 running']])
})

// cs's own resolution of its settings, the golden `cs -config list --porcelain`:
// twelve tab-separated fields a record, the value ninth and its source tenth.
const PORCELAIN = readFileSync(new URL('../../../tests/fixtures/config-porcelain.txt', import.meta.url), 'utf8')
const SETTINGS_ARGV = ['/opt/cs/bin/cs', '-config', 'list', '--porcelain']
// The golden (or <base>) with <key>'s record carrying <value> from <source>, or without the record.
const porcelainWith = (key: string, value?: string, source?: string, base = PORCELAIN) => base.split('\n').flatMap((line: string) => {
  const fields = line.split('\t')
  if (fields[0] !== key) return [line]
  if (value === undefined || source === undefined) return []
  fields[8] = value; fields[9] = source
  return [fields.join('\t')]
}).join('\n')
const answerSettings = (stdout: string) => { settingsResult = { exitCode: 0, stdout, stderr: '' } }
const queueAmber = async () => queueKey(await band()).children[0].props.color

test('cs is asked for its settings as the session starts and as each main-loop turn starts and ends; a subagent\'s turn asks nothing', async () => {
  await sessionStart(); await settle()
  await turnStart('go'); await settle()
  await turnComplete(); await settle()
  await hooks['turn.start']($, { text: 'look', turnId: 'turn-sub', agentId: 'agent-1' }, async (e: any) => ({ turnId: e.turnId })); await settle()
  await turnComplete({ agentId: 'agent-1' }); await settle()
  expect(settingsRuns).toEqual([SETTINGS_ARGV, SETTINGS_ARGV, SETTINGS_ARGV])
  expect(logs).toEqual([])
})

test('a launch that did not say where cs is (no CS_BIN) asks cs nothing and logs nothing', async () => {
  delete envVars.CS_BIN
  await sessionStart(); await settle()
  await turnStart('go'); await settle()
  expect(settingsRuns).toEqual([])
  expect(logs).toEqual([])
})

test('the golden\'s session CS_STATUSLINE_CTX_WARN=50 moves the band from the 40% default', async () => {
  answerSettings(PORCELAIN)
  await sessionStart(); await settle()
  percent = 49
  expect(await keys()).toBe(HINT_DRAWN)
  percent = 50
  expect(findButton(await keys())).toBeDefined()
})

test('a settings file\'s CS_ROTATE_BUTTON_CTX moves the band alone', async () => {
  answerSettings(porcelainWith('CS_ROTATE_BUTTON_CTX', '55', 'machine'))
  await turn('go'); await settle()
  percent = 54
  expect(await keys()).toBe(HINT_DRAWN)
  percent = 55
  expect(findButton(await keys())).toBeDefined()
})

test('a settings file\'s CS_ROTATE_FORCE_CTX=off, read as the turn started, stops the rotation its end would force', async () => {
  answerSettings(porcelainWith('CS_ROTATE_FORCE_CTX', 'off', 'session'))
  await turnStart('go'); await settle()
  percent = 100
  await turnComplete()
  expect(timers).toEqual([])
  expect(ran).toEqual([])
})

// Each record's value differs from the environment's so the ink says which
// one was read; cs itself prints the environment's value for a shell or
// launch source.
test('the theme is a settings file\'s only when cs says a file set it: a launch measurement, a shell pin or no record leave the environment\'s', async () => {
  queueTasks(2)
  envVars.CS_TERM_THEME = 'dark'
  const after = async (stdout: string) => { answerSettings(stdout); await turnStart('go'); await settle(); return queueAmber() }
  expect(await after(porcelainWith('CS_TERM_THEME', 'light', 'machine'))).toBe('rgb(180,83,9)')
  expect(await after(porcelainWith('CS_TERM_THEME', 'light', 'launch'))).toBe('rgb(251,191,36)')
  expect(await after(porcelainWith('CS_TERM_THEME', 'light', 'session'))).toBe('rgb(180,83,9)')
  expect(await after(porcelainWith('CS_TERM_THEME', 'light', 'shell'))).toBe('rgb(251,191,36)')
  expect(await after(porcelainWith('CS_TERM_THEME', 'light', 'session'))).toBe('rgb(180,83,9)')
  expect(await after(porcelainWith('CS_TERM_THEME'))).toBe('rgb(251,191,36)')
})

// A forced rotation is decided from cs's current answer, not the one before
// it: the turn's end waits for the read it starts.
test('a turn\'s end waits for cs\'s settings before it forces a rotation: a session FORCE_CTX=off that cs is still answering stops it', async () => {
  percent = 100
  settingsResult = new Promise(resolve => setTimeout(() => resolve({ exitCode: 0, stdout: porcelainWith('CS_ROTATE_FORCE_CTX', 'off', 'session'), stderr: '' }), 20))
  await turnComplete()
  expect(timers).toEqual([])
  expect(ran).toEqual([])
  settingsResult = new Promise(resolve => setTimeout(() => resolve({ exitCode: 0, stdout: porcelainWith('CS_ROTATE_FORCE_CTX'), stderr: '' }), 20))
  await turnComplete()
  expect(timers.map(t => t.kind)).toEqual(['after'])
})

test('a background a settings file pins outranks the dark theme the launch measured, on the queue glyph and the count alike', async () => {
  envVars.CS_TERM_THEME = 'dark'
  queueTasks(2)
  answerSettings(porcelainWith('CS_TERM_BG_RGB', '252;247;229', 'machine'))
  await sessionStart(); await settle()
  expect(await queueAmber()).toBe('rgb(180,83,9)')
  await startGrace()
  await tick(10)
  expect(countText(await keys()).props.color).toBe('rgb(180,83,9)')
})

// The loader drops the launch's measured background when a file pins the
// theme of the other polarity, and cs then reports the background as default:
// the environment's value is that dropped measurement, not a pin.
test('a file theme of the other polarity leaves the launch\'s measured background behind; one of the same polarity keeps it', async () => {
  queueTasks(2)
  envVars.CS_TERM_THEME = 'light'
  envVars.CS_TERM_BG_RGB = '252;247;229'
  const after = async (stdout: string) => { answerSettings(stdout); await turnStart('go'); await settle(); return queueAmber() }
  const darkFile = (bgValue?: string, bgSource?: string) => porcelainWith('CS_TERM_BG_RGB', bgValue, bgSource).split('\n').map((line: string) => {
    const fields = line.split('\t')
    if (fields[0] !== 'CS_TERM_THEME') return line
    fields[8] = 'dark'; fields[9] = 'machine'
    return fields.join('\t')
  }).join('\n')
  expect(await after(darkFile('-', 'default'))).toBe('rgb(251,191,36)')
  expect(await after(darkFile('252;247;229', 'launch'))).toBe('rgb(180,83,9)')
  expect(await after(darkFile('30;30;30', 'session'))).toBe('rgb(251,191,36)')
  expect(await after(darkFile('252;247;229', 'shell'))).toBe('rgb(180,83,9)')
  delete envVars.CS_TERM_BG_RGB
})

test('the count\'s amber takes a settings file\'s theme over the launch\'s', async () => {
  envVars.CS_TERM_THEME = 'dark'
  answerSettings(porcelainWith('CS_TERM_THEME', 'light', 'session'))
  await sessionStart(); await settle()
  await startGrace()
  await tick(10)
  expect(countText(await keys()).props.color).toBe('rgb(180,83,9)')
})

test('an answer that moves a setting redraws the band; the same answer again does not', async () => {
  answerSettings(porcelainWith('CS_TERM_THEME', 'light', 'machine'))
  await turnStart(''); await settle()
  expect(invalidated).toEqual(['ui.render'])
  await turnStart(''); await settle()
  expect(invalidated).toEqual(['ui.render'])
})

test('a failed, unreadable or unanswered read keeps the settings last read, and says so once a kind', async () => {
  queueTasks(2)
  envVars.CS_TERM_THEME = 'dark'
  const refresh = async () => { await turnStart('go'); await settle() }
  answerSettings(porcelainWith('CS_TERM_THEME', 'light', 'machine'))
  await refresh()
  settingsResult = { exitCode: 2, stdout: '', stderr: 'cs: no such command\nUsage: cs [<name>] -config list\n' }
  await refresh()
  await refresh()
  expect(await queueAmber()).toBe('rgb(180,83,9)')
  answerSettings(`${PORCELAIN}CS_EXTRA\tTerminal\tToo short\n`)
  await refresh()
  expect(await queueAmber()).toBe('rgb(180,83,9)')
  answerSettings(porcelainWith('CS_TERM_THEME', 'light', 'disk'))
  await refresh()
  expect(await queueAmber()).toBe('rgb(180,83,9)')
  settingsResult = new Error('timed out after 10000 ms')
  await refresh()
  expect(await queueAmber()).toBe('rgb(180,83,9)')
  expect(logs).toEqual([
    'cs -config list exited 2: Usage: cs [<name>] -config list',
    'cs -config list gave a record the band cannot read: CS_EXTRA\tTerminal\tToo short',
    'cs -config list gave a record the band cannot read: CS_TERM_THEME\tTerminal\tTheme\tchoice\tlight,dark\tdetected\tnow\tapplies at the next repaint\tlight\tdisk\t-\tWhether cs draws for a light or a dark terminal; unset, cs detects it at launch.',
    'cs\'s settings could not be read: timed out after 10000 ms',
  ])
})

// cs delivers each mail as one file in the mailbox's new/, where it stays
// until `cs -msg` reads it, behind .cs/private in an encrypted session.
const MAIL = '/work/.cs/local/mail'

test('unread mail draws a dim mail word, counting only the .json files directly in new/', async () => {
  files[`${MAIL}/new/1-a.json`] = '{}'
  files[`${MAIL}/new/2-b.json`] = '{}'
  files[`${MAIL}/new/3-c.tmp`] = '{}'
  files[`${MAIL}/cur/0-z.json`] = '{}'
  const tree = await band()
  expect(restingWords(tree)).toEqual(['mail 2'])
  expect(texts(tree)[0].props).toEqual({ dimColor: true })
  expect(buttons(tree)).toEqual([])
  delete files[`${MAIL}/new/1-a.json`]; delete files[`${MAIL}/new/2-b.json`]
  expect(await band()).toBe(DRAWN)
})

test('an encrypted session counts its mail behind .cs/private', async () => {
  existing.add('/work/.cs/private')
  files[`${MAIL}/new/1-a.json`] = '{}'
  files[`${MAIL}/new/2-b.json`] = '{}'
  files['/work/.cs/private/mail/new/3-c.json'] = '{}'
  expect(restingWords(await band())).toEqual(['mail 1'])
})

test('the mail word comes last, after the queue word, and never under a survey or in a teammate', async () => {
  queueTasks(2)
  files['/work/.cs/local/queue.state'] = 'armed\n'
  files[`${MAIL}/new/1-a.json`] = '{}'
  expect(restingWords(await band())).toEqual(['▤ queue 2 running', 'mail 1'])
  files['/work/.cs/local/queue.state'] = 'idle\n'
  const keyed = await band()
  expect(buttons(keyed).map((b: any) => b.props.key)).toEqual(['cs-queue'])
  expect(restingWords(keyed)).toEqual(['mail 1'])
  expect(await band({ hasSurvey: true })).toBe(DRAWN)
  sessionId = 'uuid-teammate'
  expect(await band()).toBe(DRAWN)
})

test('the queue word stands at the left and the mail word before the rail at the right edge, and the keys under the prompt take none of the line', async () => {
  transcript(LINEAR)
  await turnComplete()
  queueTasks(2)
  files['/work/.cs/local/queue.state'] = 'armed\n'
  files[`${MAIL}/new/1-a.json`] = '{}'
  const tree = await band()
  expect(rail(tree)).toEqual(['│', '│', '│', '┃'])
  // 108 cells after the inset less `▤ queue 2 running` (17), `mail 1` (6), three cells, the
  // name sized to `#3 say three` (12), three cells and the bars (4) leave 63 between the zones.
  expect(textOf(gapLabel(tree))).toBe(' #4 say four')
  expect(bandLine(tree, 110)).toBe(`  ▤ queue 2 running${' '.repeat(63)}mail 1    #4 say four   │││┃`)
  percent = 80
  expect(bandLine(await band(), 110)).toBe(`  ▤ queue 2 running${' '.repeat(63)}mail 1    #4 say four   │││┃`)
})

test('the mail word counts neither a stray file nor a directory in new/', async () => {
  files[`${MAIL}/new/1-a.json`] = '{}'
  files[`${MAIL}/new/.DS_Store`] = ''
  files[`${MAIL}/new/sub.json/2-b.json`] = '{}'
  expect(restingWords(await band())).toEqual(['mail 1'])
})

// ---------------------------------------------------------------------------
// cs's prompt-bar settings: CS_BAND_PROMPTS draws the bars, CS_BAND_PROMPT
// picks the prompt the band names (the newest, or the one being read), and
// CS_BAND_BARS the most bars before older prompts fold.

test('by default the band names the newest prompt and draws its bar thick, wherever the reader is; a scroll redraws nothing', async () => {
  transcript(LINEAR)
  await turnComplete()
  await band()
  invalidated = []
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  await fireAfter()
  expect(invalidated).toEqual([])
  const tree = await band()
  expect(textOf(gapLabel(tree))).toBe(' #4 say four')
  expect(rail(tree)).toEqual(['│', '│', '│', '┃'])
})

test('with CS_BAND_PROMPT=read the band names the prompt being read and draws its bar thick', async () => {
  envVars.CS_BAND_PROMPT = 'read'
  transcript(LINEAR)
  await turnComplete()
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  const tree = await band()
  expect(textOf(gapLabel(tree))).toBe('  #2 say two')
  expect(rail(tree)).toEqual(['│', '┃', '│', '│'])
})

test('at most CS_BAND_BARS bars draw, 10 when unset; older prompts fold into …N and the prompt is still named', async () => {
  const many = [prompt('u1', null, 'p1')]
  for (let i = 2; i <= 30; i++) many.push(reply(`a${i - 1}`, `u${i - 1}`), prompt(`u${i}`, `a${i - 1}`, `p${i}`))
  transcript(many)
  await turnComplete()
  let tree = await band()
  expect(rail(tree)).toEqual(['…20', ...Array(9).fill('│'), '┃'])
  // `…20`, its cell and ten bars are 14 cells; the name is as wide as the widest prompt a drawn bar can swap in.
  expect(textOf(gapLabel(tree))).toBe('#30 p30')
  expect(boxes(tree).find((b: any) => (b.children ?? []).flat(Infinity).includes(gapLabel(tree))).props.width).toBe(7)
  register(on as any)
  envVars.CS_BAND_BARS = '3'
  transcript(many, 2)
  await turnComplete()
  tree = await band()
  expect(rail(tree)).toEqual(['…27', '│', '│', '┃'])
  // A folded prompt has no bar to hover, so no card either.
  expect(boxes(tree).filter((b: any) => b.props.display === 'none')).toHaveLength(2)
})

test('/config has no row of the band\'s: the prompt bars are three cs settings, which /cs lists', () => {
  const manifest = JSON.parse(readFileSync(new URL('../.claude-plugin/plugin.json', import.meta.url), 'utf8'))
  expect(manifest.userConfig).toBeUndefined()
  expect(PORCELAIN.split('\n').filter((l: string) => l.startsWith('CS_BAND_')).map((l: string) => l.split('\t').slice(0, 6))).toEqual([
    ['CS_BAND_PROMPTS', 'Prompt bars', 'Prompt bars', 'flag', '-', 'off'],
    ['CS_BAND_PROMPT', 'Prompt bars', 'Named prompt', 'choice', 'latest,read', 'latest'],
    ['CS_BAND_BARS', 'Prompt bars', 'Most bars', 'text', '-', '10'],
  ])
})

test('a CS_BAND_BARS or CS_BAND_PROMPT the band cannot draw leaves it without bars and says so once a value; the rest of the band still runs', async () => {
  envVars.CS_BAND_BARS = '0'
  transcript(LINEAR)
  await turnComplete()
  files[`${MAIL}/new/1-a.json`] = '{}'
  // A teammate's band, like any the mod stays silent in, says nothing.
  sessionId = 'uuid-teammate'
  await band()
  expect(toasts).toEqual([])
  sessionId = 'uuid-lead'
  const tree = await band()
  expect(rail(tree)).toEqual([])
  expect(restingWords(tree)).toEqual(['mail 1'])
  await band()
  expect(toasts).toEqual(['the band draws no prompt bars: CS_BAND_BARS is a whole number of 1 or more; got 0. /cs shows where it is set.'])
  for (const bars of ['-2', '2.5', 'ten']) {
    envVars.CS_BAND_BARS = bars
    expect(rail(await band())).toEqual([])
    await band()
    expect(toasts.at(-1)).toBe(`the band draws no prompt bars: CS_BAND_BARS is a whole number of 1 or more; got ${bars}. /cs shows where it is set.`)
  }
  delete envVars.CS_BAND_BARS
  envVars.CS_BAND_PROMPT = 'first'
  expect(rail(await band())).toEqual([])
  expect(toasts.at(-1)).toBe('the band draws no prompt bars: CS_BAND_PROMPT is latest or read; got first. /cs shows where it is set.')
  expect(toasts).toHaveLength(5)
  delete envVars.CS_BAND_PROMPT
  expect(rail(await band())).toEqual(['│', '│', '│', '┃'])
  expect(toasts).toHaveLength(5)
  // With the bars off a bad value is said all the same.
  envVars.CS_BAND_PROMPTS = '0'
  envVars.CS_BAND_BARS = 'none'
  expect(rail(await band())).toEqual([])
  expect(toasts.slice(5)).toEqual(['the band draws no prompt bars: CS_BAND_BARS is a whole number of 1 or more; got none. /cs shows where it is set.'])
})

test('a settings file turns the prompt bars on, picks their prompt and turns them off again, each from the next prompt, with no reload', async () => {
  delete envVars.CS_BAND_PROMPTS
  transcript(LINEAR)
  await turnComplete()
  files[`${MAIL}/new/1-a.json`] = '{}'
  expect(rail(await band())).toEqual([])
  answerSettings(porcelainWith('CS_BAND_PROMPT', 'read', 'machine', porcelainWith('CS_BAND_PROMPTS', '1', 'session')))
  await turnStart('go'); await settle()
  await drawRow('u2', 'say two', { first: 0, last: 1, of: 2 })
  expect(rail(await band())).toEqual(['│', '┃', '│', '│'])
  answerSettings(porcelainWith('CS_BAND_PROMPTS', '0', 'session'))
  await turnStart('again'); await settle()
  const tree = await band()
  expect(rail(tree)).toEqual([])
  expect(restingWords(tree)).toEqual(['mail 1'])
  expect(toasts).toEqual([])
})

test('by cs\'s defaults the band draws no prompt bars and names no prompt; its other words still draw', async () => {
  delete envVars.CS_BAND_PROMPTS
  answerSettings(PORCELAIN)
  await sessionStart(); await settle()
  transcript(LINEAR)
  await turnComplete()
  expect(await keys()).toBe(HINT_DRAWN)
  percent = 80
  const tree = await keys()
  expect(rail(tree)).toEqual([])
  expect(gapLabel(tree)).toBeUndefined()
  expect(buttons(tree).map((b: any) => b.props.key)).toEqual(['cs-rotate', 'cs-wrap'])
  expect(toasts).toEqual([])
})

test('with the prompt bars off, a scroll redraws nothing, whichever prompt the band would name', async () => {
  Object.assign(envVars, READING, { CS_BAND_PROMPTS: '0' })
  transcript(LINEAR)
  await turnComplete()
  await band()
  invalidated = []
  await drawRow('u1', 'say one', { first: 0, last: 1, of: 2 })
  await fireAfter()
  expect(invalidated).toEqual([])
})

// ---------------------------------------------------------------------------
// A /finish gate running, as the band draws it.

const gateRuns = async () => {
  livePids.add('4242')
  nowMs = NOW * 1000
  await startFinish()
  record(running('gate', { gate_started: NOW - 3 }))
  await watchTick()
}

test('a rail alone stands at the right edge across the spacer, and the named prompt gives up its cells before the bars', async () => {
  transcript(LINEAR)
  await turnComplete()
  const tree = await band()
  expect(bandBody(tree).map((c: any) => c.props.key ?? c.type)).toEqual(['cs-spacer', 'Box', 'cs-rail'])
  expect(textOf(gapLabel(tree))).toBe(' #4 say four')
  // 20 columns: 18 after the inset, three cells and four bars leave 11, the named prompt whole.
  expect(bandLine(await band({ bodyColumns: 20 }), 20)).toBe('  #4 say four   │││┃')
  // 19 leave ten, cut; 18 nine: the bars alone.
  expect(bandLine(await band({ bodyColumns: 19 }), 19)).toBe('  #4 say fo…   │││┃')
  expect(bandLine(await band({ bodyColumns: 18 }), 18)).toBe(`  ${' '.repeat(12)}│││┃`)
  expect(gapLabel(await band({ bodyColumns: 18 }))).toBeUndefined()
})

// The engine flattens child lists and drops conditional empty children; the
// fixture's h keeps both, so snapshots compare the tree the engine draws.
function bandSnapshot(tree: any): unknown {
  if (Array.isArray(tree)) return tree.flat(Infinity).filter(child => child !== false && child !== undefined && child !== null).map(bandSnapshot)
  if (!tree || typeof tree !== 'object') return tree
  return { type: tree.type, props: tree.props, children: bandSnapshot(tree.children ?? []) }
}

const bandScenes: [string, () => void | Promise<void>, { isWorking?: boolean; hasSurvey?: boolean; bodyColumns?: number }?][] = [
  ['empty', () => {}],
  ['rotate and wrap', () => { percent = 40 }],
  ['wrapped', () => { percent = 40; files['/work/.cs/local/wrapped'] = 'uuid-lead\n' }],
  ['armed', () => { arm() }],
  ['countdown', async () => { arm(); await turnComplete() }],
  ['queue start', () => { queueTasks(2) }],
  ['running queue', () => { queueTasks(2); files['/work/.cs/local/queue.state'] = 'draining\n' }],
  ['mail', () => { files['/work/.cs/local/mail/new/one.json'] = '{}' }],
  ['gate', async () => { await gateRuns() }],
  ['survey gate', async () => { await gateRuns() }, { hasSurvey: true }],
  ['working', () => { percent = 40; queueTasks(2) }, { isWorking: true }],
  ['survey', () => { percent = 40; queueTasks(2) }, { hasSurvey: true }],
  ['features', async () => { featureDir('fix-auth'); porcelain(feature('fix-auth', 3, 'ready')); await featuresTurn() }],
  ['working features', async () => { featureDir('fix-auth'); porcelain(feature('fix-auth', 3, 'ready')); await featuresTurn() }, { isWorking: true }],
  ['rail', async () => { transcript(LINEAR); await turnComplete() }],
  ['narrow rail', async () => { transcript(LINEAR); await turnComplete() }, { bodyColumns: 21 }],
  ['mixed row', async () => { percent = 40; queueTasks(2); files['/work/.cs/local/mail/new/one.json'] = '{}'; transcript(LINEAR); await featuresTurn() }],
  ['filter chat on', () => { percent = 40; enableFilterChat(); files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=1\n' }],
]

// Each scene's band above the prompt and its keys under it, the keys as they
// stand in the hint's place.
for (const [name, arrange, props] of bandScenes) {
  test(`band and keys drawing snapshot: ${name}`, async () => {
    await arrange()
    expect(JSON.stringify({ band: bandSnapshot(await band(props)), keys: bandSnapshot(await footerHint()) })).toMatchSnapshot()
  })
}

// A design tool outside cs draws the band by calling drawBand with a view it spells out
// by hand, and the keys under the prompt by calling drawFooterKeys. Each view
// here is that fixture for one state: its band entries must draw the tree the
// handler draws from the same state's facts, and its footer entries the keys.
const noPress = () => {}
const noJump = async () => {}
const OWN = 'rgb(220,38,38)'
const CHORDS = { 'strip:jump1': 'ctrl+x 1', 'strip:jump2': 'ctrl+x 2' }
// The queue glyph's amber on a light terminal, or one that says nothing of its background.
const AMBER = 'rgb(180,83,9)'
// The filter chat key's dot while on: the palette's green.
const GREEN = 'rgb(22,163,74)'
const quiet = { rotating: false, armed: false, wrapping: false, waiting: 0, queued: 0, queueRunning: false, queueInk: AMBER, mail: 0, rotate: noPress, wrap: noPress, queue: noPress }
const FOUR = [{ uuid: 'u1', text: 'say one' }, { uuid: 'u2', text: 'say two' }, { uuid: 'u3', text: 'say three' }, { uuid: 'u4', text: 'say four' }]
const THIRTY = Array.from({ length: 30 }, (_, i) => ({ uuid: `m${i + 1}`, text: `step ${i + 1}` }))
const thirtyPrompts = () => transcript(THIRTY.flatMap((p, i) => [prompt(p.uuid, i === 0 ? null : `r${i}`, p.text), reply(`r${i + 1}`, p.uuid)]))
const railOf = (prompts: { uuid: string; text: string }[]) => ({ prompts, named: prompts.length - 1, denied: new Set<string>(), bars: 10, jump: noJump })
const view = (over: Partial<BandView>): BandView => ({ drawn: DRAWN as any, entries: [], chords: CHORDS, own: OWN, bodyColumns: 110, surface: 'terminal', ...over })
const railViews = (name: string, arrange: () => Promise<void>, prompts: { uuid: string; text: string }[]) =>
  [80, 60, 40].map(columns => [`${name} at ${columns}`, arrange, { bodyColumns: columns }, view({ bodyColumns: columns, rail: railOf(prompts) })] as const)

const bandViews: (readonly [string, () => void | Promise<void>, { isWorking?: boolean; hasSurvey?: boolean; bodyColumns?: number }, BandView])[] = [
  ['idle', () => {}, {}, view({})],
  ['rotate due', () => { percent = 40 }, {}, view({ entries: buildBandEntries({ ...quiet, rotating: true, wrapping: true }) })],
  ['armed', () => { arm() }, {}, view({ entries: buildBandEntries({ ...quiet, rotating: true, armed: true }) })],
  ['countdown', async () => { arm(); await turnComplete() }, {}, view({ entries: buildBandEntries({ ...quiet, countdown: { seconds: GRACE_SECONDS, ink: OWN }, rotating: true, armed: true }) })],
  ['filter chat off', () => { enableFilterChat(); files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=0\n' }, {}, view({ entries: buildBandEntries({ ...quiet, filterChat: { on: false, onPress: noPress } }) })],
  ['filter chat on', () => { enableFilterChat(); files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=1\n' }, {}, view({ entries: buildBandEntries({ ...quiet, filterChat: { on: true, onPress: noPress } }) })],
  ['queue', () => { queueTasks(2) }, {}, view({ entries: buildBandEntries({ ...quiet, waiting: 2 }) })],
  ['running queue', () => { queueTasks(2); files['/work/.cs/local/queue.state'] = 'draining\n' }, {}, view({ entries: buildBandEntries({ ...quiet, queued: 2, queueRunning: true }) })],
  ['gate', async () => { await gateRuns() }, {}, view({ entries: buildBandEntries({ ...quiet, gate: 'finishing fix-auth · gate 3s' }) })],
  ['mail', () => { files['/work/.cs/local/mail/new/one.json'] = '{}' }, {}, view({ entries: buildBandEntries({ ...quiet, mail: 1 }) })],
  ['features', async () => { featureDir('fix-auth'); porcelain(feature('fix-auth', 3, 'ready')); await featuresTurn() }, {}, view({ entries: buildBandEntries({ ...quiet, featured: { label: '1 feature · fix-auth ready', onPress: noPress } }) })],
  ['survey', async () => { await gateRuns() }, { hasSurvey: true }, view({ entries: buildBandEntries({ ...quiet, gate: 'finishing fix-auth · gate 3s' }) })],
  ...railViews('rail of four', async () => { transcript(LINEAR); await turnComplete() }, FOUR),
  ...railViews('rail of thirty', async () => { thirtyPrompts(); await turnComplete() }, THIRTY),
  ['rail with no room for a tick', async () => { transcript(LINEAR); await turnComplete() }, { bodyColumns: 5 }, view({ bodyColumns: 5, rail: railOf(FOUR) })],
]

for (const [name, arrange, props, fixture] of bandViews) {
  test(`drawBand and drawFooterKeys draw the handler's band and keys from a fixture view: ${name}`, async () => {
    await arrange()
    const drawn = JSON.stringify(bandSnapshot(await band(props)))
    expect(JSON.stringify(bandSnapshot(drawBand({ ...fixture, entries: entriesAt(fixture.entries, 'band') }, EL)))).toBe(drawn)
    const under = entriesAt(fixture.entries, 'footer')
    expect(JSON.stringify(bandSnapshot(under.length === 0 ? HINT_DRAWN : drawFooterKeys(under, EL)))).toBe(JSON.stringify(bandSnapshot(await footerHint())))
  })
}

// The band's rows as the terminal lays them out in `bodyColumns` cells: the
// inset, then each part in order, a Box's margins as blank cells and its
// `width` as the cells it holds, a Button its children or else its label, a
// hidden or absolute Box nothing (it takes no room in the row), and the band
// row's flexGrow child taking what the row's width leaves. With the pointer
// on the `hovered` scope, each part of that scope takes its hover props, and
// an absolute Box shown so paints over its parent's cells from its `left`.
// Parts that need more cells than the row has are what Claude Code draws
// over several rows (it squeezes each Text to a cell and wraps it down);
// that overrun draws here as the line cut into rows of the room, not as the
// squeeze itself. Every glyph the band draws here is one cell.
function bandRows(tree: any, bodyColumns: number, hovered?: string): string[] {
  const cells = (text: string) => [...text].length
  const propsOf = (node: any) => (hovered !== undefined && node.props.hover?.scope === hovered ? { ...node.props, ...node.props.hover } : node.props)
  const part = (node: any): string => {
    if (typeof node === 'string') return node
    if (Array.isArray(node)) return node.map(part).join('')
    if (!node || typeof node !== 'object') return ''
    const props = propsOf(node)
    if (props.display === 'none' || props.position === 'absolute') return ''
    const inner = node.type === 'Button' && (node.children ?? []).flat(Infinity).filter(Boolean).length === 0 ? props.label : part(node.children ?? [])
    if (node.type !== 'Box') return inner
    const { marginLeft = 0, marginRight = 0, width } = props
    if (width !== undefined && cells(inner) > width) throw new Error(`a Box ${width} cells wide holds ${cells(inner)}: ${inner}`)
    const held = [...`${inner}${' '.repeat(width === undefined ? 0 : width - cells(inner))}`]
    for (const card of (node.children ?? []).flat(Infinity)) {
      if (!card || typeof card !== 'object' || card.type !== 'Box') continue
      const shown = propsOf(card)
      if (shown.position !== 'absolute' || shown.display === 'none') continue
      const over = [...part(card.children ?? [])]
      if ((shown.left ?? 0) + over.length > held.length) throw new Error(`a card ${over.length} cells wide overruns a Box of ${held.length}: ${over.join('')}`)
      held.splice(shown.left ?? 0, over.length, ...over)
    }
    return `${' '.repeat(marginLeft)}${held.join('')}${' '.repeat(marginRight)}`
  }
  const row = boxes(tree).find((b: any) => b.props.key === 'cs-rotate-band')
  if (row === undefined) throw new Error('the band drew no line')
  const inset = row.props.marginLeft ?? 0
  const room = bodyColumns - inset
  const parts = (row.children ?? []).flat(Infinity).filter((child: any) => child !== false && child !== undefined && child !== null)
  const growing = parts.filter((child: any) => typeof child === 'object' && child.props.flexGrow > 0)
  if (growing.length > 1) throw new Error(`the band row has ${growing.length} growing parts`)
  const fixed = parts.map((child: any) => growing.includes(child) ? '' : part(child))
  const used = cells(fixed.join(''))
  const width = row.props.width ?? used
  const line = fixed.map((text: string, i: number) => growing.includes(parts[i]) ? ' '.repeat(Math.max(0, width - used)) : text).join('')
  if (width > room || used > width) {
    const glyphs = [...line]
    return Array.from({ length: Math.ceil(glyphs.length / room) }, (_, i) => `${i === 0 ? ' '.repeat(inset) : ''}${glyphs.slice(i * room, (i + 1) * room).join('')}`)
  }
  return [`${' '.repeat(inset)}${line}`]
}
// The band's one row; a band that draws more fails.
function bandLine(tree: any, bodyColumns: number): string {
  const [row, ...more] = bandRows(tree, bodyColumns)
  if (row === undefined || more.length > 0) throw new Error(`the band drew ${more.length + 1} rows at ${bodyColumns} columns: ${JSON.stringify([row, ...more])}`)
  return row
}
const EL = { Box: 'Box', Text: 'Text', Button: 'Button' } as any
const everything = buildBandEntries({ ...quiet, featured: { label: '3 features · fix-auth ready', onPress: noPress }, rotating: true, wrapping: true, filterChat: { on: true, onPress: noPress }, waiting: 2, mail: 1 })
const droppable = buildBandEntries({ ...quiet, featured: { label: '3 features · none ready' }, rotating: true, wrapping: true, gate: 'finishing fix-auth · gate 3s', queued: 2, mail: 1 })
const lineAt = (entries: any[], bodyColumns: number, rail?: BandView['rail']) => bandLine(drawBand(view({ entries, bodyColumns, rail }), EL), bodyColumns)
// `n` blank cells, for the spacer between the band's zones in a row written out.
const gap = (n: number) => ' '.repeat(n)

// The typical line at 120 columns: the actions at the left, then what the
// session is and the rail at the right edge, the spacer between them.
const FOURTEEN = Array.from({ length: 14 }, (_, i) => ({ uuid: `t${i + 1}`, text: i === 13 ? 'the band is too busy' : `step ${i + 1}` }))
const typical = buildBandEntries({ ...quiet, rotating: true, wrapping: true, filterChat: { on: true, onPress: noPress }, waiting: 2, mail: 1 })

// The rail at 120 columns: fourteen prompts, five bars, and the jump to the
// twelfth refused.
const REFUSED = { ...railOf(FOURTEEN), bars: 5, denied: new Set(['t12']) }

test('the band draws the actions at the left, and at the right edge the mail, the prompt\'s name, and the bars in the last cells', () => {
  // 118 cells after the inset: the actions 63, `mail 1` 6, three cells, the
  // name 24, three cells, `…9 ` 3 and five bars leave 11 between the zones.
  expect(lineAt(typical, 120, REFUSED)).toBe(`  ctrl+x 1 rotate   2 wrap · filter chat ●   ▤ run 2 queued tasks${gap(11)}mail 1   #14 the band is too busy   …9 ││┆│┃`)
  // With the rail off the mail word alone holds the right edge: 118 less 63 and 6 leave 49.
  expect(lineAt(typical, 120)).toBe(`  ctrl+x 1 rotate   2 wrap · filter chat ●   ▤ run 2 queued tasks${gap(49)}mail 1`)
})

test('with no actions the rail still ends in the line\'s last cell, the status words and the name before it', () => {
  // The rail alone: 118 less the name 24, three cells, `…9 ` 3 and five bars leave 83.
  expect(lineAt([], 120, REFUSED)).toBe(`  ${gap(83)}#14 the band is too busy   …9 ││┆│┃`)
  // `mail 1` and its three cells come out of the spacer.
  const mail = buildBandEntries({ ...quiet, mail: 1 })
  expect(lineAt(mail, 120, REFUSED)).toBe(`  ${gap(74)}mail 1   #14 the band is too busy   …9 ││┆│┃`)
})

test('a narrowing line cuts the name, then drops it, then folds the bars into …N, and the bars end in the last cell throughout', () => {
  const mail = buildBandEntries({ ...quiet, mail: 1 })
  const rail = { ...railOf(FOURTEEN), bars: 5 }
  // 32 columns leave the name ten cells, cut; 31 leave it nine, and none is named.
  expect(lineAt(mail, 32, rail)).toBe('  mail 1   #14 the b…   …9 ││││┃')
  expect(lineAt(mail, 31, rail)).toBe(`  ${gap(12)}mail 1   …9 ││││┃`)
  // 19 columns hold `…9 ` and five bars in the eight cells after the mail word; each cell fewer folds one more.
  expect(lineAt(mail, 19, rail)).toBe('  mail 1   …9 ││││┃')
  expect(lineAt(mail, 18, rail)).toBe('  mail 1   …11 ││┃')
  expect(lineAt(mail, 17, rail)).toBe('  mail 1   …12 │┃')
  expect(lineAt(mail, 16, rail)).toBe('  mail 1   …13 ┃')
  // A cell fewer holds the mail word and `…13 ┃` no more: the word leaves before the rail's least, and the rail takes the line.
  expect(lineAt(mail, 15, rail)).toBe(`  ${gap(5)}…9 ││││┃`)
})

test('a bar under the pointer swaps its prompt into the whole name box, and the bars stay where they stand', () => {
  const tree = drawBand(view({ entries: typical, bodyColumns: 120, rail: REFUSED }), EL)
  expect(bandRows(tree, 120, 'cs-rail-9')).toEqual([`  ctrl+x 1 rotate   2 wrap · filter chat ●   ▤ run 2 queued tasks${gap(11)}mail 1   ${gap(13)}#10 step 10   …9 ││┆│┃`])
  // The refused bar hovers as any other; the named one is a Text with no hover, so nothing swaps.
  expect(bandRows(tree, 120, 'cs-rail-11')).toEqual([`  ctrl+x 1 rotate   2 wrap · filter chat ●   ▤ run 2 queued tasks${gap(11)}mail 1   ${gap(13)}#12 step 12   …9 ││┆│┃`])
  expect(bandRows(tree, 120, 'cs-rail-13')).toEqual([`  ctrl+x 1 rotate   2 wrap · filter chat ●   ▤ run 2 queued tasks${gap(11)}mail 1   #14 the band is too busy   …9 ││┆│┃`])
})

test('while a clear counts down, the count follows its clear key and the right edge stays where it was', () => {
  const counting = buildBandEntries({ ...quiet, rotating: true, armed: true, countdown: { seconds: 18, ink: OWN }, mail: 1 })
  // `ctrl+x 1 /clear now   in 18s` (28) leaves 46 between the zones.
  expect(lineAt(counting, 120, { ...railOf(FOURTEEN), bars: 5 })).toBe(`  ctrl+x 1 /clear now   in 18s${gap(46)}mail 1   #14 the band is too busy   …9 ││││┃`)
})

test('the countdown never stands beside a bare clear key: it leaves before `/clear now` would lose its word, and the line is fitted again', () => {
  const counting = buildBandEntries({ ...quiet, rotating: true, armed: true, countdown: { seconds: 18, ink: OWN }, mail: 1 })
  // The count is an action, so beside the rail's least it would have to leave: the words take the whole line.
  expect(lineAt(counting, 28, { ...railOf(FOURTEEN), bars: 5 })).toBe('  1 /clear now   in 18s')
  // A cell short of `1 /clear now   in 18s`, the count leaves and the prefix comes back.
  expect(lineAt(counting, 22)).toBe('  ctrl+x 1 /clear now')
  expect(lineAt(counting, 19)).toBe('  1 /clear now')
  expect(lineAt(counting, 12)).toBe('  1')
  // A count that leaves for its key's sake is no action the rail can be owed:
  // the line keeps the same actions either way, so the rail keeps its least.
  expect(lineAt(counting, 22, { ...railOf(FOURTEEN), bars: 5 })).toBe('  1 /clear now   …13 ┃')
})

test('with no action to offer, what the session is still stands at the right edge, the spacer before it', () => {
  const tree = drawBand(view({ entries: buildBandEntries({ ...quiet, gate: 'finishing fix-auth · gate 3s', mail: 1 }), bodyColumns: 120 }), EL)
  expect(bandLine(tree, 120)).toBe(`  ${gap(81)}finishing fix-auth · gate 3s   mail 1`)
  expect(bandBody(tree).map((k: any) => k.props.key ?? textOf(k))).toEqual(['cs-spacer', 'finishing fix-auth · gate 3s', '   ', 'mail 1'])
})

test('the queue word draws at the left, where its start key would stand, across the spacer from the right edge', () => {
  const tree = drawBand(view({ entries: buildBandEntries({ ...quiet, queued: 2, mail: 1 }), bodyColumns: 120 }), EL)
  // 118 cells less `▤ queue 2` (9) and `mail 1` (6) leave 103 between them.
  expect(bandLine(tree, 120)).toBe(`  ▤ queue 2${gap(103)}mail 1`)
  expect(bandBody(tree).map((k: any) => k.props.key ?? textOf(k))).toEqual(['▤ queue 2', 'cs-spacer', 'mail 1'])
  expect(queueWordInks(tree)).toEqual([[{ color: 'rgb(180,83,9)' }, '▤'], [{ dimColor: true }, ' queue 2']])
})

test('a dim middle dot parts the keys, the clear key\'s count among them, from the presses and words after them, and stands nowhere else', () => {
  const dots = (tree: any) => texts(tree).filter((t: any) => textOf(t) === ' · ').map((t: any) => t.props)
  const after = drawBand(view({ entries: buildBandEntries({ ...quiet, rotating: true, armed: true, countdown: { seconds: 18, ink: OWN }, queued: 2 }), bodyColumns: 120 }), EL)
  expect(bandLine(after, 120)).toBe('  ctrl+x 1 /clear now   in 18s · ▤ queue 2')
  expect(dots(after)).toEqual([{ dimColor: true }])
  // A chord with no key bound is still a key.
  expect(bandLine(drawBand(view({ chords: {}, entries: buildBandEntries({ ...quiet, rotating: true, waiting: 1 }), bodyColumns: 120 }), EL), 120)).toBe('  rotate · ▤ run 1 queued task')
  // The filter chat key is a press: the dot parts it from the keys before it.
  expect(lineAt(buildBandEntries({ ...quiet, rotating: true, wrapping: true, filterChat: { on: true, onPress: noPress } }), 120)).toBe('  ctrl+x 1 rotate   2 wrap · filter chat ●')
  // Keys alone, a count after its clear key, and a press with no key before it draw no dot.
  expect(lineAt(buildBandEntries({ ...quiet, rotating: true, wrapping: true }), 120)).toBe('  ctrl+x 1 rotate   2 wrap')
  expect(lineAt(buildBandEntries({ ...quiet, rotating: true, armed: true, countdown: { seconds: 18, ink: OWN } }), 120)).toBe('  ctrl+x 1 /clear now   in 18s')
  const keyless = drawBand(view({ entries: buildBandEntries({ ...quiet, waiting: 2, mail: 1 }), bodyColumns: 120 }), EL)
  expect(bandLine(keyless, 120)).toBe(`  ▤ run 2 queued tasks${gap(92)}mail 1`)
  expect(dots(keyless)).toEqual([])
})

test('with only actions to offer, the line ends at its last action: no spacer, no right edge, and the row only as wide as its words', () => {
  const tree = drawBand(view({ entries: buildBandEntries({ ...quiet, rotating: true, wrapping: true }), bodyColumns: 120 }), EL)
  expect(bandLine(tree, 120)).toBe('  ctrl+x 1 rotate   2 wrap')
  expect(boxes(tree).filter((b: any) => ['cs-spacer', 'cs-status'].includes(b.props.key))).toEqual([])
  expect(boxes(tree).find((b: any) => b.props.key === 'cs-rotate-band').props).toEqual({ key: 'cs-rotate-band', marginLeft: 2 })
})

test('an entry the band has no zone for is a programmer error, named', () => {
  expect(() => drawBand(view({ entries: [{ key: 'cs-weather', kind: 'word', label: 'sunny' }] }), EL)).toThrow('cs: the band has no zone for cs-weather')
})

// Every combination of the band's nine entries at every width from 40 to 200:
// the band draws one row that fits the line, or nothing. The widths take
// turns at the chords (shared, apart, unbound) and the rail (on, off), so
// each combination meets every variant.
// Where the rail is on and every action still fits a line that holds the
// rail's least, `…13 ┃` and the three cells before it, the named bar draws.
// A sweep draws 82,432 lines: about 20 s on a Mac, three times that and more
// on a CI macOS runner. The limit only catches a hang.
const SWEEP_TIMEOUT = 180000
const ACTION_KEYS = ['cs-rotate', 'cs-countdown', 'cs-wrap', 'cs-filter-chat', 'cs-queue']
const RAIL_LEAST = 8
test('every combination of entries at every width from 40 to 200 draws one row no wider than the line, and keeps the rail whenever the actions leave it room', () => {
  const chordSets = [CHORDS, { 'strip:jump1': 'ctrl+x 1', 'strip:jump2': 'ctrl+w 2' }, {}]
  let drawn = 0
  let railKept = 0
  for (let bits = 0; bits < 512; bits++) {
    const on = (i: number) => (bits & (1 << i)) !== 0
    const entries = buildBandEntries({
      ...quiet,
      rotating: on(0), armed: on(1), countdown: on(1) ? { seconds: 18, ink: OWN } : undefined, wrapping: on(2),
      filterChat: on(3) ? { on: true, onPress: noPress } : undefined, waiting: on(4) ? 2 : 0,
      featured: on(5) ? { label: '3 features · fix-auth ready', onPress: noPress } : undefined,
      gate: on(6) ? 'finishing fix-auth · gate 3s' : undefined, queued: on(7) ? 2 : 0, mail: on(8) ? 1 : 0,
    })
    for (let bodyColumns = 40; bodyColumns <= 200; bodyColumns++) {
      const chords = chordSets[bodyColumns % 3]
      const rail = (bodyColumns >> 1) % 2 === 1 ? { ...railOf(FOURTEEN), bars: 5 } : undefined
      const tree = drawBand(view({ entries, chords, rail, bodyColumns }), EL)
      const kept = fitBand(entries, chords, bodyColumns - 2 - RAIL_LEAST).entries.map(entry => entry.key)
      const keptWhole = fitBand(entries, chords, bodyColumns - 2).entries.map(entry => entry.key)
      const railOwed = rail !== undefined && keptWhole.every(key => !ACTION_KEYS.includes(key) || kept.includes(key))
      if (railOwed) railKept++
      if (tree === DRAWN) {
        if (railOwed) throw new Error(`entries ${bits} at ${bodyColumns} columns drew nothing where the rail had room`)
        continue
      }
      const [row, ...more] = bandRows(tree, bodyColumns)
      if (row === undefined || more.length > 0 || [...row].length > bodyColumns) throw new Error(`entries ${bits} at ${bodyColumns} columns drew ${JSON.stringify([row, ...more])}`)
      if (railOwed && !row.includes('\u2503')) throw new Error(`entries ${bits} at ${bodyColumns} columns dropped the rail its actions left room for: ${row}`)
      drawn++
    }
  }
  // 512 combinations at 161 widths, less the empty one at the 81 widths without a rail.
  expect(drawn).toBe(512 * 161 - 81)
  // The rail is on at 80 widths; at 368 of their 40960 lines beside its
  // least the words lose an action the whole line keeps (the countdown at
  // 256, the queue press at 48, the filter chat key at 32, both presses at
  // 32), and there it may go.
  expect(railKept).toBe(80 * 512 - 368)
}, SWEEP_TIMEOUT)

// The same lines with cs.bandPrompt read, the named prompt anywhere: wherever
// the rail draws, its named bar draws, and wherever every action fits a line
// that holds the rail's least for that prompt (the named bar, `…N ` before
// it when older prompts fold, ` M…` after it when newer ones do, and the
// three cells before the rail), the rail draws.
test('with cs.bandPrompt read, every combination of entries at every width from 40 to 200 draws the named bar whenever the rail draws', () => {
  const chordSets = [CHORDS, { 'strip:jump1': 'ctrl+x 1', 'strip:jump2': 'ctrl+w 2' }, {}]
  const runCells = (folded: number) => (folded > 0 ? `${folded}`.length + 2 : 0)
  let railed = 0
  for (let bits = 0; bits < 512; bits++) {
    const on = (i: number) => (bits & (1 << i)) !== 0
    const entries = buildBandEntries({
      ...quiet,
      rotating: on(0), armed: on(1), countdown: on(1) ? { seconds: 18, ink: OWN } : undefined, wrapping: on(2),
      filterChat: on(3) ? { on: true, onPress: noPress } : undefined, waiting: on(4) ? 2 : 0,
      featured: on(5) ? { label: '3 features · fix-auth ready', onPress: noPress } : undefined,
      gate: on(6) ? 'finishing fix-auth · gate 3s' : undefined, queued: on(7) ? 2 : 0, mail: on(8) ? 1 : 0,
    })
    for (let bodyColumns = 40; bodyColumns <= 200; bodyColumns++) {
      const chords = chordSets[bodyColumns % 3]
      const named = (bits + bodyColumns) % FOURTEEN.length
      const rail = { ...railOf(FOURTEEN), bars: 5, named }
      const tree = drawBand(view({ entries, chords, rail, bodyColumns }), EL)
      const least = runCells(named) + 1 + runCells(FOURTEEN.length - 1 - named) + 3
      const kept = fitBand(entries, chords, bodyColumns - 2 - least).entries.map(entry => entry.key)
      const railOwed = entries.every(entry => !ACTION_KEYS.includes(entry.key) || kept.includes(entry.key))
      const railDrawn = tree !== DRAWN && boxes(tree).some((b: any) => b.props.key === 'cs-rail')
      if (railOwed && !railDrawn) throw new Error(`entries ${bits} at ${bodyColumns} columns, prompt ${named + 1} named, drew no rail where its actions left room`)
      if (!railDrawn) continue
      railed++
      const [row, ...more] = bandRows(tree, bodyColumns)
      if (row === undefined || more.length > 0 || [...row].length > bodyColumns) throw new Error(`entries ${bits} at ${bodyColumns} columns drew ${JSON.stringify([row, ...more])}`)
      if (!row.includes('\u2503')) throw new Error(`entries ${bits} at ${bodyColumns} columns, prompt ${named + 1} named, drew a rail without its named bar: ${row}`)
    }
  }
  expect(railed).toBeGreaterThan(0)
}, SWEEP_TIMEOUT)

// The rail with cs.bandPrompt read at 120 columns and on narrow lines: the
// drawn bars are the newest that fit, slid back only as far as the named
// one; the older prompts fold into `…N ` before them and the newer ones
// into ` M…` after them.
const reading = (named: number) => ({ ...railOf(FOURTEEN), bars: 5, named })
test('with the oldest prompt named the bars start at it and the newer prompts fold after them, ` M…` in the line\'s last cells', () => {
  const mail = buildBandEntries({ ...quiet, mail: 1 })
  expect(lineAt(mail, 120, reading(0))).toBe(`  ${gap(89)}mail 1   #1 step 1   ┃││││ 9…`)
  expect(lineAt(mail, 19, reading(0))).toBe('  mail 1   ┃││││ 9…')
  expect(lineAt(mail, 16, reading(0))).toBe('  mail 1   ┃ 13…')
})

test('with a middle prompt named the bars slide back to start at it, the older prompts folded before them and the newer after', () => {
  const mail = buildBandEntries({ ...quiet, mail: 1 })
  // The name is as wide as `#11 step 11`, the widest drawn bar's.
  expect(lineAt(mail, 120, reading(6))).toBe(`  ${gap(84)}mail 1   ${gap(2)}#7 step 7   …6 ┃││││ 3…`)
  expect(lineAt(mail, 19, reading(6))).toBe('  mail 1   …6 ┃│ 6…')
  // The least, `…6 ┃ 7…`, takes seven cells and three before them.
  expect(lineAt(mail, 18, reading(6))).toBe('  mail 1   …6 ┃ 7…')
  // A cell fewer holds the mail word and the least no more: the word leaves, and the rail takes the line.
  expect(lineAt(mail, 17, reading(6))).toBe(`  ${gap(4)}…6 ┃││││ 3…`)
})

test('with the newest prompt named the rail reads as it does with cs.bandPrompt latest', () => {
  const mail = buildBandEntries({ ...quiet, mail: 1 })
  expect(lineAt(mail, 120, reading(13))).toBe(`  ${gap(74)}mail 1   #14 the band is too busy   …9 ││││┃`)
  expect(lineAt(mail, 16, reading(13))).toBe('  mail 1   …13 ┃')
})

test('a bar drawn after the named one hovers and jumps to its own prompt, and a folded prompt has no bar', async () => {
  const jumped: number[] = []
  const tree = drawBand(view({ entries: buildBandEntries({ ...quiet, mail: 1 }), bodyColumns: 120, rail: { ...reading(6), jump: async (i: number) => { jumped.push(i) } } }), EL)
  expect(bandRows(tree, 120, 'cs-rail-10')).toEqual([`  ${gap(84)}mail 1   #11 step 11   …6 ┃││││ 3…`])
  const ticks = buttons(tree).filter((b: any) => b.props.key?.startsWith('cs-rail-'))
  expect(ticks.map((b: any) => b.props.key)).toEqual(['cs-rail-7', 'cs-rail-8', 'cs-rail-9', 'cs-rail-10'])
  for (const tick of ticks) await tick.props.onPress()
  expect(jumped).toEqual([7, 8, 9, 10])
})

test('every entry the band never drops stays whole at the narrowest line that holds them, and the features word shortens a cell under it', () => {
  // The actions without the prefix (56), three cells and the features press (27) hold 86 cells.
  expect(lineAt(everything, 88)).toBe('  1 rotate   2 wrap · filter chat ●   ▤ run 2 queued tasks   3 features · fix-auth ready')
  expect(lineAt(everything, 87)).toBe('  1 rotate   2 wrap · filter chat ●   ▤ run 2 queued tasks   3 features · fix-auth rea…')
})

test('a status word keeps at least its head, the words before its first `·`, and `…`: cut shorter it says nothing, so it leaves and the line is fitted again', () => {
  const oneReady = buildBandEntries({ ...quiet, featured: { label: '1 feature · fix-auth ready', onPress: noPress }, rotating: true, wrapping: true, filterChat: { on: true, onPress: noPress }, waiting: 3, mail: 1 })
  // `1 feature…` is the shortest the features press draws.
  expect(lineAt(oneReady, 78, railOf(FOUR))).toBe('  1 rotate   2 wrap · filter chat ●   ▤ run 3 queued tasks   1 feature…   │││┃')
  // A cell fewer would cut it into its head: it leaves, and the shared prefix comes back.
  expect(lineAt(oneReady, 77, railOf(FOUR))).toBe(`  ctrl+x 1 rotate   2 wrap · filter chat ●   ▤ run 3 queued tasks${gap(5)}   │││┃`)
  expect(lineAt(oneReady, 74, railOf(FOUR))).toBe(`  ctrl+x 1 rotate   2 wrap · filter chat ●   ▤ run 3 queued tasks${gap(2)}   │││┃`)
  expect(lineAt(oneReady, 70, railOf(FOUR))).toBe(`  1 rotate   2 wrap · filter chat ●   ▤ run 3 queued tasks${gap(5)}   │││┃`)
})

test('with every entry on, the band leaves out its lowest words, then shortens the free text before the actions, until it fits one line', () => {
  // 120, 80, 60 and 40 columns: the engine keeps five cells of each for the [-].
  expect(lineAt(everything, 115)).toBe(`  ctrl+x 1 rotate   2 wrap · filter chat ●   ▤ run 2 queued tasks${gap(14)}3 features · fix-auth ready   mail 1`)
  // At 80 the prefix goes and the features press shortens.
  expect(lineAt(everything, 75)).toBe(`  1 rotate   2 wrap · filter chat ●   ▤ run 2 queued tasks${gap(4)}3 features ·…`)
  // At 60 the features press would cut into its head: it leaves, and the queue press shortens.
  expect(lineAt(everything, 55)).toBe('  1 rotate   2 wrap · filter chat ●   ▤ run 2 queued t…')
  expect(lineAt(everything, 35)).toBe('  1 rotate   2 · filter chat ●   ▤…')
})

test('a shortened queue press keeps its count whole, or cuts to its glyph: cut inside `▤ run N` it would name another number', () => {
  const twelve = buildBandEntries({ ...quiet, rotating: true, wrapping: true, filterChat: { on: true, onPress: noPress }, waiting: 12 })
  expect(lineAt(twelve, 59)).toBe('  1 rotate   2 wrap · filter chat ●   ▤ run 12 queued tasks')
  expect(lineAt(twelve, 47)).toBe('  1 rotate   2 wrap · filter chat ●   ▤ run 12…')
  expect(lineAt(twelve, 46)).toBe('  1 rotate   2 wrap · filter chat ●   ▤…')
  expect(lineAt(twelve, 43)).toBe('  1 rotate   2 wrap · filter chat ●   ▤…')
})

test('the rail keeps its least, `…N ┃` three cells after the words, while the words can drop and shorten and still keep every action', () => {
  // 80 columns (75 after the [-]): the mail word drops, and the actions keep the prefix and leave the rail room for three bars.
  expect(lineAt(typical, 75, REFUSED)).toBe('  ctrl+x 1 rotate   2 wrap · filter chat ●   ▤ run 2 queued tasks   …11 ┆│┃')
  // With the features press too, the mail word drops and the press, cut into its head, leaves: the actions keep the prefix and the rail keeps three bars.
  expect(lineAt(everything, 75, REFUSED)).toBe('  ctrl+x 1 rotate   2 wrap · filter chat ●   ▤ run 2 queued tasks   …11 ┆│┃')
  // Without the filter chat key, as a band with no cs-filter-chat loaded draws it (docs/hooks.md), the features press stays, shortened, and the rail keeps its least.
  const noFilterChat = buildBandEntries({ ...quiet, featured: { label: '3 features · fix-auth ready', onPress: noPress }, rotating: true, wrapping: true, waiting: 2, mail: 1 })
  expect(lineAt(noFilterChat, 75, REFUSED)).toBe('  1 rotate   2 wrap · ▤ run 2 queued tasks   3 features · fix-auth…   …13 ┃')
  // 38 columns: the features press would cut into its head and leaves, the queue press shortens to a cell and `…`, and the rotate and wrap keys lose their words.
  expect(lineAt(everything, 38, REFUSED)).toBe('  1   2 · filter chat ●   ▤…   …11 ┆│┃')
  // 37 columns: the bare keys, the filter chat key and the queue's glyph leave the rail its least and a bar.
  expect(lineAt(everything, 37, REFUSED)).toBe('  1   2 · filter chat ●   ▤…   …12 │┃')
})

test('the actions outrank the rail: where an action would leave whole beside its least, the words take the whole line and the rail what they leave', () => {
  const differ = { 'strip:jump1': 'ctrl+x 1', 'strip:jump2': 'ctrl+w 2' }
  const at = (bodyColumns: number) => bandLine(drawBand(view({ chords: differ, entries: everything, bodyColumns, rail: REFUSED }), EL), bodyColumns)
  // The keys bare and the presses (40 cells), three cells and `…13 ┃` fill 50 columns.
  expect(at(50)).toBe('  ctrl+x 1   ctrl+w 2 · filter chat ●   ▤…   …13 ┃')
  // Two fewer and the queue press would leave: it stays, the features press would cut into its head and leaves, and no bar fits.
  expect(at(48)).toBe('  ctrl+x 1   ctrl+w 2 · filter chat ●   ▤…')
  // 40 columns (35 after the [-]), the chords shared: the keys, the rotate key's word and the presses take all 33 cells, the rail's least needs eight, and no bar draws.
  expect(lineAt(everything, 35, REFUSED)).toBe('  1 rotate   2 · filter chat ●   ▤…')
})

test('a chord drawn as its key alone is still its Button, pressed by its action, the key in the session colour', () => {
  const pressable = buttons(drawBand(view({ entries: everything, bodyColumns: 29 }), EL)).map((b: any) => [b.props.key, b.props.action, b.props.label, texts(b).map((t: any) => t.props)])
  expect(pressable).toEqual([
    ['cs-rotate', 'strip:jump1', '1', [{ bold: true, color: OWN }]],
    ['cs-wrap', 'strip:jump2', '2', [{ bold: true, color: OWN }]],
    ['cs-filter-chat', undefined, 'filter chat ●', [{ color: GREEN }]],
    ['cs-queue', undefined, '▤…', [{ color: 'rgb(180,83,9)' }]],
  ])
})

test('a cut that lands after a space drops the space before the ellipsis, in the band\'s words and the rail\'s prompt alike', () => {
  const shop = [{ uuid: 'u1', text: 'say one' }, { uuid: 'u2', text: 'go to the shop' }]
  // 17 cells leave the named prompt 10: `#2 go to ` and `…`, the space dropped and the cell padded.
  expect(textOf(gapLabel(drawBand(view({ bodyColumns: 17, rail: railOf(shop) }), EL)))).toBe(' #2 go to…')
})

test('when even the keys overrun, the queue press leaves whole, then the filter chat key, then the chords right to left', () => {
  // The features press, which would cut into its head, has left already.
  expect(lineAt(everything, 28)).toBe('  1   2 · filter chat ●   ▤…')
  expect(lineAt(everything, 27)).toBe('  1   2 · filter chat ●')
  expect(lineAt(everything, 23)).toBe('  1   2 · filter chat ●')
  // With the filter chat key gone, the chords take their words back where they fit.
  expect(lineAt(everything, 22)).toBe('  1 rotate   2 wrap')
  expect(lineAt(everything, 20)).toBe('  1 rotate   2 wrap')
  expect(lineAt(everything, 19)).toBe('  1 rotate   2 wrap')
  expect(lineAt(everything, 18)).toBe('  1 rotate   2')
  expect(lineAt(everything, 14)).toBe('  1 rotate   2')
  expect(lineAt(everything, 13)).toBe('  1   2')
  expect(lineAt(everything, 7)).toBe('  1   2')
  expect(lineAt(everything, 6)).toBe('  1')
  expect(lineAt(everything, 3)).toBe('  1')
  // A line with no entry left draws nothing.
  expect(drawBand(view({ entries: everything, bodyColumns: 2 }), EL)).toBe(DRAWN)
})

test('the queue press never shortens past `▤…`: it leaves whole, and a line it was alone on draws nothing', () => {
  const queue = buildBandEntries({ ...quiet, waiting: 3 })
  expect(lineAt(queue, 4)).toBe('  ▤…')
  expect(drawBand(view({ entries: queue, bodyColumns: 3 }), EL)).toBe(DRAWN)
})

test('the countdown is free text after its clear key: it leaves before its own key loses its word, and the filter chat key outlasts it', () => {
  const counting = buildBandEntries({ ...quiet, featured: { label: '3 features · fix-auth ready', onPress: noPress }, countdown: { seconds: 30, ink: OWN }, rotating: true, armed: true, filterChat: { on: true, onPress: noPress }, queued: 2, mail: 1 })
  expect(lineAt(counting, 102)).toBe(`  ctrl+x 1 /clear now   in 30s · filter chat ●   ▤ queue 2${gap(8)}3 features · fix-auth ready   mail 1`)
  expect(lineAt(counting, 39)).toBe('  1 /clear now   in 30s · filter chat ●')
  // A cell fewer would key the clear bare: the count leaves, and the prefix comes back.
  expect(lineAt(counting, 38)).toBe('  ctrl+x 1 /clear now · filter chat ●')
  expect(lineAt(counting, 19)).toBe('  1 · filter chat ●')
})

test('the band drops mail, the queue count, an unpressable features word, the gate word and then the chord prefix, in that order', () => {
  expect(lineAt(droppable, 104)).toBe('  ctrl+x 1 rotate   2 wrap · ▤ queue 2   3 features · none ready   finishing fix-auth · gate 3s   mail 1')
  expect(lineAt(droppable, 103)).toBe(`  ctrl+x 1 rotate   2 wrap · ▤ queue 2${gap(11)}3 features · none ready   finishing fix-auth · gate 3s`)
  expect(lineAt(droppable, 95)).toBe('  ctrl+x 1 rotate   2 wrap · ▤ queue 2   3 features · none ready   finishing fix-auth · gate 3s')
  expect(lineAt(droppable, 94)).toBe(`  ctrl+x 1 rotate   2 wrap${gap(14)}3 features · none ready   finishing fix-auth · gate 3s`)
  expect(lineAt(droppable, 83)).toBe('  ctrl+x 1 rotate   2 wrap   3 features · none ready   finishing fix-auth · gate 3s')
  expect(lineAt(droppable, 82)).toBe(`  ctrl+x 1 rotate   2 wrap${gap(28)}finishing fix-auth · gate 3s`)
  expect(lineAt(droppable, 57)).toBe('  ctrl+x 1 rotate   2 wrap   finishing fix-auth · gate 3s')
  expect(lineAt(droppable, 56)).toBe('  ctrl+x 1 rotate   2 wrap')
  expect(lineAt(droppable, 26)).toBe('  ctrl+x 1 rotate   2 wrap')
  expect(lineAt(droppable, 25)).toBe('  1 rotate   2 wrap')
  expect(lineAt(droppable, 19)).toBe('  1 rotate   2 wrap')
  expect(lineAt(droppable, 18)).toBe('  1 rotate   2')
})

test('chords that differ fall back to their whole chord, right to left; the last leaves whole, and the one left takes its word back when it fits', () => {
  const differ = { 'strip:jump1': 'ctrl+x 1', 'strip:jump2': 'ctrl+w 2' }
  const at = (bodyColumns: number) => bandLine(drawBand(view({ chords: differ, entries: buildBandEntries({ ...quiet, rotating: true, wrapping: true }), bodyColumns }), EL), bodyColumns)
  expect(at(33)).toBe('  ctrl+x 1 rotate   ctrl+w 2 wrap')
  expect(at(32)).toBe('  ctrl+x 1 rotate   ctrl+w 2')
  expect(at(28)).toBe('  ctrl+x 1 rotate   ctrl+w 2')
  expect(at(27)).toBe('  ctrl+x 1   ctrl+w 2')
  expect(at(21)).toBe('  ctrl+x 1   ctrl+w 2')
  expect(at(20)).toBe('  ctrl+x 1 rotate')
  expect(at(17)).toBe('  ctrl+x 1 rotate')
  expect(at(16)).toBe('  ctrl+x 1')
  expect(at(10)).toBe('  ctrl+x 1')
})

test('with chords that differ, every chord outlives the features, queue and filter chat presses', () => {
  const differ = { 'strip:jump1': 'ctrl+x 1', 'strip:jump2': 'ctrl+w 2' }
  const at = (bodyColumns: number) => bandLine(drawBand(view({ chords: differ, entries: everything, bodyColumns }), EL), bodyColumns)
  // The features press would cut into its head, so it has left.
  expect(at(46)).toBe('  ctrl+x 1   ctrl+w 2 · filter chat ●   ▤…')
  expect(at(45)).toBe('  ctrl+x 1   ctrl+w 2 · filter chat ●   ▤…')
  expect(at(42)).toBe('  ctrl+x 1   ctrl+w 2 · filter chat ●   ▤…')
  expect(at(41)).toBe('  ctrl+x 1   ctrl+w 2 · filter chat ●')
  expect(at(37)).toBe('  ctrl+x 1   ctrl+w 2 · filter chat ●')
  // The filter chat key leaves, and the two chords take their words back.
  expect(at(36)).toBe('  ctrl+x 1 rotate   ctrl+w 2 wrap')
})

test('an unbound chord has no key to fall back to: the filter chat press before it leaves whole, then the last chord cuts its word to end in `…`, and leaves when not a cell of it fits', () => {
  const at = (bodyColumns: number) => bandLine(drawBand(view({ chords: {}, entries: buildBandEntries({ ...quiet, rotating: true, wrapping: true, filterChat: { on: true, onPress: noPress } }), bodyColumns }), EL), bodyColumns)
  expect(at(31)).toBe('  rotate   wrap · filter chat ●')
  expect(at(30)).toBe('  rotate   wrap')
  expect(at(14)).toBe('  rotate   wr…')
  expect(at(11)).toBe('  rotate')
})

test('the rail takes what the line leaves once the band has fitted its words', () => {
  // Every word holds at 114, and the seven cells left after them and the three before the bars hold four bars and no name.
  expect(lineAt(droppable, 114, railOf(FOUR))).toBe(`  ctrl+x 1 rotate   2 wrap · ▤ queue 2${gap(6)}3 features · none ready   finishing fix-auth · gate 3s   mail 1   │││┃`)
})

test('a band with no words and no room for a tick draws nothing', async () => {
  transcript(LINEAR)
  await turnComplete()
  // Five columns leave three cells after the inset, and `…3`, its cell and a bar take four.
  expect(await band({ bodyColumns: 5 })).toBe(DRAWN)
  expect(boxes(await band({ bodyColumns: 6 })).some((b: any) => b.props.key === 'cs-rail')).toBe(true)
})

test('band entries keep the drawn rotate and wrap labels in order', async () => {
  percent = 40
  const drawnLabels = buttons(await keys()).map(button => button.props.label)
  const press = () => {}
  const entries = buildBandEntries({ rotating: true, armed: false, wrapping: true, waiting: 0, queued: 0, queueRunning: false, queueInk: AMBER, mail: 0, rotate: press, wrap: press, queue: press })
  expect(entries.map(entry => entry.label)).toEqual(drawnLabels)
  expect(entries.map(entry => entry.label)).toEqual(['rotate', 'wrap'])
})

const filterChatKey = (tree: any) => buttons(tree).find(button => button.props.key === 'cs-filter-chat')
const enableFilterChat = () => {
  availableCommands = [{ name: 'filter-chat', source: 'plugin', plugin: 'cs-filter-chat' }]
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
}

test('the filter chat key toggles this session, answers no chord, and colours its dot green only while on', async () => {
  enableFilterChat()
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=0\n'
  percent = 40
  const tree = await keys()
  expect(filterChatKey(tree)?.props.label).toBe('filter chat ○')
  expect(buttons(tree).find(button => button.props.label === 'filter chat ○')?.props.key).toBe('cs-filter-chat')
  expect(filterChatKey(tree).props.action).toBeUndefined()
  expect(bandWords(tree)).toEqual(['rotate', ' · ', 'wrap', ' · ', 'filter chat ○'])
  await filterChatKey(tree).props.onPress()
  expect(runs.map(run => run.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work'], ['/opt/cs/bin/cs', 'work', '-config', 'set', 'CS_FILTER_CHAT', '1']])
  const on = await keys()
  expect(filterChatKey(on).props.label).toBe('filter chat ●')
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=1\n')
  expect(texts(filterChatKey(on)).map(text => [textOf(text), text.props.color])).toEqual([['●', GREEN]])
  expect(ran).toEqual([])
  expect(invalidated).toEqual(['ui.render'])
  await filterChatKey(on).props.onPress()
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=0\n')
  expect(ran).toEqual([])
  expect(invalidated).toEqual(['ui.render', 'ui.render'])
})

test('a filter chat press refuses a session whose control files are tracked', async () => {
  enableFilterChat()
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=1\n'
  runResult = tracked
  await filterChatKey(await keys()).props.onPress()
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=1\n')
  expect(written).toEqual({})
  expect(runs.map(run => run.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(toasts).toEqual([`no rotation in this session: ${TRACKED}`])
  expect(invalidated).toEqual(['ui.render'])
  runResult = VETTED
  await filterChatKey(await keys()).props.onPress()
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=0\n')
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  await filterChatKey(await keys()).props.onPress()
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=1\n')
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ●')
})

// A prompt clears the handoff's refusal so its toast says it again, but cs's
// answer on the session's control files still stands for the filter chat key:
// a refused vet keeps the key off until a vet passes or the mod loads again.
test('a refused session keeps the filter chat key off across prompts, whichever vet refused it', async () => {
  enableFilterChat()
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=1\n'
  runResult = tracked
  await startSession()
  expect(runs.map(run => run.argv)).toEqual([['/opt/cs/bin/cs', '-vet-session', '/work']])
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  await promptSubmit()
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  await filterChatKey(await keys()).props.onPress()
  await promptSubmit()
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=1\n')
  runResult = VETTED
  await filterChatKey(await keys()).props.onPress()
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=0\n')
  await filterChatKey(await keys()).props.onPress()
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ●')
})

test('a filter chat press survives clearing the conversation and loading the band again', async () => {
  enableFilterChat()
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=0\n'
  await filterChatKey(await keys()).props.onPress()
  sessionId = 'uuid-next'
  files['/work/.cs/local/state'] = 'claude_session_color: red\nclaude_session_id: uuid-next\n'
  register(on as any)
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ●')
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=1\n')
  for (const content of ['', 'CS_FILTER_CHAT=0\n', 'CS_FILTER_CHAT_X=1\n', 'CS_FILTER_CHAT=1\nCS_FILTER_CHAT=0\n', 'CS_FILTER_CHAT=yes\n', ' CS_FILTER_CHAT=1\n', 'CS_FILTER_CHAT=1\r\n']) {
    files['/work/.cs/local/config'] = content
    expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  }
  delete files['/work/.cs/local/config']
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  await filterChatKey(await keys()).props.onPress()
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=1\n')
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ●')
})

test('a cs write that fails toasts cs\'s words, keeps the setting and allows another press', async () => {
  enableFilterChat()
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=1\n'
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ●')
  nextRuns = [VETTED, { exitCode: 2, stdout: '', stderr: 'warming up\nError: not changed\n' }]
  await filterChatKey(await keys()).props.onPress()
  expect(invalidated).toEqual(['ui.render'])
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ●')
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=1\n')
  expect(toasts).toEqual(['filter chat update failed: Error: not changed'])
  await filterChatKey(await keys()).props.onPress()
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  expect(invalidated).toEqual(['ui.render', 'ui.render'])
})

for (const [name, env, seeded, label] of [
  ['the environment pins on over the session file', { CS_FILTER_CHAT: '1' }, { '/work/.cs/local/config': 'CS_FILTER_CHAT=0\n' }, 'filter chat ●'],
  ['the environment pins off over the session file', { CS_FILTER_CHAT: '0' }, { '/work/.cs/local/config': 'CS_FILTER_CHAT=1\n' }, 'filter chat ○'],
  ['the last accepted line of the session file wins', {}, { '/work/.cs/local/config': 'CS_FILTER_CHAT=0\nCS_FILTER_CHAT=1\nCS_FILTER_CHAT=yes\n' }, 'filter chat ●'],
  ['this machine\'s file answers where the session file says nothing', { XDG_CONFIG_HOME: '/x' }, { '/x/cs/config': 'CS_FILTER_CHAT=1\n' }, 'filter chat ●'],
  ['the session file off outranks this machine\'s file', { XDG_CONFIG_HOME: '/x' }, { '/work/.cs/local/config': 'CS_FILTER_CHAT=0\n', '/x/cs/config': 'CS_FILTER_CHAT=1\n' }, 'filter chat ○'],
  ['no file says, so the key reads off', {}, {}, 'filter chat ○'],
] as const) test(`the filter chat key reads the setting as cs resolves it: ${name}`, async () => {
  enableFilterChat()
  Object.assign(envVars, env)
  Object.assign(files, seeded)
  expect(filterChatKey(await keys()).props.label).toBe(label)
})

test('duplicate filter chat presses both wait until the one write is ready', async () => {
  enableFilterChat()
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=0\n'
  const run = $.process.run
  let finish = () => {}
  const writes: string[][] = []
  $.process.run = async (argv: string[], init: any) => {
    if (argv.includes('-config')) {
      writes.push(argv)
      await new Promise<void>(resolve => { finish = resolve })
    }
    return run(argv, init)
  }
  try {
    const key = filterChatKey(await keys())
    let duplicateFinished = false
    const press = key.props.onPress().then(() => files['/work/.cs/local/config'])
    const duplicate = key.props.onPress().then(() => {
      duplicateFinished = true
      return files['/work/.cs/local/config']
    })
    await settle()
    expect(duplicateFinished).toBe(false)
    expect(writes).toEqual([['/opt/cs/bin/cs', 'work', '-config', 'set', 'CS_FILTER_CHAT', '1']])
    expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
    expect(invalidated).toEqual([])
    finish()
    expect(await Promise.all([press, duplicate])).toEqual(['CS_FILTER_CHAT=1\n', 'CS_FILTER_CHAT=1\n'])
    expect(filterChatKey(await keys()).props.label).toBe('filter chat ●')
    expect(invalidated).toEqual(['ui.render'])
    expect(ran).toEqual([])
  } finally {
    finish()
    $.process.run = run
  }
})

test('a non-session redraw does not discover the filter chat command', async () => {
  enableFilterChat()
  cwdPath = '/outside'
  const list = $.command.list
  let listed = 0
  $.command.list = async () => { listed++; return list() }
  try {
    expect(await keys()).toBe(HINT_DRAWN)
    expect(await keys()).toBe(HINT_DRAWN)
    expect(listed).toBe(0)
    expect(runs).toEqual([])
  } finally {
    $.command.list = list
  }
})

test('the filter chat key draws idle and mid-turn, follows command availability and the band ownership gates', async () => {
  enableFilterChat()
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=0\n'
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  expect(filterChatKey(await keys({ isWorking: true })).props.label).toBe('filter chat ○')
  expect(filterChatKey(await keys({ hasSurvey: true }))).toBeUndefined()
  sessionId = 'uuid-teammate'
  expect(filterChatKey(await keys())).toBeUndefined()
  sessionId = 'uuid-lead'
  arm()
  expect(buttons(await keys()).map(button => button.props.key)).toEqual(['cs-rotate'])
  delete files[MARKER]
  for (const command of [undefined, { name: 'filter-chat', source: 'user' }, { name: 'filter-chat', source: 'plugin', plugin: 'another-plugin' }]) {
    availableCommands = command === undefined ? [] : [command]
    expect(await keys()).toBe(HINT_DRAWN)
  }
  expect(ran).toEqual([{ command: 'color', args: 'red' }, { command: 'color', args: 'red' }])
})

test('filter chat state stays with its session across registration and stale button presses', async () => {
  enableFilterChat()
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=0\n'
  const stale = filterChatKey(await keys())
  await stale.props.onPress()
  register(on as any)
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ●')
  await stale.props.onPress()
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  expect(ran).toEqual([])
  await filterChatKey(await keys()).props.onPress()
  sessionId = 'uuid-next'
  cwdPath = '/other'
  existing.add('/other/.cs/local')
  realPaths['/other'] = '/other'
  realPaths['/home/.claude-sessions/other'] = '/other'
  files['/other/.cs/local/state'] = 'claude_session_color: red\nclaude_session_id: uuid-next\n'
  files['/other/.cs/local/config'] = 'CS_FILTER_CHAT=0\n'
  register(on as any)
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=1\n')
})

test('a companion filter chat file change appears on the next redraw without reloading', async () => {
  enableFilterChat()
  const stale = filterChatKey(await keys())
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=1\n'
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ●')
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=0\n'
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=1\n'
  await stale.props.onPress()
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=0\n')
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  expect(ran).toEqual([])
})

test('an unreadable filter chat file leaves the band visible and reports each read error once', async () => {
  enableFilterChat()
  percent = 40
  cwdPath = '/ENOENT'
  existing.add('/ENOENT/.cs/local')
  realPaths['/ENOENT'] = '/ENOENT'
  realPaths['/home/.claude-sessions/ENOENT'] = '/ENOENT'
  files['/ENOENT/.cs/local/state'] = 'claude_session_color: red\nclaude_session_id: uuid-lead\n'
  const read = $.fs.read
  let error = 'cs: $.fs.read(/ENOENT/.cs/local/config) failed: EACCES'
  $.fs.read = async path => {
    if (path === '/ENOENT/.cs/local/config') throw new Error(error)
    return read(path)
  }
  try {
    for (let redraw = 0; redraw < 2; redraw++) {
      expect(buttons(await keys()).map(button => button.props.label)).toEqual(['rotate', 'wrap', 'filter chat ○'])
    }
    expect(logs).toEqual(['the filter chat setting could not be read: cs: $.fs.read(/ENOENT/.cs/local/config) failed: EACCES'])
    error = 'cs: $.fs.read(/ENOENT/.cs/local/config) failed: EISDIR'
    expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
    expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
    expect(logs).toEqual([
      'the filter chat setting could not be read: cs: $.fs.read(/ENOENT/.cs/local/config) failed: EACCES',
      'the filter chat setting could not be read: cs: $.fs.read(/ENOENT/.cs/local/config) failed: EISDIR',
    ])
    expect(toasts).toEqual([])
    expect(written).toEqual({})
    expect(invalidated).toEqual([])
    expect(ran).toEqual([])
  } finally {
    $.fs.read = read
  }
})

test('filter chat presses use the local directory even when private storage exists', async () => {
  enableFilterChat()
  existing.add('/work/.cs/private')
  files['/work/.cs/private/config'] = 'CS_FILTER_CHAT=1\n'
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=0\n'
  expect(filterChatKey(await keys()).props.label).toBe('filter chat ○')
  await filterChatKey(await keys()).props.onPress()
  await filterChatKey(await keys()).props.onPress()
  expect(files['/work/.cs/local/config']).toBe('CS_FILTER_CHAT=0\n')
  expect(files['/work/.cs/private/config']).toBe('CS_FILTER_CHAT=1\n')
  expect(ran).toEqual([])
})

// ---------------------------------------------------------------------------
// The lines the mod hands the engine on paths the tests above do not walk:
// a toast, a transcript notice and a /cs reply each, in their exact words.

test('a transcript past 4 MiB is read by its tail, and a toast says the rail lists only its prompts', async () => {
  transcript(LINEAR)
  files[TRANSCRIPT] += ' '.repeat(4 * 1024 * 1024)
  runResult = { exitCode: 0, stdout: `${LINEAR.join('\n')}\n`, stderr: '' }
  await turnComplete({ reason: 'aborted' })
  expect(runs.map(r => r.argv[0])).toEqual(['tail'])
  expect(toasts).toEqual(['the transcript is over 4 MiB; the rail lists the prompts of its tail'])
})

test('a transcript that cannot be read is logged with the reason', async () => {
  transcript(LINEAR)
  const read = $.fs.read
  $.fs.read = async (path: string) => { if (path === TRANSCRIPT) throw new Error('EACCES'); return read(path) }
  try {
    await turnComplete({ reason: 'aborted' })
  } finally {
    $.fs.read = read
  }
  expect(logs).toEqual(['the transcript could not be read: EACCES'])
})

test('a features reading that fails before cs is asked is logged with the reason', async () => {
  featureDir('fix-auth')
  const every = $.clock.every
  $.clock.every = () => { throw new Error('clock refused') }
  try {
    await featuresTurn()
  } finally {
    $.clock.every = every
  }
  expect(featureRuns()).toEqual([])
  expect(logs).toEqual(['the features word could not be read: clock refused'])
})

test('/cs next on the last prompt says there is none after it', async () => {
  transcript(LINEAR)
  await turnComplete()
  expect(await cs('next')).toEqual({ text: 'no prompt after this one' })
})

test('a /finish record cs did not write is toasted once, and the watch shows no progress', async () => {
  await startFinish()
  files[RECORD] = '{"id": 1'
  await watchTick()
  await watchTick()
  expect(toasts).toEqual(['.cs/local/finish-progress.json is not a record cs wrote; /finish progress is not shown'])
})

test('a /finish whose pid cannot be checked is toasted once and counts as over', async () => {
  await startFinish()
  record(running('merging'))
  const run = $.process.run
  $.process.run = async (argv: string[], init: any) => { if (argv[0] === 'kill') throw new Error('spawn EPERM'); return run(argv, init) }
  try {
    await watchTick()
    await watchTick()
  } finally {
    $.process.run = run
  }
  expect(toasts).toEqual(['finishing fix-auth', 'cannot tell whether /finish is still running: spawn EPERM'])
})

// Claude Code leads every toast, transcript notice and command reply with the
// name of the plugin that sent it, so a line that names cs itself reads
// `cs: cs: ...`.
test('no toast, notice or command reply the mod hands the engine starts with its own name', () => {
  const lines = [...Object.values(TOASTS), ...Object.values(LOGS), ...Object.values(REPLIES)]
    .map(entry => typeof entry === 'function' ? (entry as (...args: string[]) => string)('x', 'x', 'x') : entry)
    .concat(['merging', 'landed', 'refused', 'retired'].map(step => finishToast({ id: 'x', pid: 1, task: 'x', sha: 'x', step })))
  expect(lines.filter(line => line.startsWith('cs:'))).toEqual([])
})

// The keys under the prompt. Measured on Claude Code 2.1.322: a status line of
// 82 cells left the keys their place at the notice's right from 87 columns
// and not at 86, one of 95 cells from 100 and not at 99; bypass permissions,
// the widest notice, kept its 48 cells clear of the three keys' 29 from 80.
const THREE_KEYS = 29
const route = (columns: number | undefined, statusWidth: number | undefined, modesCells: number | undefined, keysCells: number, hint: string | undefined = CYCLE, fullscreen = true) =>
  keysRoute({ columns, fullscreen, statusWidth, modesCells, hint, keysCells })
test('the keys go to the notice\'s right only where the status line, the mode labels and the notice leave them room', () => {
  expect(route(87, 82, 0, THREE_KEYS)).toBe('notice-right')
  expect(route(86, 82, 0, THREE_KEYS)).toBe('inline')
  expect(route(100, 95, 0, THREE_KEYS)).toBe('notice-right')
  expect(route(99, 95, 0, THREE_KEYS)).toBe('inline')
  // The notice binds where the status line is short.
  expect(route(80, 60, 0, THREE_KEYS)).toBe('notice-right')
  expect(route(79, 60, 0, THREE_KEYS)).toBe('inline')
  // Mode labels at the status line's right take their cells from the same row.
  expect(route(100, 60, 35, THREE_KEYS)).toBe('notice-right')
  expect(route(99, 60, 35, THREE_KEYS)).toBe('inline')
  // Fewer keys need less of the notice's row, never less of the status line's.
  expect(route(68, 60, 0, 17)).toBe('notice-right')
  expect(route(67, 60, 0, 17)).toBe('inline')
  expect(route(64, 60, 0, 6)).toBe('inline')
  // The main screen clips what hangs under the mode labels, at any width.
  expect(route(200, 60, 0, THREE_KEYS, CYCLE, false)).toBe('inline')
})

test('a status line width nobody recorded, or mode labels another mod draws over, send the keys inline; a row too narrow for them there, a hint a person reads, or a footer nobody measured, to the band', () => {
  expect(route(200, undefined, 0, THREE_KEYS)).toBe('inline')
  expect(route(200, 60, undefined, THREE_KEYS)).toBe('inline')
  // The widest notice without its hint, the indent and the engine's ` · ` are 29 cells; two stay free.
  expect(route(60, undefined, 0, THREE_KEYS)).toBe('inline')
  expect(route(59, undefined, 0, THREE_KEYS)).toBe('band')
  expect(route(59, 20, 0, THREE_KEYS)).toBe('band')
  expect(route(200, undefined, 0, THREE_KEYS, '1 shell')).toBe('band')
  expect(route(undefined, 60, 0, THREE_KEYS)).toBe('band')
  expect(route(undefined, undefined, 0, THREE_KEYS)).toBe('band')
  // Until the hint's site draws, the hint is taken for the cycle hint.
  expect(route(60, undefined, 0, THREE_KEYS, undefined)).toBe('inline')
  expect(route(80, 60, 0, THREE_KEYS, undefined)).toBe('notice-right')
})

// The hints are the ones Claude Code 2.1.322 handed the hint's site; the
// widths beside the labelled ones are the notices it drew (auto 38, accept
// edits 41, plan 37, bypass permissions 48), never under-counted.
test('the notice is as wide as the hint in it says, the widest where the hint names no label', () => {
  for (const hint of [CYCLE, 'auto mode on (shift+tab to cycle)', 'accept edits on (shift+tab to cycle)', 'plan mode on (shift+tab to cycle)', 'bypass permissions on (shift+tab to cycle)']) expect([hint, isCycleHint(hint)]).toEqual([hint, true])
  for (const hint of ['1 shell', '? for shortcuts', 'manual mode on', '', '(shift+tab to cycle) · 1 shell', '1 shell (shift+tab to cycle)', '2 shells on (shift+tab to cycle)', 'esc to interrupt']) expect([hint, isCycleHint(hint)]).toEqual([hint, false])
  expect(noticeCells(undefined)).toBe(48)
  expect(noticeCells(CYCLE)).toBe(48)
  expect(noticeCells('bypass permissions on (shift+tab to cycle)')).toBe(48)
  expect(noticeCells('accept edits on (shift+tab to cycle)')).toBe(42)
  expect(noticeCells('auto mode on (shift+tab to cycle)')).toBe(39)
  expect(noticeCells('plan mode on (shift+tab to cycle)')).toBe(39)
  // `  ⏵⏵ bypass permissions on · 1 shell` is 37 cells.
  expect(noticeCells('1 shell')).toBe(37)
  expect(noticeCells('')).toBe(30)
})

test('the status line\'s record gives a width only for this conversation and this Claude Code, in the one shape cs-statusline writes', () => {
  expect(STATUS_WIDTH).toBe('.cs/local/statusline-width')
  expect(parseStatusWidth('uuid-lead 82 4242\n', 'uuid-lead', '4242')).toBe(82)
  expect(parseStatusWidth('uuid-lead 0 4242\n', 'uuid-lead', '4242')).toBe(0)
  expect(parseStatusWidth('uuid-old 82 4242\n', 'uuid-lead', '4242')).toBeUndefined()
  // The bar of another Claude Code on this conversation, in a terminal of another width.
  expect(parseStatusWidth('uuid-lead 82 4243\n', 'uuid-lead', '4242')).toBeUndefined()
  // Two of them alive: cs-statusline writes no width.
  expect(parseStatusWidth('uuid-lead - 4242 4243\n', 'uuid-lead', '4242')).toBeUndefined()
  for (const text of ['', '82\n', 'uuid-lead\n', 'uuid-lead 82\n', 'uuid-lead 82 4242 1\n', 'uuid-lead -3 4242\n', 'uuid-lead 8e1 4242\n', 'uuid-lead  82 4242\n', 'uuid-lead 82 4242\nuuid-lead 90 4242\n', 'uuid-lead 12345 4242\n', 'uuid-lead 82 42x2\n']) {
    expect([text, parseStatusWidth(text, 'uuid-lead', '4242')]).toEqual([text, undefined])
  }
})

test('the mode labels are counted as the footer joins them, cs-filter-chat\'s once while it is on whether or not the hook sees it', () => {
  expect(FILTER_CHAT_MODE).toBe(filterChatLabels.mode)
  expect(modesWidth([], false)).toBe(0)
  expect(modesWidth(['focus'], false)).toBe(5)
  expect(modesWidth(['focus', 'memory paused'], false)).toBe(21)
  expect(modesWidth([], true)).toBe(36)
  expect(modesWidth([FILTER_CHAT_MODE], true)).toBe(36)
  expect(modesWidth(['focus'], true)).toBe(44)
})

test('every entry has one site: the rotate, clear, countdown, wrap and filter chat keys under the prompt, the rest on the band', () => {
  const all = buildBandEntries({ ...quiet, featured: { label: '1 feature · fix-auth ready', onPress: noPress }, countdown: { seconds: 18, ink: OWN }, rotating: true, armed: true, wrapping: true, filterChat: { on: true, onPress: noPress }, waiting: 2, gate: 'finishing fix-auth · gate 3s', queued: 2, mail: 1 })
  expect(entriesAt(all, 'footer').map(entry => entry.key)).toEqual(['cs-rotate', 'cs-countdown', 'cs-wrap', 'cs-filter-chat'])
  expect(entriesAt(all, 'band').map(entry => entry.key)).toEqual(['cs-queue', 'cs-features', 'cs-gate', 'cs-queued', 'cs-mail'])
  expect(() => entriesAt([{ key: 'cs-weather', kind: 'word', label: 'sunny' }], 'band')).toThrow('cs: cs-weather has no site')
})

test('the keys\' width is what the row draws: a middle dot between keys, a space before the count', () => {
  expect(keysWidth(entriesAt(buildBandEntries({ ...quiet, rotating: true, wrapping: true, filterChat: { on: false, onPress: noPress } }), 'footer'))).toBe(THREE_KEYS)
  expect(keysWidth(entriesAt(buildBandEntries({ ...quiet, rotating: true, armed: true, countdown: { seconds: 18, ink: OWN } }), 'footer'))).toBe('/clear now in 18s'.length)
  expect(keysWidth([])).toBe(0)
})

// The record is trusted for the pid it names, so a mod that cannot learn its
// own Claude Code's trusts none; the pid is asked for once.
test('the mod asks which Claude Code it runs in from a timer, three times at most, and trusts no record until it knows', async () => {
  files[WIDTH] = 'uuid-lead 57 4242\n'
  percent = 40
  let pidRuns = 0
  const run = $.process.run
  $.process.run = async (argv: string[], init: any) => { if (argv[0] === '/bin/sh') pidRuns++; return run(argv, init) }
  try {
    // A render starts no process: the engine aborts one whose render it supersedes.
    await band()
    expect(pidRuns).toBe(0)
    expect(await footerMode()).toBe(MODES_DRAWN)
    await settleTimers()
    expect(pidRuns).toBe(1)
    expect(sitesWithKeys(await pass())).toEqual(['mode'])
    expect(pidRuns).toBe(1)
    reload()
    claudePid = new Error('spawn EPERM')
    for (let draws = 0; draws < 5; draws++) expect(sitesWithKeys(await pass())).toEqual(['hint'])
    expect(pidRuns).toBe(4)
    // An answer on a later ask is taken.
    reload()
    await band()
    await fireAfter()
    expect(pidRuns).toBe(5)
    claudePid = '4242'
    expect(sitesWithKeys(await pass())).toEqual(['mode'])
    expect(pidRuns).toBe(6)
    expect(runs).toEqual([])
  } finally {
    $.process.run = run
  }
})

const absoluteBoxes = (tree: any) => boxes(tree).filter((b: any) => b.props.position === 'absolute')
test('with room the keys draw at the right end of the notice\'s row from the mode labels\' site, and the hint stays the engine\'s', async () => {
  files[WIDTH] = 'uuid-lead 82 4242\n'
  percent = 40
  expect(await band()).toBe(DRAWN)
  await settleTimers()
  const tree = await footerMode(87)
  // The engine's own labels stay; the keys hang one row down from a box of no width, flush right.
  expect(tree.children[0]).toBe(MODES_DRAWN)
  const [holder] = boxes(tree).filter((b: any) => b.props.width === 0)
  expect(holder.props).toEqual({ width: 0, height: 1 })
  expect(absoluteBoxes(tree).map((b: any) => b.props)).toEqual([{ position: 'absolute', right: 0, top: 1 }])
  expect(buttons(absoluteBoxes(tree)[0]).map((b: any) => [b.props.key, b.props.action])).toEqual([['cs-rotate', 'strip:jump1'], ['cs-wrap', 'strip:jump2']])
  expect(buttonsUnderText(tree)).toBe(0)
  expect(await footerHint(87)).toBe(HINT_DRAWN)
})

test('without room there the keys stand in the hint\'s place, and the mode labels stay the engine\'s', async () => {
  files[WIDTH] = 'uuid-lead 82 4242\n'
  percent = 40
  await band()
  expect(await footerMode(86)).toBe(MODES_DRAWN)
  const tree = await footerHint(86)
  expect(bandWords(tree)).toEqual(['rotate', ' · ', 'wrap'])
  expect(buttonsUnderText(tree)).toBe(0)
  expect(absoluteBoxes(tree)).toEqual([])
})

test('a record of another conversation or another Claude Code, an unreadable one, or none sends the keys inline at any width', async () => {
  percent = 40
  // The mod has learned it runs in Claude Code 4242: its own record takes the keys to the notice's right.
  files[WIDTH] = 'uuid-lead 20 4242\n'
  await band()
  await settleTimers()
  expect(sitesWithKeys(await pass({ columns: 200 }))).toEqual(['mode'])
  for (const record of ['uuid-old 20 4242\n', 'uuid-lead 20 4243\n', 'uuid-lead - 4242 4243\n', 'wide\n', undefined]) {
    if (record === undefined) delete files[WIDTH]
    else files[WIDTH] = record
    expect([record, sitesWithKeys(await pass({ columns: 200 }))]).toEqual([record, ['hint']])
  }
})

test('a footer too narrow for the keys inline draws the engine\'s own at both sites', async () => {
  percent = 40
  await band()
  // `rotate · wrap` is 13 cells: 44 columns hold it after the widest notice, 43 do not.
  expect(buttons(await footerHint(44))).toHaveLength(2)
  expect(await footerHint(43)).toBe(HINT_DRAWN)
  expect(await footerMode(43)).toBe(MODES_DRAWN)
})

test('with no key to show, both footer sites return the engine\'s own', async () => {
  files[WIDTH] = 'uuid-lead 82 4242\n'
  expect(await footerMode()).toBe(MODES_DRAWN)
  expect(await footerHint()).toBe(HINT_DRAWN)
  await band()
  expect(await footerMode()).toBe(MODES_DRAWN)
  expect(await footerHint()).toBe(HINT_DRAWN)
  // Mail and a queue are the band's, and leave the footer alone.
  files['/work/.cs/local/mail/new/one.json'] = '{}'
  queueTasks(2)
  expect(buttons(await band()).map((b: any) => b.props.key)).toEqual(['cs-queue'])
  expect(await footerMode()).toBe(MODES_DRAWN)
  expect(await footerHint()).toBe(HINT_DRAWN)
})

test('keys once drawn leave both sites when a survey takes the band, a turn starts, or the conversation is not the lead\'s', async () => {
  files[WIDTH] = 'uuid-lead 82 4242\n'
  percent = 40
  const drawnAtBoth = async (props: Parameters<typeof band>[0]) => {
    await band(props)
    return [await footerMode(110), await footerHint(86)].map(tree => buttons(tree).length)
  }
  await band()
  await settleTimers()
  expect(await drawnAtBoth({})).toEqual([2, 2])
  expect(await drawnAtBoth({ hasSurvey: true })).toEqual([0, 0])
  expect(await footerMode(110)).toBe(MODES_DRAWN)
  expect(await footerHint(86)).toBe(HINT_DRAWN)
  expect(await drawnAtBoth({})).toEqual([2, 2])
  expect(await drawnAtBoth({ isWorking: true })).toEqual([0, 0])
  expect(await drawnAtBoth({})).toEqual([2, 2])
  sessionId = 'uuid-teammate'
  expect(await drawnAtBoth({})).toEqual([0, 0])
})

test('the keys are dim plain Buttons with dim separators; only the count and the filter chat dot are coloured', async () => {
  enableFilterChat()
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=1\n'
  percent = 40
  let tree = await keys()
  expect(buttons(tree).map((b: any) => [b.props.key, b.props.plain, b.props.dimColor, b.props.hotkey])).toEqual([['cs-rotate', true, true, undefined], ['cs-wrap', true, true, undefined], ['cs-filter-chat', true, true, undefined]])
  expect(texts(tree).filter((t: any) => t.props.color !== undefined).map((t: any) => [textOf(t), t.props.color])).toEqual([['●', GREEN]])
  expect(texts(tree).filter((t: any) => textOf(t) === ' · ').map((t: any) => t.props)).toEqual([{ dimColor: true }, { dimColor: true }])
  expect(buttonsUnderText(tree)).toBe(0)
  await startGrace()
  tree = await keys()
  expect(texts(tree).filter((t: any) => t.props.color !== undefined).map((t: any) => [textOf(t), t.props])).toEqual([[`in ${GRACE_SECONDS}s`, { bold: true, color: OWN }]])
  expect(buttonsUnderText(tree)).toBe(0)
})

test('a click on a key under the prompt does what its key on the band did', async () => {
  files[WIDTH] = 'uuid-lead 82 4242\n'
  percent = 40
  await band()
  await settleTimers()
  await buttons(await footerMode(110)).find((b: any) => b.props.key === 'cs-wrap').props.onPress()
  expect(asks.map(ask => ask.question)).toEqual([WRAP_QUESTION])
  expect(ran).toEqual([{ command: 'wrap', args: '' }])
  await buttons(await footerHint(86)).find((b: any) => b.props.key === 'cs-rotate').props.onPress()
  expect(ran.at(-1)).toEqual({ command: 'rotate', args: '' })
})

test('filter chat on adds its mode label to the status line\'s row, and the keys leave the notice\'s right where the two no longer fit', async () => {
  enableFilterChat()
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=1\n'
  files[WIDTH] = 'uuid-lead 60 4242\n'
  await band()
  await settleTimers()
  // 60 cells, the label's 36 and the margin's 5: the row holds them from 101 columns.
  expect(buttons(await footerMode(101)).map((b: any) => b.props.label)).toEqual(['filter chat ●'])
  expect(await footerHint(101)).toBe(HINT_DRAWN)
  expect(await footerMode(100)).toBe(MODES_DRAWN)
  expect(buttons(await footerHint(100)).map((b: any) => b.props.label)).toEqual(['filter chat ●'])
  // The label is counted once when cs-filter-chat's rewrite reaches this hook.
  expect(buttons(await footerMode(101, [FILTER_CHAT_MODE]))).toHaveLength(1)
  // Off, the row is the status line's alone.
  files['/work/.cs/local/config'] = 'CS_FILTER_CHAT=0\n'
  await band()
  expect(buttons(await footerMode(65)).map((b: any) => b.props.label)).toEqual(['filter chat ○'])
})

test('another mode label the footer shows takes the keys\' route with it, and both sites draw again', async () => {
  files[WIDTH] = 'uuid-lead 60 4242\n'
  percent = 40
  await band()
  await fireAfter()
  invalidated = []
  expect(buttons(await footerMode(80))).toHaveLength(2)
  expect(timers.filter(t => t.kind === 'after' && !t.cancelled)).toEqual([])
  // `memory paused` is 13 cells: with the status line's 60 and the margin's 5 it needs 78 columns.
  expect(buttons(await footerMode(77, ['memory paused']))).toHaveLength(0)
  await fireAfter()
  expect(invalidated).toEqual(['ui.render'])
  expect(buttons(await footerHint(77))).toHaveLength(2)
})

// claude-errands draws its Codex line there, a tree as wide as its sessions' names.
test('a tree another mod draws in the mode labels\' place sends the keys inline, since nothing says how wide it is', async () => {
  files[WIDTH] = 'uuid-lead 60 4242\n'
  percent = 40
  await band()
  await settleTimers()
  expect(buttons(await footerMode(110))).toHaveLength(2)
  const theirs = { type: 'Box', props: { flexDirection: 'row' }, children: [MODES_DRAWN, { type: 'Text', props: {}, children: ['2 Codex sessions'] }] }
  expect(await footerMode(110, [], theirs)).toBe(theirs)
  expect(buttons(await footerHint(110))).toHaveLength(2)
  // The engine's own drawing back, the keys return to the notice's right.
  expect(buttons(await footerMode(110))).toHaveLength(2)
  expect(await footerHint(110)).toBe(HINT_DRAWN)
})

test('a footer that changed is drawn again once, and one that did not is left alone', async () => {
  percent = 40
  await band()
  await band()
  // One redraw for the keys, beside the timer that asks which Claude Code this is.
  expect(timers.filter(t => t.kind === 'after' && !t.cancelled)).toHaveLength(2)
  await settleTimers()
  expect(invalidated).toEqual(['ui.render'])
  await band()
  expect(timers.filter(t => t.kind === 'after' && !t.cancelled)).toEqual([])
  percent = 10
  await band()
  await fireAfter()
  expect(invalidated).toEqual(['ui.render', 'ui.render'])
})

// One pass over the three sites that can draw the keys, each handed what its
// own event says of the screen, and again while any of them asks for a
// redraw: what is on screen once the footer has settled.
type Site = 'band' | 'mode' | 'hint'
type Pass = { columns?: number; fullscreen?: boolean; hint?: string; modes?: string[]; modesDrawn?: unknown; working?: boolean; unmeasured?: Site[] }
const pass = async (o: Pass = {}) => {
  const fullscreen = o.fullscreen ?? true
  const columns = (site: Site) => o.unmeasured?.includes(site) ? null : o.columns ?? 110
  for (let redraws = 0; ; redraws++) {
    const trees = {
      band: await band({ isWorking: o.working ?? false, bodyColumns: o.columns ?? 110 }, 'terminal', viewOf(columns('band'), fullscreen) ?? null),
      mode: await footerMode(columns('mode'), o.modes ?? [], o.modesDrawn ?? MODES_DRAWN, fullscreen),
      hint: await footerHint(columns('hint'), o.hint ?? CYCLE, o.working ?? false, fullscreen),
    }
    if (timers.every(t => t.kind !== 'after' || t.cancelled)) return trees
    if (redraws === 5) throw new Error(`the footer never settled: ${JSON.stringify(o)}`)
    await fireAfter()
  }
}
const KEY_NAMES = ['cs-rotate', 'cs-wrap', 'cs-filter-chat']
const sitesWithKeys = (trees: Record<Site, unknown>) =>
  (Object.keys(trees) as Site[]).filter(site => buttons(trees[site]).some((b: any) => KEY_NAMES.includes(b.props.key)))
// A mod loaded afresh: what the sites learned of an earlier screen is gone.
const reload = () => { for (const k of Object.keys(hooks)) delete hooks[k]; timers = []; register(on as any) }

test('exactly one site draws the keys, whatever each site is told of the screen', async () => {
  percent = 40
  enableFilterChat()
  const drew = new Set<Site>()
  const everySite: Site[] = ['band', 'mode', 'hint']
  const subsets = everySite.reduce<Site[][]>((sets, site) => [...sets, ...sets.map(set => [...set, site])], [[]])
  for (const record of ['uuid-lead 57 4242\n', 'uuid-lead 139 4242\n', undefined]) {
    if (record === undefined) delete files[WIDTH]
    else files[WIDTH] = record
    for (const columns of [40, 59, 60, 83, 84, 110, 180]) for (const fullscreen of [true, false]) for (const hint of [CYCLE, '1 shell', '? for shortcuts', ''])
      for (const modes of [[], ['memory paused']]) for (const unmeasured of subsets) {
        reload()
        const sites = sitesWithKeys(await pass({ columns, fullscreen, hint, modes, unmeasured }))
        if (sites.length !== 1) throw new Error(`${JSON.stringify({ record, columns, fullscreen, hint, modes, unmeasured })} drew the keys at ${JSON.stringify(sites)}`)
        drew.add(sites[0])
      }
  }
  // Each site takes its turn somewhere in the table, so the count above is not one site's alone.
  expect([...drew].sort()).toEqual(['band', 'hint', 'mode'])
})

test('a footer too narrow for the keys, or one nobody measured, draws them on the band above the prompt, their chords spelled', async () => {
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
  percent = 40
  // `rotate · wrap` is 13 cells: 44 columns hold it after the widest notice, 43 do not.
  let trees = await pass({ columns: 44 })
  expect(sitesWithKeys(trees)).toEqual(['hint'])
  expect(trees.band).toBe(DRAWN)
  trees = await pass({ columns: 43 })
  expect(sitesWithKeys(trees)).toEqual(['band'])
  expect(words(trees.band)).toEqual(['ctrl+x', '1', '   ', '2'])
  expect(buttons(trees.band).map((b: any) => [b.props.key, b.props.action])).toEqual([['cs-rotate', 'strip:jump1'], ['cs-wrap', 'strip:jump2']])
  expect(trees.mode).toBe(MODES_DRAWN)
  expect(trees.hint).toBe(HINT_DRAWN)
  reload()
  trees = await pass({ unmeasured: ['band', 'mode', 'hint'] })
  expect(sitesWithKeys(trees)).toEqual(['band'])
  expect(words(trees.band)).toEqual(['ctrl+x', '1', '   ', '2'])
})

// The band's line here is as wide as the footer (the engine's is a few cells
// narrower: 105 of 110): the count holds its place on a line of 23 cells, and
// only a narrower line drops it before the clear key's word.
test('an armed handoff\'s clear key and its count draw on the band where the footer has no room for them', async () => {
  bindKeys({ 'ctrl+x 1': 'strip:jump1', 'ctrl+x 2': 'strip:jump2' })
  await startGrace()
  let trees = await pass({ columns: 40 })
  expect(trees.mode).toBe(MODES_DRAWN)
  expect(trees.hint).toBe(HINT_DRAWN)
  expect(bandWords(trees.band)).toEqual(['ctrl+x', '1', '/clear now', '   ', `in ${GRACE_SECONDS}s`])
  trees = await pass({ columns: 23 })
  expect(sitesWithKeys(trees)).toEqual(['band'])
  expect(bandLine(trees.band, 23)).toBe(`  1 /clear now   in ${GRACE_SECONDS}s`)
  expect(bandLine((await pass({ columns: 22 })).band, 22)).toBe('  ctrl+x 1 /clear now')
})

// Measured on 2.1.322: on the main screen the engine clips what a mod hangs a
// row under the mode labels, and the keys drew nowhere at 110 columns.
test('on the main screen the keys never hang under the mode labels, whatever room the row has', async () => {
  files[WIDTH] = 'uuid-lead 57 4242\n'
  percent = 40
  expect(sitesWithKeys(await pass({ columns: 110 }))).toEqual(['mode'])
  expect(sitesWithKeys(await pass({ columns: 110, fullscreen: false }))).toEqual(['hint'])
  expect(sitesWithKeys(await pass({ columns: 110 }))).toEqual(['mode'])
  // A surface that has not said which layout it draws is not known to be fullscreen.
  const unsaid = { surface: 'terminal', viewport: { columns: 110, rows: 35 }, props: { modes: [] } }
  expect(await hooks['ui.render:SessionMode']($, unsaid, async () => MODES_DRAWN)).toBe(MODES_DRAWN)
  expect(buttons(await footerHint(110))).toEqual([])
  await fireAfter()
  expect(buttons(await footerHint(110, CYCLE, false, false))).toHaveLength(2)
})

// Measured on 2.1.322: the hint is the cycle hint at rest, the mode's label
// before it for a moment after shift+tab, and `1 shell` in its place once a
// background shell runs.
test('the keys stand in the hint\'s place only while the hint is the cycle hint, alone or after a mode\'s label', async () => {
  percent = 40
  for (const hint of [CYCLE, 'auto mode on (shift+tab to cycle)', 'accept edits on (shift+tab to cycle)', 'plan mode on (shift+tab to cycle)', 'bypass permissions on (shift+tab to cycle)']) {
    const trees = await pass({ hint })
    expect([hint, sitesWithKeys(trees)]).toEqual([hint, ['hint']])
    expect(trees.band).toBe(DRAWN)
  }
  for (const hint of ['1 shell', '? for shortcuts', 'manual mode on', '', '(shift+tab to cycle) · 1 shell', '1 shell (shift+tab to cycle)', 'esc to interrupt']) {
    const trees = await pass({ hint })
    expect([hint, sitesWithKeys(trees)]).toEqual([hint, ['band']])
    expect(trees.hint).toBe(HINT_DRAWN)
  }
})

test('at the notice\'s right the keys clear a notice as wide as its hint makes it', async () => {
  files[WIDTH] = 'uuid-lead 40 4242\n'
  percent = 40
  // Before the hint's site has drawn, the widest notice at rest: its 48 cells, the 13 of `rotate · wrap` and 3 between.
  await band({}, 'terminal', viewOf(64))
  await settleTimers()
  expect(buttons(await footerMode(64))).toHaveLength(2)
  reload()
  await band({}, 'terminal', viewOf(63))
  await settleTimers()
  expect(await footerMode(63)).toBe(MODES_DRAWN)
  // The cycle hint, bare or after the widest label, is that same notice.
  for (const hint of [CYCLE, 'bypass permissions on (shift+tab to cycle)']) {
    expect(sitesWithKeys(await pass({ columns: 64, hint }))).toEqual(['mode'])
    expect(sitesWithKeys(await pass({ columns: 63, hint }))).toEqual(['hint'])
  }
  // A shorter label leaves the keys their place on a narrower row: 6 cells of indent and glyph, then the hint's 33.
  expect(sitesWithKeys(await pass({ columns: 55, hint: 'auto mode on (shift+tab to cycle)' }))).toEqual(['mode'])
  expect(sitesWithKeys(await pass({ columns: 54, hint: 'auto mode on (shift+tab to cycle)' }))).toEqual(['hint'])
  // A pill follows a label the hint does not carry: 30 cells for the widest and its ` · `, then the pill's 7.
  expect(sitesWithKeys(await pass({ columns: 53, hint: '1 shell' }))).toEqual(['mode'])
  expect(sitesWithKeys(await pass({ columns: 52, hint: '1 shell' }))).toEqual(['band'])
  const long = '3 shells · 2 local agents · esc to interrupt · ctrl+t to hide tasks'
  expect(sitesWithKeys(await pass({ columns: 30 + long.length + 13 + 3, hint: long }))).toEqual(['mode'])
  expect(sitesWithKeys(await pass({ columns: 30 + long.length + 13 + 2, hint: long }))).toEqual(['band'])
})

test('an evaluation of the band that throws leaves no key under the prompt', async () => {
  files[WIDTH] = 'uuid-lead 57 4242\n'
  percent = 40
  expect(sitesWithKeys(await pass())).toEqual(['mode'])
  const usage = $.session.usage
  $.session.usage = async () => { throw new Error('usage unread') }
  try {
    await expect(band()).rejects.toThrow('usage unread')
  } finally {
    $.session.usage = usage
  }
  await fireAfter()
  expect(invalidated.at(-1)).toBe('ui.render')
  expect(await footerMode()).toBe(MODES_DRAWN)
  expect(await footerHint()).toBe(HINT_DRAWN)
  expect(sitesWithKeys(await pass())).toEqual(['mode'])
})

test('a turn the hint\'s site reports takes the rotate and wrap keys from under the prompt before the band draws again, and leaves filter chat', async () => {
  files[WIDTH] = 'uuid-lead 57 4242\n'
  enableFilterChat()
  percent = 40
  await band()
  await settleTimers()
  expect(buttons(await footerMode()).map((b: any) => b.props.key)).toEqual(['cs-rotate', 'cs-wrap', 'cs-filter-chat'])
  expect(await footerHint(110, CYCLE, true)).toBe(HINT_DRAWN)
  expect(buttons(await footerMode()).map((b: any) => b.props.key)).toEqual(['cs-filter-chat'])
  await fireAfter()
  expect(invalidated.at(-1)).toBe('ui.render')
  expect(await footerHint(110, CYCLE, false)).toBe(HINT_DRAWN)
  expect(buttons(await footerMode()).map((b: any) => b.props.key)).toEqual(['cs-rotate', 'cs-wrap', 'cs-filter-chat'])
})

test('a rotate or wrap key pressed once a turn runs does nothing but say so', async () => {
  percent = 40
  const [rotate, wrap] = buttons(await keys())
  await footerHint(110, CYCLE, true)
  await rotate.props.onPress()
  await wrap.props.onPress()
  expect(ran).toEqual([])
  expect(asks).toEqual([])
  expect(written['/work/.cs/local/cs.pressed']).toBeUndefined()
  expect(toasts).toEqual(['/rotate did not run: a turn is running', '/wrap did not run: a turn is running'])
  expect(toasts).toEqual([TOASTS.midTurn('/rotate'), TOASTS.midTurn('/wrap')])
  await footerHint(110, CYCLE, false)
  await rotate.props.onPress()
  await wrap.props.onPress()
  expect(ran).toEqual([{ command: 'rotate', args: '' }, { command: 'wrap', args: '' }])
})

test('a turn on the main loop runs from its start to its end, before any site draws it and while the band and the hint disagree', async () => {
  percent = 40
  const [rotate] = buttons(await keys())
  await turnStart('go')
  await rotate.props.onPress()
  expect(toasts).toEqual([TOASTS.midTurn('/rotate')])
  await footerHint(110, CYCLE, false)
  await band()
  await turnComplete({ agentId: 'agent-1' })
  await rotate.props.onPress()
  expect(toasts).toEqual([TOASTS.midTurn('/rotate'), TOASTS.midTurn('/rotate')])
  await turnComplete()
  await rotate.props.onPress()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
})

// The band a render behind says idle while the hint says working, after a
// load that heard no turn start: the turn stands at both, and the footer stops
// asking to be drawn again.
const disagree = async () => { for (let draws = 0; draws < 3; draws++) { await footerHint(110, CYCLE, true); await band(); await settleTimers() } }
test('a mod loaded while a turn runs takes the turn from the site that draws it, and its end from the main loop', async () => {
  percent = 40
  await keys()
  reload()
  const [rotate] = buttons(await keys())
  await disagree()
  const settled = invalidated.length
  await disagree()
  expect(invalidated).toHaveLength(settled)
  expect(buttons(await footerHint(110, CYCLE, true))).toEqual([])
  await rotate.props.onPress()
  expect(toasts).toEqual([TOASTS.midTurn('/rotate')])
  await turnComplete()
  await rotate.props.onPress()
  expect(ran).toEqual([{ command: 'rotate', args: '' }])
})

// The press reads the turn as it lands, and again once cs has answered: a
// turn started meanwhile without a prompt (a Stop hook's feedback) bumps no
// press count.
test('a /clear now key pressed once a turn runs, before any site draws the turn, does nothing but say so', async () => {
  await startGrace()
  const clear = findButton(await keys())
  expect(clear.props.label).toBe('/clear now')
  await promptSubmit()
  await turnStart('keep going')
  const asked = runs.length
  await clear.props.onPress()
  expect(ran).toEqual([])
  expect(runs).toHaveLength(asked)
  expect(toasts.filter(t => t.startsWith('/clear'))).toEqual([TOASTS.midTurn('/clear')])
  await turnComplete()
  let answered!: () => void
  const run = $.process.run
  $.process.run = async (argv: string[], init: any) => {
    if (argv[1] !== '-vet-session') return run(argv, init)
    await new Promise<void>(resolve => { answered = resolve })
    return { exitCode: 0, stdout: '', stderr: '' }
  }
  try {
    const pressed = clear.props.onPress()
    await settle()
    await turnStart('')
    answered()
    await pressed
  } finally {
    $.process.run = run
  }
  expect(ran).toEqual([])
  expect(toasts.filter(t => t.startsWith('/clear'))).toEqual([TOASTS.midTurn('/clear'), TOASTS.midTurn('/clear')])
  await turnComplete()
  await clear.props.onPress()
  expect(ran).toEqual([{ command: 'clear', args: '' }])
})

test('a turn a Stop hook starts with no prompt, before the band draws it, keeps the count\'s zero from clearing', async () => {
  await startGrace()
  await keys()
  await tick(GRACE_SECONDS - 1)
  await turnStart('')
  await tick()
  expect(ran).toEqual([])
  expect(ticker()).toBeUndefined()
  expect(toasts).toEqual([TOASTS.midTurn('/clear')])
  // Nor does one that starts while the zero tick waits on cs.
  await turnComplete()
  await keys()
  await tick(GRACE_SECONDS - 1)
  let answered!: () => void
  const run = $.process.run
  $.process.run = async (argv: string[], init: any) => {
    if (argv[1] !== '-vet-session') return run(argv, init)
    await new Promise<void>(resolve => { answered = resolve })
    return { exitCode: 0, stdout: '', stderr: '' }
  }
  try {
    const zero = tick()
    await settle()
    await turnStart('')
    answered()
    await zero
  } finally {
    $.process.run = run
  }
  expect(ran).toEqual([])
  expect(toasts).toEqual([TOASTS.midTurn('/clear'), TOASTS.midTurn('/clear')])
})

const footerClock = () => timers.find(t => t.kind === 'every' && t.ms === FOOTER_POLL_MS && !t.cancelled)
test('the status line\'s width is read on a clock only while it can move the keys, and a line that grows or shrinks moves them on the next read', async () => {
  files[WIDTH] = 'uuid-lead 82 4242\n'
  expect(footerClock()).toBeUndefined()
  percent = 40
  await band()
  await fireAfter()
  invalidated = []
  expect(FOOTER_POLL_MS).toBe(2000)
  expect(timers.filter(t => t.kind === 'every' && t.ms === FOOTER_POLL_MS)).toHaveLength(1)
  expect(buttons(await footerMode(90))).toHaveLength(2)
  await footerClock()!.fn()
  await fireAfter()
  expect(invalidated).toEqual([])
  // A turn ended and the context reading grew a digit.
  files[WIDTH] = 'uuid-lead 86 4242\n'
  await footerClock()!.fn()
  await fireAfter()
  expect(invalidated).toEqual(['ui.render'])
  expect(await footerMode(90)).toBe(MODES_DRAWN)
  expect(buttons(await footerHint(90))).toHaveLength(2)
  // Still one clock: a shorter line would give the keys their place back.
  expect(timers.filter(t => t.kind === 'every' && t.ms === FOOTER_POLL_MS && !t.cancelled)).toHaveLength(1)
  // No status line, however short, hangs the keys under the mode labels on a
  // row too narrow for the notice and the keys, on the main screen, beside a
  // pill, or by another mod's tree: nothing reads the record there.
  const theirs = { type: 'Box', props: {}, children: [MODES_DRAWN] }
  const offTheRight: Pass[] = [{ columns: 63 }, { fullscreen: false }, { columns: 52, hint: '1 shell' }, { modesDrawn: theirs }]
  for (const screen of offTheRight) {
    await pass(screen)
    expect([screen, footerClock()]).toEqual([screen, undefined])
    reads = []
    await pass(screen)
    expect(reads.filter(path => path === WIDTH)).toEqual([])
    // Back on a row with room, the record is read at once and the clock runs again.
    files[WIDTH] = 'uuid-lead 57 4242\n'
    expect(sitesWithKeys(await pass())).toEqual(['mode'])
    expect(footerClock()).toBeDefined()
  }
  percent = 10
  await band()
  expect(footerClock()).toBeUndefined()
})

test('a mod that cannot learn which Claude Code it runs in after three asks reads the width on no clock', async () => {
  files[WIDTH] = 'uuid-lead 57 4242\n'
  claudePid = new Error('spawn EPERM')
  percent = 40
  let pidRuns = 0
  const run = $.process.run
  $.process.run = async (argv: string[], init: any) => { if (argv[0] === '/bin/sh') pidRuns++; return run(argv, init) }
  try {
    for (let draws = 0; draws < 4; draws++) expect(sitesWithKeys(await pass())).toEqual(['hint'])
    expect(pidRuns).toBe(3)
    expect(footerClock()).toBeUndefined()
    expect(sitesWithKeys(await pass())).toEqual(['hint'])
    expect(footerClock()).toBeUndefined()
    expect(pidRuns).toBe(3)
  } finally {
    $.process.run = run
  }
})
