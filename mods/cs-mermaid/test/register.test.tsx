// ABOUTME: Engine test-kit tests for the cs-mermaid register module: inline drawing, the fallback to source, fit and palette helpers.
// ABOUTME: Also pins the drawDiagrams option, which turns off the drawing.
import { test, expect, mock } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { ConfigRow, On } from 'claude-code'

import { Drawing, OPTION, blockRows, drawFence, drawPart, fencesOf, fillFor, fit, fitSource, labelColor, paletteFor, roleOf, splitReply } from '../hooks/register'
import { parse } from '../hooks/parse'

const TEXT = ['Flow:', '', '```mermaid', 'graph TD', '  A[prompt] --> B{cached?}', '  B -->|no| C[render]', '```'].join('\n')

test('fencesOf finds mermaid fences and ignores other fences', () => {
  expect(fencesOf(TEXT)).toEqual(['graph TD\n  A[prompt] --> B{cached?}\n  B -->|no| C[render]'])
  expect(fencesOf('```ts\nconst a = 1\n```')).toEqual([])
  // A four-backtick block quoting mermaid source is not a fence of its own.
  expect(fencesOf('x\n````mermaid\ngraph TD\nA-->B\n````\n')).toEqual([])
  // Nor is a mermaid fence quoted inside a four-backtick or a tilde block.
  expect(fencesOf('Write it like this:\n````markdown\n```mermaid\ngraph TD\nA --> B\n```\n````\nthen run it.')).toEqual([])
  expect(fencesOf('~~~\n```mermaid\ngraph TD\nA --> B\n```\n~~~')).toEqual([])
  // A fence after a closed outer block is drawn.
  expect(fencesOf('````\nquoted\n````\n```mermaid\ngraph TD\nA --> B\n```')).toEqual(['graph TD\nA --> B'])
})

// Any other three-backtick opener, with a language or none, quotes everything up to a bare
// line of at least its backticks: a mermaid fence inside it is its text, not a chart.
test('a mermaid fence quoted in a three-backtick block stays source; one after a closed block draws', () => {
  expect(fencesOf('Write it like this:\n```markdown\n```mermaid\ngraph TD\nA --> B\n```\n```')).toEqual([])
  expect(fencesOf('```\n```mermaid\ngraph TD\nA --> B\n```\n```')).toEqual([])
  // A closer takes no language: `ts` inside a ts block is its text.
  expect(fencesOf('```ts\nconst a = 1\n```ts\n```\n```mermaid\ngraph TD\nA --> B\n```')).toEqual(['graph TD\nA --> B'])
  expect(fencesOf('```bash\nls\n```\n```mermaid\ngraph TD\nA --> B\n```')).toEqual(['graph TD\nA --> B'])
  expect(fencesOf('```mermaid\ngraph TD\nA --> B\n```\n```mermaid\ngraph LR\nC --> D\n```')).toEqual(['graph TD\nA --> B', 'graph LR\nC --> D'])
  // Backticks after the opening run make inline code, not a block.
  expect(fencesOf('```npm test``` runs it\n```mermaid\ngraph TD\nA --> B\n```')).toEqual(['graph TD\nA --> B'])
})

// A reply is scanned on every streaming flush, so one long line must not cost time quadratic in
// its length: the check for a backtick after the opening run reads the line once.
test('a line of 100k backticks then x` scans in under 200 ms, and the fence after it draws', () => {
  const text = '`'.repeat(100_000) + 'x`\n```mermaid\ngraph TD\nA --> B\n```'
  const started = Date.now()
  const fences = fencesOf(text)
  expect(Date.now() - started).toBeLessThan(200)
  expect(fences).toEqual(['graph TD\nA --> B'])
})

// CommonMark: a fence closes on a bare run of its mark at least as long as its opener, with
// only blanks after it.
test('a mermaid fence closes on a bare line of three or more backticks', () => {
  const text = '```mermaid\ngraph TD\nA --> B\n````\n\ntext\n```bash\nls\n```'
  expect(fencesOf(text)).toEqual(['graph TD\nA --> B'])
  expect(splitReply(text)).toEqual([
    { kind: 'mermaid', body: 'graph TD\nA --> B' },
    { kind: 'text', body: '\n\ntext\n```bash\nls\n```' },
  ])
  expect(fencesOf('```mermaid\ngraph TD\nA --> B\n`````  \nafter')).toEqual(['graph TD\nA --> B'])
})

