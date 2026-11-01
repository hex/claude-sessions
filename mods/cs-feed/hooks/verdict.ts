// ABOUTME: cs-feed's decisions: what a user row, a command's answer and the mode line draw while this session's feed is on, from the row's own props.
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
 *   unclassified                               nothing: the engine names no provenance (a teammate's
 *                                              drain, an idle notice, a delivery receipt), so it is never
 *                                              presumed typed
 *   every other kind                           the engine's: its origin is not measured
 *
 * Exhaustive over the contract's kinds: a kind the engine adds fails to
 * compile here instead of drawing as one of the above.
 */
export function decideUser(row: { readonly text: string; readonly origin: PromptOrigin }, surface: string): UserVerdict {
  switch (row.origin.kind) {
    case 'composer': case 'bridge': case 'sdk': case 'scheduled-trigger':
      return surface === 'terminal' ? { draw: 'you', text: row.text } : { draw: 'engine' }
    case 'task-notification': case 'peer': case 'peer-send-message': case 'unclassified':
      return { draw: 'nothing' }
    case 'projects-relay': case 'channel': case 'coordinator': case 'observer': case 'observer-activity':
    case 'auto-continuation': case 'slack-ping': case 'plugin':
      return { draw: 'engine' }
  }
}

/** CommandOutput §3.3: dim "·" and the text, red on error, a leading "cs-feed:" removed; an empty answer draws nothing. */
export function decideCommandOutput(props: { readonly text: string; readonly isErrored: boolean }): 'nothing' | { readonly text: string; readonly isErrored: boolean } {
  const text = props.text.trim().replace(/^cs-feed:\s*/, '').trim()
  return text ? { text, isErrored: props.isErrored } : 'nothing'
}

/** SessionMode §3.5: append the feed's mode while this session's feed is on. Off, site() passes the row through before any painter runs. */
export function sessionModes(modes: readonly string[]): readonly string[] {
  return [...modes, labels.mode]
}
