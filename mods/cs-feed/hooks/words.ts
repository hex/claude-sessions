// ABOUTME: cs-feed's words: every string the feed draws that is not a setting, from call words and run counts to error lines, peer headlines and report frames.
// ABOUTME: Pure. The strings are the spec's (explore-features §4.6, §6, §8), pinned by tests; the dropped clock strings ("· 19s ·") are not brought back.
import type { FiledCall, Run, Transcript } from './transcript'
import type { CallView } from './verdict'

export type Tense = 'present' | 'past'

export const labels = { you: '❯', backgroundUpdate: 'background task update', reportHint: 'ctrl+o shows the whole report' } as const
export const marks = { dot: '·', live: '●', idle: '○', peer: '⇄', closed: '›', opened: '⌄', question: '?', failed: '✕', working: '◐' } as const
export const braille = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'] as const
export const breathing = ['·', '•', '●', '•'] as const
export const usagePeriods = { fiveHour: '5h', week: 'week' } as const
export const settingsWords = { title: 'Chat view', switch: 'Feed', shortcuts: '· /feed clean · /feed normal · /feed raw · /feed close', show: 'Show', hideHelp: '/feed hide <kind> · /feed show <kind>' } as const
export function settingValue(value: boolean | string): string { return typeof value === 'boolean' ? value ? 'on' : 'off' : value }
export function settingCommand(word: string, value: boolean | string): string { return `/feed ${word} ${settingValue(value)}` }
export function kindChip(kind: string, shown: boolean): string { return `${shown ? marks.live : marks.idle} ${kind}` }

// The lines the feed hands the engine to draw on surfaces of the engine's own:
// its transcript notices (the engine leads each with `cs-feed: `), the
// replies of /feed and /helpers that are not a setting's (settings.ts
// transition holds those) and its slash menu rows.
export const logs = {
  viewUnusable: (path: string, reason: string) => `could not use ${path}: ${reason}; the feed draws its default view until /feed writes the file again`,
  unread: (path: string, reason: string) => `could not read ${path}: ${reason}`,
  feedOff: (refusal: string) => `the feed is off in this session: ${refusal}`,
  clockStopped: (reason: string) => `clock stopped: ${reason}`,
  pulseStopped: (reason: string) => `pulse stopped: ${reason}`,
  helperUnread: (id: string, deny: string) => `could not read helper ${id}'s transcript: ${deny}`,
} as const
export const replies = {
  notASession: 'this directory is not a cs session (no .cs/local), so nothing changed.',
  refused: (refusal: string) => `no feed change in this session: ${refusal}`,
  helpersOpen: 'Helpers open above the prompt.',
} as const
export const commands = {
  feed: { name: 'feed', description: 'Chat view for this session: on, off, clean, normal, raw, or one setting', argumentHint: 'on | off | clean | normal | raw | status | <setting> <value>', immediate: true },
  helpers: { name: 'helpers', description: "Show each helper's own work, call by call", immediate: true },
} as const

export function moreKinds(count: number): string { return `+${count} more ${count === 1 ? 'kind' : 'kinds'}` }

export function helperCounts(states: readonly import('./verdict').HelperState[], durationMs?: number): string {
  const done = states.filter(state => state === 'finished').length
  const running = states.filter(state => state === 'running' || state === 'dispatched').length
  const failed = states.filter(state => state === 'failed' || state === 'stopped').length
  return joined([`${states.length} ${states.length === 1 ? 'helper' : 'helpers'}`, done ? `${done} done` : undefined, running ? `${running} running` : undefined, failed ? `${failed} failed` : undefined, durationMs === undefined ? undefined : elapsed(durationMs)])
}

export function helperFraction(done: number, count: number, failed = 0): string {
  return joined([`${done}/${count}`, failed ? `${failed} failed` : undefined])
}