// CommonMark: a fence may be indented up to three spaces; four, or a tab (which reaches the
// next multiple of four), makes an indented code block, so the fence stays source.
test('a fence indented four spaces or a tab is an indented code block, not a chart', () => {
  expect(fencesOf('   ```mermaid\ngraph TD\nA --> B\n   ```')).toEqual(['graph TD\nA --> B'])
  expect(fencesOf('    ```mermaid\ngraph TD\nA --> B\n    ```')).toEqual([])
  expect(fencesOf('\t```mermaid\ngraph TD\nA --> B\n\t```')).toEqual([])
  expect(fencesOf(' \t```mermaid\ngraph TD\nA --> B\n ```')).toEqual([])
  // A line of three backticks indented four inside a fence is its content, not its closer.
  expect(fencesOf('```mermaid\ngraph TD\n    ```\nA --> B\n```')).toEqual(['graph TD\n    ```\nA --> B'])
  // An outer block's marks follow the same rule.
  expect(fencesOf('    ````\n```mermaid\ngraph TD\nA --> B\n```\n    ````')).toEqual(['graph TD\nA --> B'])
})

// CommonMark measures a fence inside a list item from the item's content column: the marker
// (`-`, `+`, `*`, or 1-9 digits and `.` or `)`) and the spaces after it.
test('a fence in a list item is indented from the item, not the margin', () => {
  const chart = (indent: string) => ['```mermaid', 'graph TD', 'A --> B', '```'].map(line => indent + line).join('\n')
  expect(fencesOf(`- a\n${chart('  ')}`)).toEqual(['graph TD\n  A --> B'])
  expect(fencesOf(`1. flow:\n${chart('   ')}`)).toEqual(['graph TD\n   A --> B'])
  expect(fencesOf(`1. flow:\n${chart('    ')}`)).toEqual(['graph TD\n    A --> B'])
  expect(fencesOf(`10. flow:\n${chart('    ')}`)).toEqual(['graph TD\n    A --> B'])
  expect(fencesOf(`- a\n  - b\n${chart('    ')}`)).toEqual(['graph TD\n    A --> B'])
  // Four columns past the item's content is an indented code block inside the item.
  expect(fencesOf(`1. x\n${chart('       ')}`)).toEqual([])
  // With no list item, four columns is an indented code block, as is the same fence once
  // prose at the margin has closed the list.
  expect(fencesOf(chart('    '))).toEqual([])
  expect(fencesOf(`- a\n\nprose\n${chart('    ')}`)).toEqual([])
  // `* * *` and `- - -` are thematic breaks, not bullets.
  expect(fencesOf(`* * *\n${chart('    ')}`)).toEqual([])
  expect(fencesOf(`- - -\n${chart('    ')}`)).toEqual([])
  // Right after the opener a body line back at the margin ends the item and the fence open in
  // it, with nothing in it: no chart.
  expect(fencesOf('1. flow:\n   ```mermaid\ngraph TD\nA --> B\n   ```')).toEqual([])
  // A fence opened on the marker's own line is a fence in the item, and a chart after the list
  // draws too.
  expect(fencesOf('- ```mermaid\n  graph TD\n  A --> B\n  ```\n\nlater:\n```mermaid\ngraph TD\nC --> D\n```')).toEqual(['graph TD\n  A --> B', 'graph TD\nC --> D'])
  // A blockquote's `>` is not read: a quoted fence stays source.
  expect(fencesOf('> ```mermaid\n> graph TD\n> A --> B\n> ```')).toEqual([])
})

