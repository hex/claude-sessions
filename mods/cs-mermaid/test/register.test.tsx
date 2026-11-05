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
  // A body line back at the margin closes the item and the fence open in it: no chart.
  expect(fencesOf('1. flow:\n   ```mermaid\ngraph TD\nA --> B\n   ```')).toEqual([])
  // A blockquote's `>` is not read: a quoted fence stays source.
  expect(fencesOf('> ```mermaid\n> graph TD\n> A --> B\n> ```')).toEqual([])
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
  expect(labelColor('yes', paletteFor('light'))).toBe('#28823A')
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
// Every such pair meets WCAG AA for text (4.5:1) on the backgrounds a terminal has: white and
// a cream (252;247;229) under the light palette, black and two dark greys under the dark one.
test('every ink in each palette reads at 4.5:1 on what it is drawn over', () => {
  expect(contrast('#FFFFFF', '#000000')).toBe(21)
  const terminals = { light: ['#FFFFFF', '#FCF7E5'], dark: ['#000000', '#1C1C1E', '#282C34'] }
  const failing: string[] = []
  for (const [name, backgrounds] of Object.entries(terminals)) {
    const palette = paletteFor(name)
    for (const background of backgrounds) for (const ink of ['line', 'good', 'bad'] as const) {
      const ratio = contrast(palette[ink], background)
      if (ratio < 4.5) failing.push(`${name} ${ink} ${palette[ink]} on ${background}: ${ratio.toFixed(2)}`)
    }
    for (const fill of ['fill', 'decision', 'start', 'end'] as const) {
      const ratio = contrast(palette.text, palette[fill])
      if (ratio < 4.5) failing.push(`${name} text ${palette.text} on ${fill} ${palette[fill]}: ${ratio.toFixed(2)}`)
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