export function backgroundLine(words: string, isTest: boolean, more: number): string {
  const label = /[|;&><`$\/]|^(?:cd|bash|python|node|npm|git|pgrep)\b/.test(words) ? 'Running a shell command' : words
  return joined([isTest ? 'Test running' : 'Running in the background', label, more ? `+${more} more` : undefined])
}

export function backgroundTail(durationMs: number | undefined, typing: boolean): string {
  const tail = joined([durationMs === undefined ? undefined : elapsed(durationMs), typing ? 'you can keep typing' : undefined])
  return tail ? `${marks.dot} ${tail}` : ''
}

export function usageLabel(percent: number, period: '5h' | 'week'): string {
  return joined([`${Math.round(percent)}%`, period])
}

export function pillLabel(pill: import('./verdict').Pill): string {
  return joined([pill.kind === 'helper' ? 'Helper' : pill.kind === 'test' ? '⚗ Test' : 'Job', pill.words, pill.elapsedMs === undefined ? undefined : elapsed(pill.elapsedMs)])
}

/** The Helpers pane's words (§7.4). */
export const helpersPaneWords = { none: 'No helper ran in this session.', now: 'now:' } as const

/** §7.4 head: "{name} · working · {elapsed}" while running, else "{name} · {status} · {elapsed}"; no time when none is known. */
export function helperPaneHead(name: string, status: 'working' | 'finished' | 'failed' | 'stopped', durationMs?: number): string {
  return joined([name, status, durationMs === undefined ? undefined : elapsed(durationMs)])
}

export function helperNowLine(step: string): string {
  return `${helpersPaneWords.now} ${step}`
}

/** §3.1: a message that starts with a slash command: its name, then its arguments (empty when it has none). */
export function slashCommand(text: string): { readonly name: string; readonly args: string } | undefined {
  const match = /^(\/[A-Za-z0-9][\w:.-]*)(?:\s+([\s\S]*))?$/.exec(text.trim())
  return match?.[1] ? { name: match[1], args: (match[2] ?? '').trim() } : undefined
}

export function joined(parts: readonly (string | undefined)[]): string {
  return parts.filter(part => part !== undefined && part !== '').join(' · ')
}

export function peerLine(sender: string, headline: string): string {
  return `${marks.peer} ${joined([sender, headline])}`
}

export function hookNotice(line: string): string {
  return `${marks.idle} ${line}`
}

export function burstLine(members: readonly { sender: string; at?: number }[]): string {
  const last = members.at(-1)?.at
  return `${marks.peer} ${joined([`${members.length} messages`, [...new Set(members.map(member => member.sender))].join(', '), last === undefined ? undefined : `last ${hhmm(last)}`])}`
}

export function helperNoteLine(headline: string, durationMs?: number): string {
  return `${marks.peer} ${joined(['helper', durationMs === undefined ? undefined : elapsed(durationMs), headline])}`
}

/** A dispatched helper's call is in flight while the helper works, so it reads `running` too. */
export function helperLine(call: CallView, state: import('./verdict').HelperState, durationMs?: number): string {
  const working = state === 'running' || state === 'dispatched'
  return joined([callWords(call, working ? 'present' : 'past'), working ? 'running' : state, durationMs === undefined ? undefined : elapsed(durationMs)])
}

export function outputLines(output: unknown): readonly string[] {
  const text = typeof output === 'string' ? output : output && typeof output === 'object' && !Array.isArray(output)
    ? ['stdout', 'stderr'].flatMap(key => { const value = (output as Record<string, unknown>)[key]; return typeof value === 'string' ? [value] : [] }).join('\n') : ''
  return text.split('\n').filter((line, index, rows) => line !== '' || index < rows.length - 1).slice(0, 12)
}

export function questionLines(call: CallView, filed?: FiledCall): readonly string[] {
  if (filed?.outcome.state === 'done' && filed.outcome.answers?.length) return filed.outcome.answers.map(pair => `${marks.question} ${pair.question} → ${pair.answer}`)
  const questions = Array.isArray(call.input.questions) ? call.input.questions.flatMap(question => {
    if (!question || typeof question !== 'object' || !('question' in question) || typeof question.question !== 'string') return []
    return [question.question.split(/(?<=[?.!])\s/)[0] ?? question.question]
  }) : []
  return [...questions.map(question => `Asked you: ${question}`), ...(call.isRunning ? [] : ['No answer'])]
}

export function frameHead(frame: Frame & { from: string }): string {
  return `${marks.peer} ${joined([frame.from, frame.state, frame.at === undefined ? undefined : hhmm(frame.at), frame.summary, frame.relays ? 'relays content written by others' : undefined])}`
}

/** One line under a report frame's header (§8.3 (a)): a verdict card's parts, the lead or its sentence as Markdown, and the dim hints. */
export type FrameLine =
  | { readonly kind: 'markdown'; readonly text: string }
  | { readonly kind: 'status'; readonly tone: Card['tone']; readonly glyph: string; readonly status: string; readonly sub?: string }
  | { readonly kind: 'text'; readonly text: string }
  | { readonly kind: 'score'; readonly label: string; readonly dots: readonly Card['tone'][]; readonly tally: string }
  | { readonly kind: 'list'; readonly label: string; readonly count: string; readonly first: string }
  | { readonly kind: 'hint'; readonly text: string }

/**
 * §8.3 (a): a verdict card (status chip "✓"/"✕"/"●" by tone, "target …", a
 * score line per judged list with up to 24 dots and "{P} of {M} pass", a line
 * per plain list, "report {file}", the dim footer), with the sentence before
 * its JSON drawn as Markdown above it; or the lead drawn as Markdown, then
 * "+N more line(s) · ctrl+o shows all" when lines were left out.
 */
export function frameBody(frame: Frame): readonly FrameLine[] {
  const lead = frame.lead
  if (!lead) return []
  const card = lead.card
  if (!card) return [
    ...(lead.text ? [{ kind: 'markdown' as const, text: lead.text }] : []),
    ...(lead.more ? [{ kind: 'hint' as const, text: `+${lead.more} more ${lead.more === 1 ? 'line' : 'lines'} · ctrl+o shows all` }] : []),
  ]
  const lines: FrameLine[] = []
  if (lead.sentence) lines.push({ kind: 'markdown', text: lead.sentence })
  if (card.status || card.sub) lines.push({ kind: 'status', tone: card.tone, glyph: card.tone === 'ok' ? '✓' : card.tone === 'bad' ? marks.failed : marks.live, status: card.status, sub: card.sub })
  if (card.target) lines.push({ kind: 'text', text: `target ${card.target}` })
  for (const score of card.scores) lines.push({ kind: 'score', label: score.label, dots: score.dots, tally: `${score.pass} of ${score.of} pass` })
  for (const list of card.lists) lines.push({ kind: 'list', label: list.label, count: String(list.count), first: `${marks.dot} ${list.first}` })
  if (card.report) lines.push({ kind: 'text', text: `report ${card.report}` })
  lines.push({ kind: 'hint', text: labels.reportHint })
  return lines
}

/** §4.6 call words: a cleaned description of 3+ characters, else by tool ("Reading app.py", "Opened example.com"). */
export function callWords(call: Pick<CallView, 'tool' | 'input'>, tense: Tense): string {
  const description = typeof call.input.description === 'string' ? clean(call.input.description) : ''
  if (description.length >= 3) return description
  const past = tense === 'past'
  const path = call.input.file_path ?? call.input.notebook_path
  const file = typeof path === 'string' ? basename(path) : ''
  const skill = typeof call.input.skill === 'string' ? clean(call.input.skill) : ''
  const host = typeof call.input.url === 'string' ? hostname(call.input.url) : undefined
  switch (call.tool) {
    case 'Bash': case 'PowerShell': return past ? 'Ran a shell command' : 'Running a shell command'
    case 'Read': return `${past ? 'Read' : 'Reading'} ${file || 'a file'}`
    case 'Edit': case 'MultiEdit': case 'Write': case 'NotebookEdit': return `${past ? 'Edited' : 'Editing'} ${file || 'a file'}`
    case 'Grep': case 'Glob': return past ? 'Searched the code' : 'Searching the code'
    case 'WebSearch': return past ? 'Searched the web' : `Searching the web${typeof call.input.query === 'string' && call.input.query ? ` for ${clean(call.input.query)}` : ''}`
    case 'WebFetch': return `${past ? 'Opened' : 'Opening'} ${host || 'a web page'}`
    case 'Skill': return `${past ? 'Loaded' : 'Loading'} ${skill ? `the ${skill} skill` : 'a skill'}`
    case 'Agent': case 'Task': return past ? 'Asked a helper' : 'Asking a helper'
    case 'AskUserQuestion': return past ? 'Used AskUserQuestion' : 'Asking you a question'
    case 'TodoWrite': return past ? 'Updated the todo list' : 'Updating the todo list'
    default: return `${past ? 'Used' : 'Using'} ${toolName(call.tool)}`
  }
}

/** §4.6 cleaning: first non-empty line, no NAME=value, paths to base names, no UUIDs, hex runs or long digit tokens. */
export function clean(text: string): string {
  return (text.split('\n').find(line => line.trim()) ?? '')
    .replace(/\b[A-Za-z_][A-Za-z_0-9]*=(?:"[^"]*"|'[^']*'|\S+)/g, '')
    .replace(/(?:~\/|\.\.?\/|\/)[^\s,;]+/g, path => basename(path))
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, '')
    .replace(/\b[0-9a-f]{12,}\b/gi, '')
    .replace(/\S{20,}/g, token => /\d/.test(token) ? '' : token)
    .replace(/\s+/g, ' ').replace(/\s+([.,;:!?])/g, '$1').trim()
}

function basename(path: string): string {
  return path.replace(/\/+$/, '').split(/[\\/]/).at(-1) ?? ''
}

function hostname(value: string): string | undefined {
  try {
    const url = new URL(value)
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.hostname.replace(/^www\./, '') : undefined
  } catch {
    return undefined
  }
}

/** "mcp__claude_ai_Slack__send" -> "Slack send"; a built-in keeps its name. */
export function toolName(tool: string): string {
  return tool.startsWith('mcp__') ? tool.slice(5).replace(/^claude_ai_/, '').replace(/_+/g, ' ') : tool
}

/** §4.6 run words: the naming call's present words, "N steps refused by a hook", one call's words, or the counts ("Ran 2 shell commands · read 1 file"). */
export function runWords(run: Run, t: Transcript, naming?: string): string {
  if (naming) return naming
  const calls = run.calls.flatMap(id => { const call = t.calls.get(id); return call ? [call] : [] })
  const ran = calls.filter(call => call.outcome.state !== 'done' || !call.outcome.refused)
  if (calls.length && !ran.length) return refusedWords(calls.length)
  const first = calls[0]
  if (calls.length === 1 && first) return callWords(first, first.outcome.state === 'running' ? 'present' : 'past')
  const counts = new Map<string, number>()
  for (const call of ran) {
    const kind = call.tool === 'Bash' || call.tool === 'PowerShell' ? 'shell' : ['Edit', 'MultiEdit', 'Write', 'NotebookEdit'].includes(call.tool) ? 'Edit' : call.tool === 'Glob' ? 'Grep' : call.tool === 'Task' ? 'Agent' : call.tool
    counts.set(kind, (counts.get(kind) ?? 0) + 1)
  }
  const text = [...counts].sort(([a, n], [b, m]) => m - n || (a < b ? -1 : a > b ? 1 : 0)).map(([kind, n]) => countWords(kind, n)).join(' · ')
  return text.charAt(0).toUpperCase() + text.slice(1)
}

function refusedWords(n: number): string {
  return `${n} ${n === 1 ? 'step' : 'steps'} refused by a hook`
}

function countWords(kind: string, n: number): string {
  const noun = (word: string) => `${n} ${word}${n === 1 ? '' : 's'}`
  const times = n === 1 ? 'once' : `${n} times`
  switch (kind) {
    case 'shell': return `ran ${noun('shell command')}`
    case 'Read': return `read ${noun('file')}`
    case 'Edit': return `made ${noun('edit')}`
    case 'Grep': return `searched the code ${times}`
    case 'Skill': return `loaded ${noun('skill')}`
    case 'WebSearch': return `searched the web ${times}`
    case 'WebFetch': return `opened ${noun('web page')}`
    case 'Agent': return `asked ${noun('helper')}`
    default: return `used ${toolName(kind)} ${times}`
  }
}

/** §4.6 chips after " · ": refused, "N failed", "+1 line" or "+N lines" (ruling §20.10). */
export function runChips(run: Run, t: Transcript): readonly string[] {
  const outcomes = run.calls.flatMap(id => { const outcome = t.calls.get(id)?.outcome; return outcome?.state === 'done' ? [outcome] : [] })
  const refused = outcomes.filter(outcome => outcome.refused).length
  const failed = outcomes.filter(outcome => outcome.errored && !outcome.refused).length
  const lines = outcomes.reduce((n, outcome) => n + outcome.lines, 0)
  return [...(refused && refused < run.calls.length ? [refusedWords(refused)] : []), ...(failed ? [`${failed} failed`] : []), ...lineChip(lines)]
}
export function callChips(call: CallView, filed?: FiledCall): readonly string[] {
  if (call.isRunning) return []
  const outcome = filed?.outcome
  const text = typeof call.output === 'string' ? call.output : ''
  const refused = call.isErrored && (isRefusal(text) || (outcome?.state === 'done' && outcome.refused))
  const lines = outcome?.state === 'done' ? outcome.lines : text.trim() ? text.trimEnd().split('\n').length : 0
  return [...(refused ? [refusedWords(1)] : call.isErrored ? ['1 failed'] : []), ...lineChip(lines)]
}

function lineChip(lines: number): readonly string[] {
  return lines ? [`+${lines} ${lines === 1 ? 'line' : 'lines'}`] : []
}

/** "· 1 step" / "· {n} steps": the work under a reply, folded. */
export function stepsLine(done: number): string {
  return `${marks.dot} ${done} ${done === 1 ? 'step' : 'steps'}`
}

/** §4.6 fit: cut to room-1 (at least 4) at a space in the second half, trim separators, add "…". */
export function fit(text: string, room: number): string {
  if (text.length <= room) return text
  const width = Math.max(4, room - 1)
  const space = text.lastIndexOf(' ', width)
  return text.slice(0, space > width / 2 ? space : width).replace(/[\s·,;:|\-]+$/, '') + '…'
}

/** "8s", "1m 12s", "1h 3m"; floors at 0. */
export function elapsed(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000))
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`
  return `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`
}

/** Local 24-hour "09:07". One formatter (the fork had two). */
export function hhmm(at: number): string {
  const date = new Date(at)
  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
}

/** §4.7b: errored text that reads as a PreToolUse/PermissionRequest hook's refusal. */
export function isRefusal(text: string): boolean {
  return /(?:PreToolUse|PermissionRequest)(?::\S+)?\s+hook\s+(?:error|blocked|denied)|blocked by a hook|hook[^\n]*denied/i.test(text)
}

export type Tone = 'violet' | 'red' | 'amber'
export type ErrorLine = { readonly head: string; readonly rest: readonly string[]; readonly tone: Tone; readonly act: boolean }

/**
 * §6 rules 1-12, first match wins. Ruling §20.6: rules 1 and 2 (safeguards)
 * need an error prefix or a whole one-line reply; multiline quoted prose stays a reply.
 */
export function errorLine(text: string): ErrorLine | undefined {
  const prefixed = /^(?:API Error|Error:|Request timed out|Connection error|Claude AI usage limit|Credit balance|Invalid API key|Please run \/login|Prompt is too long)/i.test(text)
  if (!prefixed && text.includes('\n')) return undefined
  const content = text.replace(/^(?:API Error|Error):?\s*/i, '')
  const who = content.match(/^(.{1,40})['’]s safeguards/i)?.[1]
  const line = (head: string, rest: readonly string[], tone: Tone, act = tone === 'red'): ErrorLine => ({ head, rest, tone, act })
  if (who && /stopped the response above|continuing/i.test(content)) return line(`${who}'s safeguards cut the reply above`, ['Claude continues', 'esc esc goes back to an earlier message'], 'violet')
  if (/stopped by a safety classifier/i.test(content)) return line('A safeguard cut the reply above', ['Claude continues', 'esc esc goes back to an earlier message'], 'violet')
  if (!prefixed) return undefined
  if (/safeguards|usage policy|\/legal\/aup/i.test(content)) return line(`${who ?? 'The model'}'s safeguards stopped this reply`, ['often a false alarm', 'esc esc to edit your message, or /model to switch'], 'violet', true)
  if (/529|overloaded/i.test(content)) return line("Claude's servers are busy", ['not your setup', 'Claude Code retries, or send again'], 'amber')
  if (/usage limit|rate limit|429/i.test(content)) {
    const reset = content.match(/resets?\s+([^\n,;]+)/i)?.[1]?.trim()
    return line('Usage limit reached', [...(reset ? [`resets ${reset}`] : []), 'nothing is lost', '/model to switch'], 'red')
  }
  if (/prompt is too long|context length|too many tokens/i.test(content)) return line('This chat is too long for the model', ['run /compact', 'nothing is lost'], 'red')
  if (/401|403|authentication|login|api key|oauth/i.test(content)) return line('Login needed', ['run /login', 'nothing is lost'], 'red')
  if (/credit|billing/i.test(content)) return line('Billing problem on the account', ['nothing is lost'], 'red')
  if (/connection|network|socket|timeout|timed out/i.test(content)) return line('Connection lost', ['check your internet', 'send again to retry'], 'amber')
  if (/\b5\d\d\b|server_error|internal/i.test(content)) return line("Server error on Claude's side", ['your work is kept', 'send a message to try again'], 'amber')
  if (/400|invalid_request|max_output/i.test(content)) return line('Claude refused this request', ['ctrl+o shows why', 'esc esc to edit your message'], 'red')
  return line('Claude Code hit an error', ['ctrl+o shows it'], 'amber')
}

/** §8.2 headline: first non-empty line, tags removed, paths shrunk, a status object read as words, fit. */
export function peerHeadline(text: string, room: number): string {
  const first = text.split('\n').find(line => line.trim()) ?? ''
  const status = jsonObject(first)
  const words = status ? [stateWords(status.type), string(status.summary) ?? string(status.message) ?? string(status.status)].filter(Boolean).join(' · ') : first.replace(/<[^>]*>/g, '')
  return fit(words.replace(/(?:\/(?:Users|home|private|tmp|var|opt|Volumes)\/|~\/)[^\s,;]+/g, basename).replace(/\s+/g, ' ').trim(), room)
}

/** §8.2 sender from the envelope's from, teammate_id or name, cleaned; else "another session". */
export function senderOf(from: unknown, raw?: string): string {
  const name = string(from) ?? (record(from) ? string(from.name) : undefined) ?? attribute(raw ?? '', 'from') ?? attribute(raw ?? '', 'teammate_id') ?? attribute(raw ?? '', 'name')
  return (name ? clean(name) : '') || 'another session'
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function string(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value : undefined
}

function jsonObject(text: string): Record<string, unknown> | undefined {
  try {
    const value: unknown = JSON.parse(text)
    return record(value) ? value : undefined
  } catch {
    return undefined
  }
}

function attribute(raw: string, name: 'from' | 'teammate_id' | 'name' | 'summary'): string | undefined {
  return new RegExp(`\\b${name}\\s*=\\s*["']([^"']*)["']`).exec(raw)?.[1]
}

function stateWords(value: unknown): string | undefined {
  const state = string(value)?.replace(/_notification$/, '').replace(/_/g, ' ')
  return state === 'idle' ? 'waiting' : state
}

export type Card = {
  readonly tone: 'ok' | 'bad' | 'mid'
  readonly status: string
  readonly sub?: string
  readonly target?: string
  readonly scores: readonly { label: string; dots: readonly ('ok' | 'bad' | 'mid')[]; pass: number; of: number }[]
  readonly lists: readonly { label: string; count: number; first: string }[]
  readonly report?: string
}
export type Frame = {
  readonly from?: string
  readonly state?: string // "_notification" stripped, underscores as spaces, idle -> "waiting"
  readonly at?: number
  readonly summary?: string
  readonly relays: boolean
  readonly lead?: { readonly sentence?: string; readonly card?: Card; readonly text?: string; readonly more: number }
}

/** §8.3 source 1: teammate-message envelopes in a raw user row (session.append), parsed once by uuid. */
export function parseEnvelopes(raw: string): readonly Frame[] {
  return [...raw.matchAll(/<teammate-message\b([^>]*)>([\s\S]*?)<\/teammate-message>/g)].flatMap(match => {
    const attributes = match[1]
    const body = match[2]
    return attributes !== undefined && body !== undefined ? [frame(body, attribute(attributes, 'from') ?? attribute(attributes, 'teammate_id'), attribute(attributes, 'summary'))] : []
  })
}
/** §8.3 source 2: frames read from a row's own text (a row stored before this load). */
export function framesFromText(text: string): readonly Frame[] {
  if (!text.split('\n').some(line => statusObject(line) !== undefined)) return []
  const frames: Frame[] = []
  let plain: string[] = []
  const flush = () => {
    const body = plain.join('\n').trim()
    if (body) frames.push(frame(body, undefined, body.split('\n')[0]))
    plain = []
  }
  for (const line of text.split('\n')) {
    const status = statusObject(line)
    if (status) {
      flush()
      frames.push(frame(line))
    } else plain.push(line)
  }
  flush()
  return frames
}

function statusObject(line: string): Record<string, unknown> | undefined {
  const value = jsonObject(line.trim())
  return value && [value.type, value.status, value.verdict, value.result].some(value => string(value)) ? value : undefined
}

function frame(body: string, from?: string, summary?: string): Frame {
  let relays = false
  const text = body.split('\n').filter(line => {
    const marker = /^\s*<[^>]+\/>\s*$/.test(line) || /This agent read .*written by people other than you/.test(line)
    relays ||= marker
    return !marker
  }).join('\n').trim()
  const whole = jsonObject(text)
  const rawTime = whole?.timestamp
  const at = typeof rawTime === 'number' ? rawTime : typeof rawTime === 'string' && Number.isFinite(Date.parse(rawTime)) ? Date.parse(rawTime) : undefined
  const lead = reportLead(text)
  const name = from ?? string(whole?.from) ?? string(whole?.teammate_id)
  return { from: name ? clean(name) || undefined : undefined, state: stateWords(whole?.type), at, summary: summary ?? string(whole?.summary), relays, lead: whole?.type && !lead?.card ? undefined : lead }
}

function reportLead(text: string): Frame['lead'] {
  if (!text) return undefined
  if (text.startsWith('[')) {
    try {
      const value: unknown = JSON.parse(text)
      if (Array.isArray(value)) return { text: `${value.length} items`, more: 0 }
    } catch {
      return { text: 'a structured report', more: 0 }
    }
  }
  const opening = text.indexOf('{')
  const object = opening >= 0 ? jsonObject(text.slice(opening)) : undefined
  const sentence = opening > 0 ? text.slice(0, opening).trim() : undefined
  const card = object ? reportCard(object, sentence) : undefined
  if (card) return { ...(sentence ? { sentence } : {}), card, more: 0 }
  if (opening === 0) return { text: 'a structured report', more: 0 }
  const remaining = sentence ?? text
  const paragraph = remaining.split(/\n\s*\n/)[0] ?? ''
  const lead = paragraph.split('\n').slice(0, 6).join('\n').slice(0, 600)
  return { text: lead, more: Math.max(0, remaining.split('\n').filter(line => line.trim()).length - lead.split('\n').filter(line => line.trim()).length) }
}

function reportTone(value: unknown): Card['tone'] {
  const word = string(value)?.toLowerCase() ?? ''
  if (/^(?:done|pass|passed|ok|success|succeeded|green|complete|completed|confirms?)$/.test(word)) return 'ok'
  if (/^(?:fail|failed|error|blocked|red|contradicts|refused)$/.test(word)) return 'bad'
  return 'mid'
}

function reportCard(object: Record<string, unknown>, sentence?: string): Card | undefined {
  const status = string(object.status) ?? string(object.verdict) ?? string(object.result)
  const entries = Object.entries(object)
  const target = Object.values(object).find(value => record(value) && (string(value.name) || string(value.title) || string(value.id)))
  const arrays = entries.filter((entry): entry is [string, unknown[]] => Array.isArray(entry[1]))
  const report = entries.find(([key, value]) => typeof value === 'string' && (/(?:_file|_path|report|dossier)$/.test(key) || /^\//.test(value)))?.[1]
  if (!status && !target && !arrays.length && !report) return undefined
  const scores: Card['scores'][number][] = []
  const lists: Card['lists'][number][] = []
  for (const [label, items] of arrays) {
    const tones = items.map(item => record(item) ? reportTone(item.verdict ?? item.status ?? item.result) : 'mid')
    if (tones.some(tone => tone !== 'mid')) scores.push({ label, dots: tones.slice(0, 24), pass: tones.filter(tone => tone === 'ok').length, of: items.length })
    else {
      const first = items[0]
      const words = string(first) ?? (record(first) ? string(first.name) ?? string(first.title) ?? string(first.description) : undefined) ?? (first === undefined ? '' : JSON.stringify(first))
      lists.push({ label, count: items.length, first: words })
    }
  }
  const targetWords = record(target) ? [string(target.name) ?? string(target.title) ?? string(target.id), string(target.model), string(target.profile), typeof target.temperature === 'number' ? `temp ${target.temperature}` : undefined].filter(Boolean).join(' · ') : undefined
  return { tone: reportTone(status), status: (status ?? '').replace(/[_-]/g, ' ').slice(0, 40), sub: string(object.review_status) ?? string(object.summary) ?? string(object.message) ?? (object.result !== status ? string(object.result) : undefined) ?? (!status && sentence && sentence.length > 8 ? sentence : undefined), target: targetWords, scores, lists, report: typeof report === 'string' ? basename(report) : undefined }
}

/** §9.1 test words: test, tests, suite, spec, specs, e2e, verify, check. */
export function looksLikeTest(words: string): boolean {
  return /\b(?:tests?|suite|specs?|e2e|verify|check)\b/i.test(words)
}

/** §8.1 #3: text whose first line starts with a hook name and reaches a colon; the quiet line it draws. */
export function hookTextLine(text: string): string | undefined {
  if (!/^(?:Stop hook feedback|UserPromptSubmit|PostToolUse|PreToolUse)[^\n]*:/.test(text)) return undefined
  return (text.split('\n').map(line => line.trim()).find(line => line && !/(?:feedback|context):$/.test(line) && !/^(?:Stop hook|UserPromptSubmit)/.test(line)) ?? 'hook feedback').slice(0, 110)
}

/**
 * Whether a reply may carry its turn's steps line (§4.4), from the reply's
 * whole stored text alone (finding 6). False when the text holds a mermaid
 * fence with a non-blank body: cs-mermaid, when it is the outer hook, calls next once per prose part
 * and not at all for a diagram-only reply (mods/cs-mermaid/hooks/register.tsx
 * 195-197), so no single drawing of ours would own the line. A function of
 * the text, not of what this load saw drawn, so the tool row and the reply row
 * decide the same in either plugin order.
 *
 * The fence scan is cs-mermaid's rule (`scanFences`: a ```mermaid line, outer
 * ```` or ~~~ blocks quote it), duplicated: plugins do not import each other,
 * and the test kit refuses an import from another plugin's folder. cs-mermaid
 * draws the reply only when a closed fence has a non-blank body (`fencesOf`
 * drops blank ones), so a blank fence leaves the line to the reply. A test pins
 * the answers cs-mermaid's own fence fixtures give, and blank fences.
 */
export function repliesOwnSteps(text: string): boolean {
  let outer: string | undefined
  let mermaid: { body: boolean } | undefined
  for (const line of text.split('\n')) {
    const trimmed = line.trim()
    if (mermaid) {
      if (trimmed === '```') {
        if (mermaid.body) return false
        mermaid = undefined
      } else if (trimmed) mermaid.body = true
      continue
    }
    const mark = /^(`{3,}|~{3,})/.exec(trimmed)?.[1]
    if (!mark) continue
    if (outer) {
      if (mark[0] === outer[0] && mark.length >= outer.length && trimmed === mark) outer = undefined
    } else if (mark === '```' && trimmed.slice(3).trim() === 'mermaid') mermaid = { body: false }
    else if (mark.length > 3 || mark.startsWith('~')) outer = mark
  }
  return true
}