// The rest of the list item rules the scanner keeps, each beside its counterpart.
test('a list item takes its content column from its marker and the blanks after it', () => {
  const chart = (indent: string) => ['```mermaid', 'graph TD', 'A --> B', '```'].map(line => indent + line).join('\n')
  // Five blanks after the marker make the text indented code, its content column one past the
  // marker; with four, the content starts at the text.
  expect(fencesOf('-     code\n      ```mermaid\n      graph TD\n      A --> B\n      ```')).toEqual([])
  expect(fencesOf(`-    code\n${chart('     ')}`)).toEqual(['graph TD\n     A --> B'])
  // A marker with nothing after it puts the content one column past the marker.
  expect(fencesOf('-\n     ```mermaid\n     graph TD\n     A --> B\n     ```')).toEqual(['graph TD\n     A --> B'])
  // `)` ends an ordered marker as `.` does.
  expect(fencesOf(`1) flow:\n${chart('    ')}`)).toEqual(['graph TD\n    A --> B'])
  // A blank line inside an item does not end it.
  expect(fencesOf('1. one\n\n    ```mermaid\n    graph TD\n    A --> B\n    ```')).toEqual(['graph TD\n    A --> B'])
  // A marker in indented code starts no item; three columns in, it does.
  expect(fencesOf('    1. a\n       ```mermaid\n       graph TD\n       A --> B\n       ```')).toEqual([])
  expect(fencesOf(`   1. a\n${chart('      ')}`)).toEqual(['graph TD\n      A --> B'])
  // An ordered marker has at most nine digits.
  expect(fencesOf(`123456789. flow:\n${chart(' '.repeat(11))}`)).toEqual(['graph TD\n           A --> B'])
  expect(fencesOf(`1234567890. flow:\n${chart(' '.repeat(12))}`)).toEqual([])
})

// Claude Code reads a reply with marked, which keeps a line left of a list item's content
// column inside the item (a lazy line) unless it starts a block of its own, a blank line came
// before it inside the item, or the line before it was a fence mark, heading, thematic break or
// indented code. A lazy line in an open fence is part of its body.
test('a lazy line left of a list item keeps the item and the fence open in it', () => {
  expect(fencesOf('1. Flow:\n   ```mermaid\n   graph TD\nA --> B\n   ```\n\n2. Next:\n\n```mermaid\ngraph LR\nC --> D\n```')).toEqual(['graph TD\nA --> B', 'graph LR\nC --> D'])
  expect(fencesOf('- a\nprose\n    ```mermaid\n    graph TD\n    A --> B\n    ```')).toEqual(['graph TD\n    A --> B'])
})

// CommonMark and marked read a fence opened on a list marker's own line as a fence in the item.
test('a fence opened on a list marker\'s own line is a fence in the item', () => {
  expect(fencesOf('- ```mermaid\n  graph TD\n  A --> B\n  ```')).toEqual(['graph TD\n  A --> B'])
  expect(fencesOf('1. ```mermaid\n   graph TD\n   A --> B\n   ```')).toEqual(['graph TD\n   A --> B'])
  expect(fencesOf('- ```bash\n  ls\n  ```\n  ```mermaid\n  graph TD\n  A --> B\n  ```')).toEqual(['graph TD\n  A --> B'])
  expect(fencesOf('- ```markdown\n  ```mermaid\n  graph TD\n  A --> B\n  ```\n  ```')).toEqual([])
  // Right after the opener a line back at the margin ends the item and its empty fence; the bare
  // ``` under it then opens a block of its own, quoting the chart after it.
  expect(fencesOf('- ```mermaid\ngraph TD\n  ```\n```mermaid\ngraph LR\nC --> D\n```')).toEqual([])
  // The marker goes to the engine with the prose, so the list keeps its bullet.
  expect(splitReply('- ```mermaid\n  graph TD\n  A --> B\n  ```\n- next')).toEqual([
    { kind: 'text', body: '- ' },
    { kind: 'mermaid', body: 'graph TD\n  A --> B' },
    { kind: 'text', body: '\n- next' },
  ])
})

