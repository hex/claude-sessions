// ABOUTME: cs-chat-only's decisions: what a user row, a command's answer and the mode line draw while chat only is on in this session, from the row's own props.
// ABOUTME: Pure functions with no $; draw.tsx turns a verdict into a tree. The tool rows and Claude's replies need no decision (register.tsx PAINTERS).
import type { PromptOrigin } from 'claude-code'

import { labels } from './words'

export type UserVerdict =
  | { readonly draw: 'engine' }
  | { readonly draw: 'nothing' }
  | { readonly draw: 'you'; readonly text: string }

/**
 * §8.1 routing by the origin the engine stamped (isExpanded rows never reach
 * here: site() passes them through):
 *
 *   composer, bridge, sdk, scheduled-trigger   your line on the terminal; the engine's elsewhere
 *   task-notification, peer, peer-send-message nothing: a helper's, a task's or another session's message
 *   unclassified                               your line when nobody is named as its sender and it is not
 *                                              a hook's feedback (a channel the engine cannot attest, a
 *                                              message stored before stamps); nothing for a teammate's
 *                                              drain or a hook's feedback
 *   every other kind                           the engine's: its origin is not measured
 *
 * Exhaustive over the contract's kinds: a kind the engine adds fails to
 * compile here instead of drawing as one of the above.
 */
export function decideUser(row: { readonly text: string; readonly origin: PromptOrigin; readonly from?: { readonly name: string } }, surface: string): UserVerdict {
  const yours = (): UserVerdict => surface === 'terminal' ? { draw: 'you', text: row.text } : { draw: 'engine' }
  switch (row.origin.kind) {
    case 'composer': case 'bridge': case 'sdk': case 'scheduled-trigger':
      return yours()
    case 'unclassified':
      return row.from?.name || isHookFeedback(row.text) ? { draw: 'nothing' } : yours()
    case 'task-notification': case 'peer': case 'peer-send-message':
      return { draw: 'nothing' }
    case 'projects-relay': case 'channel': case 'coordinator': case 'observer': case 'observer-activity':
    case 'auto-continuation': case 'slack-ping': case 'plugin':
      return { draw: 'engine' }
  }
}

/** The text a Stop, UserPromptSubmit, PreToolUse or PostToolUse hook fed back, as the engine frames it. */
function isHookFeedback(text: string): boolean {
  return /^(?:Stop hook feedback|UserPromptSubmit|PostToolUse|PreToolUse)[^\n]*:/.test(text)
}

/** CommandOutput §3.3: dim "·" and the text, red on error, a leading "cs-chat-only:" removed; an empty answer draws nothing. */
export function decideCommandOutput(props: { readonly text: string; readonly isErrored: boolean }): 'nothing' | { readonly text: string; readonly isErrored: boolean } {
  const text = props.text.trim().replace(/^cs-chat-only:\s*/, '').trim()
  return text ? { text, isErrored: props.isErrored } : 'nothing'
}

/** SessionMode §3.5: append chat only's mode while it is on in this session. Off, site() passes the row through before any painter runs. */
export function sessionModes(modes: readonly string[]): readonly string[] {
  return [...modes, labels.mode]
}
