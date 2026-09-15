// ABOUTME: Unit tests for the cs-rotate mod against a fake engine `$`.
// ABOUTME: Covers the band's gate (crit, working, survey), the press, and the heartbeat.
import { test, expect, beforeEach } from 'bun:test'

// The plugin realm provides `h` and `Fragment` as globals; the test does the same.
;(globalThis as any).h = (type: any, props: any, ...children: any[]) => ({ type, props: props ?? {}, children })
;(globalThis as any).Fragment = 'Fragment'

import { register, CRIT_PERCENT } from '../hooks/register.tsx'

type Hook = ($: any, e: any, next: (e: any) => Promise<any>) => Promise<any>
const hooks: Record<string, Hook> = {}
const on = (event: string, a: any, b?: any) => {
  const matcher = b ? a : undefined
  const fn: Hook = b ?? a
  hooks[matcher?.component ? `${event}:${matcher.component}` : event] = fn
}

let percent: number | undefined
let filled: any[]
let written: Record<string, string>
let existing: Set<string>
const $ = {
  session: { usage: async () => ({ context: { percent } }) },
  prompt: { fill: async (args: any) => { filled.push(args); return { isFilled: true } } },
  ui: { resolve: async () => ({ Box: 'Box', Text: 'Text', Button: 'Button' }) },
  fs: {
    write: async (path: string, text: string) => { written[path] = text },
    exists: async (path: string) => existing.has(path),
  },
}

const DRAWN = { type: 'Survey', props: {}, children: [] }
const band = (props: Partial<{ isWorking: boolean; hasSurvey: boolean }> = {}) =>
  hooks['ui.render:AbovePrompt']($, { props: { isWorking: false, hasSurvey: false, ...props } }, async () => DRAWN)

function findButton(tree: any): any {
  if (!tree || typeof tree !== 'object') return undefined
  if (tree.type === 'Button') return tree
  for (const c of tree.children ?? []) { const b = findButton(c); if (b) return b }
  return undefined
}

beforeEach(() => {
  for (const k of Object.keys(hooks)) delete hooks[k]
  percent = undefined; filled = []; written = {}; existing = new Set()
  register(on as any)
})

test('the crit threshold matches the statusline default', () => {
  expect(CRIT_PERCENT).toBe(65)
})

test('below crit the band passes the drawn tree through untouched', async () => {
  percent = 64
  expect(await band()).toBe(DRAWN)
})

test('at crit the band adds one button on hotkey 1 beneath what was drawn', async () => {
  percent = 65
  const tree = await band()
  expect(tree).not.toBe(DRAWN)
  const button = findButton(tree)
  expect(button.props.hotkey).toBe('1')
  expect(button.props.label).toMatch(/rotate/)
  expect(JSON.stringify(tree)).toContain('"Survey"')
})

test('the band does not repeat the context percentage', async () => {
  percent = 71
  expect(JSON.stringify(await band())).not.toMatch(/71|ctx/)
})

test('while a turn runs the button is hidden', async () => {
  percent = 90
  expect(await band({ isWorking: true })).toBe(DRAWN)
})

test('while a survey holds the band the hook yields', async () => {
  percent = 90
  expect(await band({ hasSurvey: true })).toBe(DRAWN)
})

test('an unknown percentage draws nothing', async () => {
  percent = undefined
  expect(await band()).toBe(DRAWN)
})

test('a press fills the composer with the rotate command and sends nothing', async () => {
  percent = 80
  const button = findButton(await band())
  await button.props.onPress()
  expect(filled).toEqual([{ text: '/rotate ' }])
})

test('session.start writes a heartbeat under the session meta dir', async () => {
  existing.add('/work/.cs/local')
  const r = await hooks['session.start']($, { cwd: '/work', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(r).toEqual({ cwd: '/work' })
  const text = written['/work/.cs/local/cs-rotate.heartbeat']
  expect(text).toMatch(/^\d{4}-\d{2}-\d{2}T.*Z\n$/)
})

test('outside a cs session no heartbeat is written', async () => {
  await hooks['session.start']($, { cwd: '/plain', surface: 'terminal', isInteractive: true }, async (e) => ({ cwd: e.cwd }))
  expect(Object.keys(written)).toEqual([])
})