// A paragraph at a reply's top level runs on through a list marker unless it is a bullet or `1.`
// or `1)` with text after it; inside a list item any marker starts an item (marked reads an item's
// text a line at a time). A line of only `-` or `=` under a text line underlines it as a heading,
// and an item begins with at most one blank line. A fence after a marker that starts no item is
// indented code.
test('a list marker that cannot start an item leaves the fence under it indented code', () => {
  const chart = (indent: string) => ['```mermaid', 'graph TD', 'A --> B', '```'].map(line => indent + line).join('\n')
  expect(fencesOf('Steps:\n2. flow:\n    ```mermaid\n    graph TD\n    A --> B\n    ```')).toEqual([])
  expect(fencesOf(`Steps:\n1. flow:\n${chart('    ')}`)).toEqual(['graph TD\n    A --> B'])
  expect(fencesOf(`Steps:\n\n2. flow:\n${chart('    ')}`)).toEqual(['graph TD\n    A --> B'])
  expect(fencesOf(`- Steps:\n  2. flow:\n${chart('      ')}`)).toEqual(['graph TD\n      A --> B'])
  expect(fencesOf('-\n\n    ```mermaid\n    graph TD\n    A --> B\n    ```')).toEqual([])
  expect(fencesOf(`-\n${chart('    ')}`)).toEqual(['graph TD\n    A --> B'])
  expect(fencesOf('Title\n-\n    ```mermaid\n    graph TD\n    A --> B\n    ```')).toEqual([])
  expect(fencesOf(`Title\n-\n2. x\n${chart('    ')}`)).toEqual(['graph TD\n    A --> B'])
})

// CommonMark 4.5: a fence still open when its list item ends is a code block up to there. The
// line that ends the item is read afresh outside it; a bare ``` there opens a block of its own.
test('a fence open in a list item ends with the item, and the line that ends it is read outside', () => {
  const text = '- a\n  ```mermaid\n  graph TD\n  A --> B\n```\n\nlater:\n\n```mermaid\ngraph LR\nC --> D\n```'
  expect(fencesOf(text)).toEqual(['graph TD\n  A --> B'])
  expect(splitReply(text)).toEqual([
    { kind: 'text', body: '- a' },
    { kind: 'mermaid', body: 'graph TD\n  A --> B' },
    { kind: 'text', body: '\n```\n\nlater:\n\n```mermaid\ngraph LR\nC --> D\n```' },
  ])
})

test('a reply whose only fence is indented four spaces is left to the engine', async ($, on) => {
  on('config.list', () => ({ value: [] }))
  mock.env(on, {})
  const seen: { text: string; isFirstOfReply: boolean }[] = []
  engine(on, seen)
  const text = 'Code:\n\n    ```mermaid\n    graph TD\n    A --> B\n    ```'
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text, isFirstOfReply: true } })
  expect(seen).toEqual([{ text, isFirstOfReply: true }])
  await reply.unmount()
})

test('a reply without mermaid is left to the engine', async ($, on) => {
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine drew it</Text>
  })
  const mounted = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text: 'plain', isFirstOfReply: true } })
  expect(await mounted.find({ type: 'Text', text: 'engine drew it' })).toBeDefined()
  await mounted.unmount()
})

// The engine stand-in draws each block it is handed and records what it was handed.
function engine(on: On, seen: { text: string; isFirstOfReply: boolean }[]) {
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    seen.push({ text: e.props.text, isFirstOfReply: e.props.isFirstOfReply })
    return <Text>engine: {e.props.text}</Text>
  })
}

test('a reply with a fence hands its prose to the engine and draws the chart as blocks, with no fence left', async ($, on) => {
  on('config.list', () => ({ value: [] }))
  mock.env(on, {})
  const seen: { text: string; isFirstOfReply: boolean }[] = []
  engine(on, seen)
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text: TEXT, isFirstOfReply: true } })
  expect(seen).toEqual([{ text: 'Flow:\n', isFirstOfReply: true }])
  expect(await reply.find({ type: 'Text', text: 'engine: Flow:' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'prompt' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'cached?' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'render' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'no' })).toBeDefined()
  expect(await reply.findAll({ type: 'Code' })).toEqual([])
  // Role hues: prompt leads, cached? branches, render ends.
  expect((await reply.find({ type: 'Text', text: 'prompt' }))?.props.backgroundColor).toBe('#D3F9D8')
  expect((await reply.find({ type: 'Text', text: 'cached?' }))?.props.backgroundColor).toBe('#FFF3BF')
  expect((await reply.find({ type: 'Text', text: 'render' }))?.props.backgroundColor).toBe('#E9ECEF')
  // The `no` label answers the decision: drawn in the answer's colour, not the line's.
  expect((await reply.find({ type: 'Text', text: 'no' }))?.props.color).toBe('#C92A2A')
  await reply.unmount()
})

