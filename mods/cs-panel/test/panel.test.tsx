// ABOUTME: Engine test-kit tests for the cs-panel mod: the drawing helpers and the hooks driven through the real engine `$`.
// ABOUTME: Expected values come from the design's rules, never from the code under test.
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, PaneOpenArgs } from 'claude-code'

import { drawPane, ringBack, ringOf, type PanelView } from '../hooks/draw'
import { ASKS, COMMANDS, LOGS, PROBLEMS, REPLIES, STATUS_BODY, TOASTS } from '../hooks/register'

// ── Drawing ──────────────────────────────────────────────────────────────

const NOOP = { select: () => {}, act: () => {} }

// The text one line of the drawing shows on the terminal, from the plain-data
// tree: a plain Button with a hotkey is `<hotkey>: <label>`, one with children
// draws its children, and a row Box puts its columnGap between its children.
function textOf(node: unknown): string {
  if (typeof node === 'string') return node
  const n = node as { type: string; props: Record<string, unknown>; children?: unknown[] }
  const children = n.children ?? []
  if (n.type === 'Button' && children.length === 0) return n.props.hotkey === undefined ? String(n.props.label) : `${n.props.hotkey}: ${n.props.label}`
  if (n.type === 'Box') return children.map(textOf).join(' '.repeat(Number(n.props.columnGap ?? 0)))
  return children.map(textOf).join('')
}

// The body's lines top to bottom: a column Box (the stacked strip) gives one
// line per child.
function linesOf(tree: unknown): string[] {
  const root = tree as { children?: unknown[] }
  return (root.children ?? []).flatMap(child => {
    const c = child as { type: string; props: Record<string, unknown>; children?: unknown[] }
    return c.type === 'Box' && c.props.flexDirection === 'column' ? (c.children ?? []).map(textOf) : [textOf(c)]
  })
}

// Draws views through the test's own render hook, as the design lab does.
function drawer($: Engine, on: On): (view: PanelView) => Promise<string[]> {
  let view: PanelView | undefined
  on('ui.render', { component: 'Pane', requestId: 'fixture' }, ($, e) => {
    if (view === undefined) throw new Error('no view to draw')
    return drawPane(view, $.ui.resolve(e), NOOP)
  })
  return async next => {
    view = next
    const ui = await $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'fixture',
      props: { title: 'Sessions', isFocused: next.hasKeys, bodyColumns: next.columns, placement: 'inline', scroll: { offset: 0, bodyRows: next.bodyRows }, view: {} } })
    const lines = linesOf(await ui.drawn())
    await ui.unmount()
    return lines
  }
}

// ── The hooks, through the engine's own `$` ──────────────────────────────

const BIN = '/opt/cs/bin/cs'
const PANE_PROPS = { title: 'Sessions', isFocused: true, bodyColumns: 48, placement: 'inline', scroll: { offset: 0, bodyRows: 12 }, view: {} } as const
const COMMAND = { command: 'cs-panel', args: '', origin: { kind: 'composer' }, presentation: { columns: 80, isFullscreen: false } } as const

type Answer = { exitCode?: number; stdout?: string; stderr?: string }

// A promise the test settles: what a held answer waits on.
function gate(): { held: Promise<void>; open: () => void } {
  let open = () => {}
  const held = new Promise<void>(resolve => { open = resolve })
  return { held, open }
}

// Strips what a drawing carries per mount (press handles, the drawing plugin)
// so two drawings compare by what they show.
function shown(tree: unknown): unknown {
  if (Array.isArray(tree)) return tree.map(shown)
  if (tree === null || typeof tree !== 'object') return tree
  return Object.fromEntries(Object.entries(tree).filter(([k]) => k !== 'press' && k !== 'part').map(([k, v]) => [k, shown(v)]))
}

async function openPane($: Engine) {
  expect(await $.command.run(COMMAND)).toEqual({ text: REPLIES.opened })
  return $.ui.mount({ plugin: 'cs-panel', surface: 'terminal', component: 'Pane', requestId: 'cs-panel', props: PANE_PROPS })
}

const TURN = { text: '', turnId: 't1' }
const DONE = { answer: '', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' } as const

// The kit raises no person's close; a plugin's close of the id is the same
// ui.close the mod hooks (its origin aside, which the mod does not read). The
// command answers the refusal when the close is refused.
const CLOSER = { name: 'closer', register(on: On) {
  on('command.run', { command: 'close-panel' }, async $ => $.ui.close({ id: 'cs-panel' })
    .then(() => ({ text: '' }), (err: unknown) => ({ text: err instanceof Error ? err.message : String(err) })))
} }

// Logs each clock.every dispatch the plugins make: one when a timer is armed,
// then one per period it runs. A plugin's hooks run from their own source,
// sharing no binding with the test, so the count comes back through ui.log.
const EVERIES = { name: 'everies', register(on: On) {
  on('clock.every', async ($, e, next) => { await $.ui.log('clock.every'); return next(e) })
} }

test('no line the mod hands the engine names the plugin first: the engine prefixes it', () => {
  const lines = [
    COMMANDS['cs-panel'].description, ...Object.values(REPLIES).map(r => typeof r === 'string' ? r : r('x')),
    ...Object.values(TOASTS).map(t => t('x', 'y')), ...Object.values(PROBLEMS).map(p => p('x')), ...Object.values(LOGS).map(l => l('x')), ASKS.mail('x').question,
  ]
  expect(lines.length).toBe(19)
  expect(lines.filter(line => line.toLowerCase().startsWith('cs-panel'))).toEqual([])
})
