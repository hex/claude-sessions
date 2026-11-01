// ABOUTME: cs-clean-chat's words: every string the engine shows for the mod, from the /clean-chat replies and log lines to the error lines that take a failed reply's place.
// ABOUTME: Pure. The error strings are the spec's (explore-features §6), pinned by tests.
import type { CleanChatProblem } from './settings'

export const labels = { you: '❯', mode: 'clean chat · /clean-chat to switch' } as const
export const marks = { dot: '·' } as const

// The lines clean chat hands the engine to draw on surfaces of the engine's
// own: its transcript notices (the engine leads each with `cs-clean-chat: `),
// the replies of /clean-chat and its slash menu row.
export const logs = {
  unread: (path: string, reason: string) => `could not read ${path}: ${reason}`,
  unusable: (path: string, problem: CleanChatProblem, text: string) => `could not use ${path}: ${problem === 'torn' ? 'it is torn, with no closing newline' : `it holds ${JSON.stringify(text.slice(0, 40))}, neither on nor off`}; clean chat is off until /clean-chat or the band's clean chat key writes the file again`,
  cleanChatOff: (refusal: string) => `clean chat is off in this session: ${refusal}`,
  themeUnread: (reason: string) => `could not read the theme: ${reason}; clean chat draws in its dark-theme colours`,
} as const
export const replies = {
  notASession: 'this directory is not a cs session (no .cs/local), so nothing changed.',
  refused: (refusal: string) => `no clean chat change in this session: ${refusal}`,
  status: (on: boolean) => on ? 'on' : 'off',
  switched: (on: boolean) => on ? "clean chat on: your messages and Claude's replies only" : "clean chat off: Claude Code's own drawing",
  usage: '/clean-chat toggles clean chat · /clean-chat on | off | status',
} as const
export const commands = {
  cleanChat: { name: 'clean-chat', description: "Show only your messages and Claude's replies in this session: toggle, on, off or status", argumentHint: 'on | off | status', immediate: true },
} as const

/** §3.1: a message that starts with a slash command: its name, then its arguments (empty when it has none). */
export function slashCommand(text: string): { readonly name: string; readonly args: string } | undefined {
  const match = /^(\/[A-Za-z0-9][\w:.-]*)(?:\s+([\s\S]*))?$/.exec(text.trim())
  return match?.[1] ? { name: match[1], args: (match[2] ?? '').trim() } : undefined
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