test('a reply that opens with a fence gives the bullet to no prose part', async ($, on) => {
  on('config.list', () => ({ value: [] }))
  mock.env(on, {})
  const seen: { text: string; isFirstOfReply: boolean }[] = []
  engine(on, seen)
  const text = '```mermaid\ngraph TD\n  A --> B\n```\nafter'
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text, isFirstOfReply: true } })
  expect(seen).toEqual([{ text: '\nafter', isFirstOfReply: false }])
  await reply.unmount()
})

test('an unsupported chart stays a fence with the reason under it', async ($, on) => {
  on('config.list', () => ({ value: [] }))
  mock.env(on, {})
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine drew it</Text>
  })
  const text = '```mermaid\ngraph TD\n  subgraph S\n  A --> B\n  end\n```'
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text, isFirstOfReply: true } })
  expect(await reply.find({ type: 'Code', text: 'subgraph S' })).toBeDefined()
  const reason = await reply.find({ type: 'Text', text: 'mermaid: subgraphs are not supported' })
  expect(reason?.props.dimColor).toBe(true)
  // The source first, the reason under it.
  expect((await reply.findAll({})).map(node => node.type).filter(type => type === 'Code' || type === 'Text')).toEqual(['Code', 'Text'])
  await reply.unmount()
})

// A throw while fitting a fence is the engine's cue to draw the whole reply plain (the hook
// is skipped). No fence found by fuzzing parse and layout throws, so a fitter that does
// stands in: the fence shows its source and the message, as a refused chart does.
test('a fence whose fitting throws shows its source with the error named under it', async ($, on) => {
  const source = 'graph TD\n  A --> B'
  const thrower = () => { throw new Error('boom at layer 2') }
  on('ui.render', { component: 'Pane' }, ($, e) => {
    const elements = $.ui.resolve(e)
    const { Box } = elements
    return <Box flexDirection="column">{drawPart(source, 74, paletteFor(undefined), elements, thrower)}</Box>
  })
  const pane = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'Pane', requestId: 'thrown', props: { title: 'thrown', isFocused: false, placement: 'inline', bodyColumns: 80, scroll: { offset: 0, bodyRows: 24 }, view: {} } })
  expect(await pane.find({ type: 'Code', text: 'graph TD\n  A --> B' })).toBeDefined()
  expect((await pane.find({ type: 'Text', text: 'mermaid: could not draw: boom at layer 2' }))?.props.dimColor).toBe(true)
  await pane.unmount()
})

test('a reply with a refused fence still draws its prose and the fence that fits', async ($, on) => {
  on('config.list', () => ({ value: [] }))
  mock.env(on, {})
  const seen: { text: string; isFirstOfReply: boolean }[] = []
  engine(on, seen)
  const text = 'Two charts:\n```mermaid\ngraph TD\n  subgraph S\n  A --> B\n  end\n```\nthen\n```mermaid\ngraph TD\n  C[ok] --> D[done]\n```'
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text, isFirstOfReply: true } })
  expect(seen).toEqual([{ text: 'Two charts:', isFirstOfReply: true }, { text: '\nthen', isFirstOfReply: false }])
  expect(await reply.find({ type: 'Code', text: 'graph TD\n  subgraph S\n  A --> B\n  end' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'mermaid: subgraphs are not supported' })).toBeDefined()
  expect((await reply.find({ type: 'Text', text: 'done' }))?.props.backgroundColor).toBe('#E9ECEF')
  await reply.unmount()
})

