// ABOUTME: Picture tests for the flowchart layout: exact toText renderings of small charts in every direction.
// ABOUTME: Fixtures are inspected output; regenerate one only after looking at the new drawing.
import { test, expect } from 'claude-code/testing'

import { layout, toText } from '../hooks/layout'
import { parse } from '../hooks/parse'
import type { Layout } from '../hooks/layout'

function draw(source: string): Layout {
  const graph = parse(source)
  if ('error' in graph) throw new Error(graph.error)
  const drawn = layout(graph)
  if ('error' in drawn) throw new Error(drawn.error)
  return drawn
}

// The drawing without its blank margin rows, framed by newlines so a fixture reads as a picture.
const picture = (source: string) => '\n' + toText(draw(source)).replace(/^\n+|\n+$/g, '') + '\n'

test('A --> B top-down: exact cells', () => {
  const drawn = draw('graph TD\n  A --> B')
  expect(drawn.boxes).toEqual([
    { node: { id: 'A', label: 'A', shape: 'rect' }, x: 1, y: 1, width: 5, height: 3 },
    { node: { id: 'B', label: 'B', shape: 'rect' }, x: 1, y: 6, width: 5, height: 3 },
  ])
  expect(drawn.runs).toEqual([{ x: 3, y: 4, text: '│' }, { x: 3, y: 5, text: '▼' }])
  expect(drawn.labels).toEqual([])
  expect([drawn.width, drawn.height]).toEqual([7, 10])
})

test('the four directions place B around A and point the head at B', () => {
  expect(picture('graph LR\n  A --> B')).toBe(`
 █████  █████
 ██A██─►██B██
 █████  █████
`)
  expect(picture('graph RL\n  A --> B')).toBe(`
 █████  █████
 ██B██◄─██A██
 █████  █████
`)
  expect(picture('graph BT\n  A --> B')).toBe(`
 █████
 ██B██
 █████
   ▲
   │
 █████
 ██A██
 █████
`)
})

test('heads at both ends, at the source only, and none', () => {
  expect(picture('graph LR\n  A <--> B\n  C <-- D\n  E --- F')).toBe(`
 █████  █████
 ██A██◄►██B██
 █████  █████

 █████  █████
 ██C██◄─██D██
 █████  █████

 █████  █████
 ██E██──██F██
 █████  █████
`)
})

test('an unrelated edge crossing another is drawn as a crossing, never a junction', () => {
  expect(picture('graph TD\n  A --> B\n  C --> D\n  A --> D')).toBe(`
 █████   █████
 ██A██   ██C██
 █████   █████
  │ │       │
  │ └─────┐ │
  ▼       ▼ ▼
 █████   █████
 ██B██   ██D██
 █████   █████
`)
  const text = toText(draw('graph TD\n  A --> X\n  B --> Y\n  A --> Y\n  B --> X'))
  expect(text).toContain('┼')
  expect(text).not.toMatch(/[├┤┬┴]/)
})

test('parallel edges keep separate lines, heads and labels', () => {
  expect(picture('graph TD\n  A -->|first| B\n  A -->|second| B')).toBe(`
 ████████████████████
 █████████A██████████
 ████████████████████
  │ first  │ second
  └──────┐ │
         ▼ ▼
        █████
        ██B██
        █████
`)
})

test('a label never erases another edge or covers a node', () => {
  expect(picture('graph TD\n  A -->|left| B\n  A --> C')).toBe(`
  ███████████
  █████A█████
  ███████████
   │ left  │
   ▼       ▼
 █████   █████
 ██B██   ██C██
 █████   █████
`)
  expect(picture('graph LR\n  A -->|a long edge label here| B')).toBe(`
 █████a long edge label here   █████
 ██A██────────────────────────►██B██
 █████                         █████
`)
})

test('a long edge passes beside the layers it skips and a back edge points at its written target', () => {
  expect(picture('graph TD\n  A --> B --> C --> D\n  A --> D')).toBe(`
   █████
   ██A██
   █████
    │ │
    │ └──┐
    ▼    │
 █████   │
 ██B██   │
 █████   │
   │     │
   ▼     │
 █████   │
 ██C██   │
 █████   │
    │    │
    │ ┌──┘
    ▼ ▼
   █████
   ██D██
   █████
`)
  const loop = toText(draw('graph TD\n  A --> B --> C\n  C --> A'))
  expect(loop.split('▲').length - 1).toBe(1)
  expect(loop.split('▼').length - 1).toBe(2)
})

test('wide characters are measured in cells', () => {
  const drawn = draw('graph TD\n  A["界界界"] --> B')
  expect(drawn.boxes[0]?.width).toBe(10)
  expect(picture('graph TD\n  A["界界界"] --> B')).toBe(`
 ██████████
 ██界界界█████
 ██████████
     │
     ▼
   █████
   ██B██
   █████
`)
})

test('ordering finds a crossing-free arrangement when one exists', () => {
  const text = toText(draw('graph TD\n  A --> X\n  A --> Y\n  B --> Y\n  B --> Z\n  C --> X'))
  expect(text).not.toContain('┼')
})

test('no box overlaps another and no line crosses a box', () => {
  const drawn = draw('graph TD\n  A --> B --> C --> D\n  D --> B\n  A --> D\n  B --> E\n  E --> A')
  for (const p of drawn.boxes) for (const q of drawn.boxes) {
    if (p === q) continue
    const apart = p.x + p.width <= q.x || q.x + q.width <= p.x || p.y + p.height <= q.y || q.y + q.height <= p.y
    expect(apart).toBe(true)
  }
  for (const run of drawn.runs) for (const box of drawn.boxes) {
    const insideRow = run.y >= box.y && run.y < box.y + box.height
    const overlapsX = run.x < box.x + box.width && run.x + run.text.length > box.x
    expect(insideRow && overlapsX).toBe(false)
  }
})

test('a 200-node chain lays out in bounded time', () => {
  let src = 'graph TD\n'
  for (let i = 0; i < 199; i++) src += `N${i} --> N${i + 1}\n`
  const started = Date.now()
  const drawn = draw(src)
  expect(Date.now() - started).toBeLessThan(2000)
  expect(drawn.boxes.length).toBe(200)
})

test('a chart within the parser limits but past the cell budget is refused with its size', () => {
  const label = 'x'.repeat(60)
  const side = (prefix: string) => Array.from({ length: 20 }, (_, i) => `${prefix}${i}[${label}]`).join(' & ')
  const graph = parse(`graph TD\n  ${side('a')} --> ${side('b')}`)
  if ('error' in graph) throw new Error(graph.error)
  expect(layout(graph)).toEqual({ error: 'diagram would be 1339x210 cells' })
})

test('a chart at the parser limits with crossings to minimise lays out in bounded time', () => {
  let src = 'graph TD\n'
  for (let i = 0; i < 400; i++) {
    const a = i % 200, b = (a + 1 + (i * 7) % 199) % 200
    if (a !== b) src += `n${a} --> n${b}\n`
  }
  const graph = parse(src)
  if ('error' in graph) throw new Error(graph.error)
  const started = Date.now()
  const drawn = layout(graph)
  expect(Date.now() - started).toBeLessThan(4500)
  expect('error' in drawn ? drawn.error : 'drawn').toMatch(/^diagram would be \d+x\d+ cells$/)
})