test('with drawDiagrams off, a reply with a fence is left to the engine', { options: { [OPTION]: false } }, async ($, on) => {
  on('config.list', () => ({ value: [] }))
  mock.env(on, {})
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine drew it</Text>
  })
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text: TEXT, isFirstOfReply: true } })
  expect(await reply.find({ type: 'Text', text: 'engine drew it' })).toBeDefined()
  expect(await reply.find({ type: 'Text', text: 'cached?' })).toBeUndefined()
  await reply.unmount()
})

test('fit turns a wide LR chart, keeps one that fits, and reports one that cannot fit', () => {
  const wide = parse('graph LR\n  A[a long label here] --> B[another long label] --> C[and a third one]')
  if ('error' in wide) throw new Error(wide.error)
  const turned = fit(wide, 40)
  if ('error' in turned) throw new Error(turned.error)
  expect(turned.turned).toBe(true)
  expect(turned.drawn.width).toBeLessThanOrEqual(40)
  const kept = fit(wide, 200)
  if ('error' in kept) throw new Error(kept.error)
  expect(kept.turned).toBe(false)
  const fan = parse('graph TD\n  A --> B & C & D & E & F')
  if ('error' in fan) throw new Error(fan.error)
  // five 5-wide blocks, four 3-cell gaps, a margin each side
  expect(fit(fan, 20)).toEqual({ error: 'diagram is 39 columns wide, the transcript 20' })
})

test('a node takes its role from its shape, else from its place in the flow; a style fill wins', () => {
  const graph = parse(['graph TD', '  S((go)) --> A[one] --> B[two] --> C[three]', '  B --> D[four]', '  E{ask} --> F[alone]', '  G[lone]', '  C --> Z((done))', '  style B fill:#abc'].join('\n'))
  if ('error' in graph) throw new Error(graph.error)
  const role = (id: string) => roleOf(graph.nodes.find(n => n.id === id)!, graph)
  expect(role('S')).toBe('start')
  expect(role('Z')).toBe('end')
  expect(role('A')).toBe('step')
  expect(role('B')).toBe('decision')
  expect(role('C')).toBe('step')
  expect(role('D')).toBe('end')
  expect(role('E')).toBe('decision')
  expect(role('F')).toBe('end')
  expect(role('G')).toBe('step')
  expect(fillFor('start', paletteFor('light'))).toBe('#D3F9D8')
  expect(fillFor('end', paletteFor('dark'))).toBe('#3A3D42')
  expect(fillFor('decision', paletteFor('light'))).toBe('#FFF3BF')
  expect(fillFor('step', paletteFor('light'))).toBe('#ECECFF')
  expect(graph.nodes.find(n => n.id === 'B')!.style).toEqual({ fill: '#abc' })
})

test('a decision answer colours its label; other labels take the line colour', () => {
  expect(labelColor('yes', paletteFor('light'))).toBe('#277C38')
  expect(labelColor('Fail', paletteFor('light'))).toBe('#C92A2A')
  expect(labelColor('degraded', paletteFor('dark'))).toBe('#FF8787')
  expect(labelColor('retry later', paletteFor('light'))).toBe('#333333')
  expect(labelColor('nothing', paletteFor('light'))).toBe('#333333')
})

test('the palette follows the theme row', () => {
  expect(paletteFor('dark').fill).toBe('#3B3F6B')
  expect(paletteFor('dark-daltonized').fill).toBe('#3B3F6B')
  expect(paletteFor('light').fill).toBe('#ECECFF')
  expect(paletteFor('light-ansi').fill).toBe('#ECECFF')
  expect(paletteFor(undefined).fill).toBe('#ECECFF')
})

// Claude Code's `auto` theme names no polarity, and the engine exposes none: cs's own
// reading of the terminal decides, its theme first, then the measured background.
test('a theme row that names no polarity falls to the terminal cs measured', () => {
  expect(paletteFor('auto', { theme: 'dark' }).fill).toBe('#3B3F6B')
  expect(paletteFor('auto', { theme: 'light' }).fill).toBe('#ECECFF')
  expect(paletteFor('auto', { bg: '40;44;52' }).fill).toBe('#3B3F6B')
  expect(paletteFor('auto', { bg: '252;247;229' }).fill).toBe('#ECECFF')
  // The theme cs read wins over its background measurement; the theme row wins over both.
  expect(paletteFor('auto', { theme: 'light', bg: '0;0;0' }).fill).toBe('#ECECFF')
  expect(paletteFor('light', { theme: 'dark', bg: '0;0;0' }).fill).toBe('#ECECFF')
  // A background that is not three channels is no measurement.
  expect(paletteFor('auto', { bg: 'default' }).fill).toBe('#ECECFF')
  expect(paletteFor(undefined, {}).fill).toBe('#ECECFF')
})

// Only a built-in theme names a polarity (`dark`, `light`, and their `-daltonized` and `-ansi`
// kinds); a `custom:<slug>` theme does not, whatever its slug spells.
test('a custom theme falls to the terminal cs measured, whatever its name holds', () => {
  expect(paletteFor('custom:moonlight', { theme: 'dark' }).fill).toBe('#3B3F6B')
  expect(paletteFor('custom:twilight', { theme: 'dark' }).fill).toBe('#3B3F6B')
  expect(paletteFor('custom:highlight', { bg: '0;0;0' }).fill).toBe('#3B3F6B')
  expect(paletteFor('custom:darkroom', { theme: 'light' }).fill).toBe('#ECECFF')
  expect(paletteFor('custom:darkroom', {}).fill).toBe('#ECECFF')
  expect(paletteFor('dark-ansi', { theme: 'light' }).fill).toBe('#3B3F6B')
  expect(paletteFor('light-daltonized', { theme: 'dark' }).fill).toBe('#ECECFF')
})

const THEME_ROW = (value: string): ConfigRow => ({ key: 'theme', label: 'Theme', kind: 'choice', value, options: ['auto', 'dark', 'light'], provider: { plugin: 'engine', tier: 'core' }, isLocked: false })

test('a reply under the auto theme on a dark terminal draws the dark palette', async ($, on) => {
  on('config.list', () => ({ value: [THEME_ROW('auto')] }))
  mock.env(on, { CS_TERM_THEME: 'dark' })
  engine(on, [])
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text: TEXT, isFirstOfReply: true } })
  expect((await reply.find({ type: 'Text', text: 'prompt' }))?.props.backgroundColor).toBe('#1F4D2B')
  expect((await reply.find({ type: 'Text', text: 'no' }))?.props.color).toBe('#FF8787')
  await reply.unmount()
})

// WCAG 2 relative luminance and contrast ratio, from the formula in the spec.
function luminance(hex: string): number {
  const channel = (at: number) => {
    const c = parseInt(hex.slice(at, at + 2), 16) / 255
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
  }
  return 0.2126 * channel(1) + 0.7152 * channel(3) + 0.0722 * channel(5)
}
function contrast(ink: string, background: string): number {
  const [lighter, darker] = [luminance(ink), luminance(background)].sort((p, q) => q - p) as [number, number]
  return (lighter + 0.05) / (darker + 0.05)
}

// Lines and edge labels are drawn on the terminal's own background; a node's label on its fill.
// Every such pair meets WCAG AA for text (4.5:1) with 0.1 to spare, on the backgrounds a terminal
// has: white, a cream (252;247;229), Solarized Light (253;246;227) and the light background of
// cs's own status-line art (251;246;233) under the light palette, black and two dark greys under
// the dark one.
test('every ink in each palette reads at 4.5:1, with 0.1 to spare, on what it is drawn over', () => {
  expect(contrast('#FFFFFF', '#000000')).toBe(21)
  const least = 4.5 + 0.1
  const terminals = { light: ['#FFFFFF', '#FCF7E5', '#FDF6E3', '#FBF6E9'], dark: ['#000000', '#1C1C1E', '#282C34'] }
  const failing: string[] = []
  for (const [name, backgrounds] of Object.entries(terminals)) {
    const palette = paletteFor(name)
    for (const background of backgrounds) for (const ink of ['line', 'good', 'bad'] as const) {
      const ratio = contrast(palette[ink], background)
      if (ratio < least) failing.push(`${name} ${ink} ${palette[ink]} on ${background}: ${ratio.toFixed(2)}`)
    }
    for (const fill of ['fill', 'decision', 'start', 'end'] as const) {
      const ratio = contrast(palette.text, palette[fill])
      if (ratio < least) failing.push(`${name} text ${palette.text} on ${fill} ${palette[fill]}: ${ratio.toFixed(2)}`)
    }
  }
  expect(failing).toEqual([])
})

test('blockRows pads full-width rows with the label centred, measured in cells', () => {
  expect(blockRows('ab', 8, 3)).toEqual(['        ', '   ab   ', '        '])
  expect(blockRows('abc', 8, 3)).toEqual(['        ', '  abc   ', '        '])
  expect(blockRows('界界', 6, 3)).toEqual(['      ', ' 界界 ', '      '])
  expect(blockRows('toolong', 4, 5)).toEqual(['    ', '    ', 'too…', '    ', '    '])
})

test('splitReply keeps prose and fences in order', () => {
  expect(splitReply(TEXT)).toEqual([
    { kind: 'text', body: 'Flow:\n' },
    { kind: 'mermaid', body: 'graph TD\n  A[prompt] --> B{cached?}\n  B -->|no| C[render]' },
  ])
  expect(splitReply('a\n```mermaid\ngraph TD\nA --> B\n```\nb\n```mermaid\ngraph LR\nC --> D\n```')).toEqual([
    { kind: 'text', body: 'a' },
    { kind: 'mermaid', body: 'graph TD\nA --> B' },
    { kind: 'text', body: '\nb' },
    { kind: 'mermaid', body: 'graph LR\nC --> D' },
  ])
})


// A design tool outside cs draws a fence by calling Drawing or drawFence itself. A Pane
// the test draws from those exports must match the reply the mod draws, but
// for the root's stamp, which names the plugin that returned the tree.
async function sameAsExports($: Engine, source: string) {
  const reply = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'AssistantMessage', props: { text: `\`\`\`mermaid\n${source}\n\`\`\``, isFirstOfReply: true } })
  const pane = await $.ui.mount({ plugin: 'cs-mermaid', surface: 'terminal', component: 'Pane', requestId: 'exports', props: { title: 'exports', isFocused: false, placement: 'inline', bodyColumns: 80, scroll: { offset: 0, bodyRows: 24 }, view: {} } })
  const { part: drawer, ...drawn } = await reply.drawn() as { part?: unknown }
  const { part: exporter, ...ours } = await pane.drawn() as { part?: unknown }
  expect([drawer, exporter]).toEqual([{ plugin: 'cs-mermaid' }, { plugin: 'test' }])
  expect(ours).toEqual(drawn)
  await reply.unmount(); await pane.unmount()
}

test('a chart the mod draws is the tree Drawing draws from the fitted chart', async ($, on) => {
  const source = 'graph TD\n  A[prompt] --> B{cached?}\n  B -->|no| C[render]'
  on('config.list', () => ({ value: [] }))
  mock.env(on, {})
  on('ui.render', { component: 'Pane' }, ($, e) => {
    const elements = $.ui.resolve(e)
    const { Box } = elements
    // No viewport measured: the mod fits the chart to 80 columns less its 6-cell inset.
    const fitted = fitSource(source, 74)
    if ('error' in fitted) throw new Error(fitted.error)
    return <Box flexDirection="column"><Box marginY={1}><Drawing drawn={fitted.drawn} graph={fitted.graph} palette={paletteFor(undefined)} elements={elements} /></Box></Box>
  })
  await sameAsExports($, source)
})

test('a chart the parser refuses is the tree drawFence draws from its source and reason', async ($, on) => {
  const source = 'graph TD\n  subgraph S\n  A --> B\n  end'
  on('config.list', () => ({ value: [] }))
  mock.env(on, {})
  on('ui.render', { component: 'Pane' }, ($, e) => {
    const elements = $.ui.resolve(e)
    const { Box } = elements
    return <Box flexDirection="column">{drawFence(source, 'subgraphs are not supported', elements)}</Box>
  })
  await sameAsExports($, source)
})
