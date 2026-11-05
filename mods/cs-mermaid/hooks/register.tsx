// ABOUTME: cs-mermaid mod: draws each mermaid flowchart fence in a reply inline, as coloured blocks and line glyphs.
// ABOUTME: One /config row (`cs-mermaid.drawDiagrams`, on by default) controls the drawing; CLAUDE.local.md carries the diagram instruction.
import type { EngineInterface, Register } from 'claude-code'

import { layout } from './layout'
import type { Layout } from './layout'
import { parse } from './parse'
import type { Graph, GraphNode, ParseError } from './parse'
import { cellWidth, padToWidth, truncateToWidth } from './text'

// The /config row (`cs-mermaid.drawDiagrams`): off, fences stay source.
export const OPTION = 'drawDiagrams'

// A mermaid fence opens on its own line with exactly three backticks and `mermaid`. Any other
// opener (three backticks with another language or none, four or more, or three tildes) opens an
// outer block that quotes what it holds; a fence inside one is quoted source, not a chart. Either
// closes on a bare line of its mark at least as long as its opener. A backtick after the opening
// run makes the line inline code, not an opener. Any of these marks may be indented up to three
// columns past the margin, or inside a list item past the item's content column (CommonMark); at
// four, a tab reaching the next multiple of four, the line is an indented code block, not a fence.
// List items end where marked, which Claude Code reads a reply with, ends them; a block still open
// in an item ends with it (CommonMark 4.5), and a mermaid fence ended so is a chart up to there.
type Fence = { start: number; end: number; body: string }
// A list item open around the line being read: the column its content starts at, and whether a
// blank line has come inside it (a marker with nothing after it counts as one, as marked reads it).
type Item = { content: number; blank: boolean }
export function scanFences(text: string): Fence[] {
  const fences: Fence[] = []
  // The open list items, outermost first. A fenced block keeps how many were open when it opened
  // (`depth`), and ends with the item it opened in.
  const items: Item[] = []
  // The fenced block open on the line being read: a mermaid fence keeps where it and its body start.
  let block: { mark: string; length: number; depth: number; mermaid?: { start: number; bodyStart: number } } | undefined
  // Whether the line before was a fence mark, heading, thematic break or indented code, after which
  // a line left of an item's content column ends the item rather than continuing it.
  let settled = false
  // Whether the line before was a line of text in the innermost container. A line of only `-` or
  // `=` under one underlines it as a heading, and at a reply's top level only a bullet or `1.` or
  // `1)` with text after it starts a list item there (marked reads an item's text a line at a time,
  // so inside an item any marker does).
  let paragraph = false
  // Whether the line before was a list marker with nothing after it: an item begins with at most
  // one blank line, so a blank line next ends that item.
  let bare = false
  let at = 0
  const closeItems = (depth: number) => {
    items.length = depth
    paragraph = false
    if (!block || block.depth <= depth) return
    const { mermaid } = block
    if (mermaid) fences.push({ start: mermaid.start, end: at - 1, body: text.slice(mermaid.bodyStart, Math.max(mermaid.bodyStart, at - 1)) })
    block = undefined
  }
  for (const line of text.split('\n')) {
    const next = at + line.length + 1
    const { column, rest } = indentation(line, 0)
    if (rest === '') {
      if (bare) closeItems(items.length - 1)
      for (const item of items) item.blank = true
      paragraph = false
      bare = false
      at = next
      continue
    }
    // A line left of an item's content column is a lazy line, read as the item's content, unless it
    // starts a block of its own within three columns of the item's container, a blank line came
    // inside the item, or the line before settled; then it ends the item and every item inside it.
    const outermost = items.findIndex(item => column < item.content)
    const container = outermost > 0 ? items[outermost - 1]!.content : 0
    const lazy: boolean = outermost !== -1 && !settled && !items.slice(outermost).some(item => item.blank) && !(column - container < 4 && startsBlock(rest))
    if (outermost !== -1 && !lazy) closeItems(outermost)
    const margin = items.length > 0 ? items[items.length - 1]!.content : 0
    // Four columns past the margin a line is indented code, which opens nothing; nor does a lazy line.
    const indented = column - margin >= 4
    const mark = indented || lazy ? undefined : fenceMark(rest)
    // The line as its innermost container reads it: an item's marker line by what follows the marker.
    let read = { indented, text: rest }
    let pushed = false
    let underline = false
    if (mark && block) {
      if (mark[0] === block.mark && mark.length >= block.length && rest === mark) {
        const { mermaid } = block
        if (mermaid) fences.push({ start: mermaid.start, end: at + line.length, body: text.slice(mermaid.bodyStart, Math.max(mermaid.bodyStart, at - 1)) })
        block = undefined
      }
    } else if (mark) {
      // The newline before a mermaid fence belongs to it, not to the prose above.
      const mermaid = mark === '```' && rest.slice(3).trim() === 'mermaid' ? { start: Math.max(0, at - 1), bodyStart: next } : undefined
      block = { mark: mark[0]!, length: mark.length, depth: items.length, mermaid }
    } else if (!indented && !lazy && !block) {
      const item = listItem(rest, column)
      if (paragraph && /^(?:-+|=+)$/.test(rest)) underline = true
      else if (item && (items.length > 0 || !paragraph || (item.text !== '' && /^(?:[-+*]|1[.)])$/.test(item.marker)))) {
        items.push({ content: item.content, blank: item.text === '' })
        read = { indented: item.textColumn - item.content >= 4, text: item.text }
        pushed = true
      }
    }
    settled = !lazy && (read.indented || /^(?:```|~~~|#)/.test(read.text) || THEMATIC.test(read.text))
    bare = pushed && read.text === ''
    // An indented line outside a block leaves `paragraph` as it was: its continuation, or code.
    if (block || mark || underline) paragraph = false
    else if (lazy) paragraph = true
    else if (pushed || !indented) paragraph = !read.indented && read.text !== '' && !/^#{1,6}(?:[ \t]|$)/.test(read.text) && !THEMATIC.test(read.text)
    at = next
  }
  return fences
}

// The fence mark a line opens with: three or more backticks with no backtick after them (one
// makes the line inline code), or three or more tildes. One pass over the line, however long.
function fenceMark(rest: string): string | undefined {
  const mark = /^(?:`{3,}|~{3,})/.exec(rest)?.[0]
  return mark?.[0] === '`' && rest.includes('`', mark.length) ? undefined : mark
}

// A line that starts a block of its own, which a list item does not take as a lazy line: a fence
// mark, a heading, an HTML tag, a list marker or a thematic break (marked's list rules).
function startsBlock(rest: string): boolean {
  return /^(?:```|~~~|#|<(?:[a-z].*>|!--)|(?:[-+*]|\d{1,9}[.)])(?:[ \t]|$))/i.test(rest) || THEMATIC.test(rest)
}

// The column a line's text starts at, counting on from `column` (a tab reaches the next multiple
// of four), and that text without its trailing blanks.
function indentation(line: string, column: number): { column: number; rest: string } {
  let i = 0
  for (; i < line.length; i++) {
    if (line[i] === ' ') column += 1
    else if (line[i] === '\t') column += 4 - (column % 4)
    else break
  }
  return { column, rest: line.slice(i).trimEnd() }
}

// Three or more `*`, `-` or `_` alone on a line, blanks between them allowed.
const THEMATIC = /^(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$/

// A list item that opens with `rest` at `column`: a bullet (`-`, `+`, `*`) or 1-9 digits and `.`
// or `)`, then blanks or nothing; a thematic break is not one. Its content starts past one to four
// columns of blanks, or one column past the marker when more or nothing follow it (CommonMark).
// `text` is what follows the marker and its blanks, starting at `textColumn`.
function listItem(rest: string, column: number): { marker: string; content: number; text: string; textColumn: number } | undefined {
  if (THEMATIC.test(rest)) return undefined
  const marker = /^(?:[-+*]|\d{1,9}[.)])(?=[ \t]|$)/.exec(rest)?.[0]
  if (marker === undefined) return undefined
  const after = column + marker.length
  const { column: textColumn, rest: text } = indentation(rest.slice(marker.length), after)
  return { marker, content: text === '' || textColumn - after > 4 ? after + 1 : textColumn, text, textColumn }
}

export function fencesOf(text: string): string[] {
  return scanFences(text).map(fence => fence.body.trim()).filter(Boolean)
}

export type Fitted = { drawn: Layout; graph: Graph; turned: boolean } | { error: string }

// A left-to-right chart wider than the transcript is turned top-down; a chart still too wide, or one
// the engine refuses, is reported so the reply shows the source instead of a clipped drawing.
export function fit(graph: Graph, columns: number): Fitted {
  const first = layout(graph)
  if ('error' in first) return first
  if (first.width <= columns) return { drawn: first, graph, turned: false }
  if (graph.dir === 'LR' || graph.dir === 'RL') {
    const turned = layout({ ...graph, dir: graph.dir === 'LR' ? 'TD' : 'BT' })
    if ('error' in turned) return turned
    if (turned.width <= columns) return { drawn: turned, graph, turned: true }
    return { error: `diagram is ${turned.width} columns wide, the transcript ${columns}` }
  }
  return { error: `diagram is ${first.width} columns wide, the transcript ${columns}` }
}

// Nodes are solid blocks: three rows of background colour with the label on the middle row.
// Mermaid's default theme fills every node #ECECFF; here a node's role in the flow gives it a
// hue, so a chart of plain `[ ]` boxes still reads as a flow: a decision (diamond or hexagon,
// or any node that branches) amber, a start (a circle, or a node nothing leads to) green, an
// end (a node that leads nowhere) grey. A `style` or `classDef` fill wins over all of it.
type Palette = { fill: string; decision: string; start: string; end: string; text: string; line: string; good: string; bad: string }
const LIGHT: Palette = { fill: '#ECECFF', decision: '#FFF3BF', start: '#D3F9D8', end: '#E9ECEF', text: '#1F1F1F', line: '#333333', good: '#277C38', bad: '#C92A2A' }
const DARK: Palette = { fill: '#3B3F6B', decision: '#6B5A1E', start: '#1F4D2B', end: '#3A3D42', text: '#F2F2F2', line: '#D3D3D3', good: '#69DB7C', bad: '#FF8787' }

// The theme row decides when it is a built-in theme, which names its polarity first (`dark`,
// `light-daltonized`). Claude Code's `auto` and a `custom:<slug>` theme name none, and the engine
// exposes no resolved one, so the terminal cs read decides: its theme, else its measured
// background's luminance (the pivot cs's own band uses), else light.
export function paletteFor(theme: unknown, terminal: { theme?: string; bg?: string } = {}): Palette {
  const polarity = typeof theme === 'string' ? /^(dark|light)(-|$)/.exec(theme)?.[1] : undefined
  if (polarity === 'dark') return DARK
  if (polarity === 'light') return LIGHT
  if (terminal.theme === 'dark') return DARK
  if (terminal.theme === 'light') return LIGHT
  const [r, g, b, ...more] = (terminal.bg ?? '').split(';').map(part => (/^\s*\d{1,3}\s*$/.test(part) ? Number(part) : NaN))
  const measured = r !== undefined && g !== undefined && b !== undefined && more.length === 0 && r <= 255 && g <= 255 && b <= 255
  if (measured && 2126 * r + 7152 * g + 722 * b < 1530000) return DARK
  return LIGHT
}

export type Role = 'step' | 'decision' | 'start' | 'end'

// A node's role, by its shape first and else by its place in the flow. A lone node is a step.
export function roleOf(node: GraphNode, graph: Graph): Role {
  if (node.shape === 'diamond' || node.shape === 'hexagon') return 'decision'
  const outgoing = graph.edges.filter(edge => edge.from === node.id).length
  const incoming = graph.edges.filter(edge => edge.to === node.id).length
  // A circle is a terminal: the end when the flow only arrives at it, else the start.
  if (node.shape === 'circle' || node.shape === 'doublecircle') return outgoing === 0 && incoming > 0 ? 'end' : 'start'
  if (outgoing >= 2) return 'decision'
  if (outgoing === 0 && incoming > 0) return 'end'
  if (incoming === 0 && outgoing > 0) return 'start'
  return 'step'
}

export function fillFor(role: Role, palette: Palette): string {
  return role === 'step' ? palette.fill : palette[role]
}

// An edge label that answers a decision takes the answer's colour; any other label the line's.
const GOOD = new Set(['yes', 'y', 'ok', 'pass', 'passed', 'true', 'healthy', 'success', 'done', 'valid'])
const BAD = new Set(['no', 'n', 'fail', 'failed', 'false', 'error', 'degraded', 'invalid', 'timeout', 'reject', 'rejected'])
export function labelColor(text: string, palette: Palette): string {
  const word = text.trim().toLowerCase()
  if (GOOD.has(word)) return palette.good
  if (BAD.has(word)) return palette.bad
  return palette.line
}

// The rows of a block `width` cells wide and `height` tall, the label centred on the middle row.
export function blockRows(label: string, width: number, height: number): string[] {
  const blank = ' '.repeat(width)
  const inner = truncateToWidth(label, width)
  const left = Math.floor((width - cellWidth(inner)) / 2)
  const middle = padToWidth(' '.repeat(left) + inner, width)
  return Array.from({ length: height }, (_, i) => (i === Math.floor(height / 2) ? middle : blank))
}

type Elements = ReturnType<EngineInterface['ui']['resolve']>

// The diagram as coloured blocks and line glyphs.
export function Drawing({ drawn, graph, palette, elements }: { drawn: Layout; graph: Graph; palette: Palette; elements: Elements }) {
  const { Box, Text } = elements
  return (
    <Box width={drawn.width} height={drawn.height} position="relative">
      {drawn.runs.map(run => (
        <Box position="absolute" top={run.y} left={run.x}><Text color={palette.line}>{run.text}</Text></Box>
      ))}
      {drawn.boxes.map(box => {
        const role = roleOf(box.node, graph)
        const fill = box.node.style?.fill ?? fillFor(role, palette)
        const text = box.node.style?.color ?? palette.text
        return (
          <Box position="absolute" top={box.y} left={box.x} width={box.width} height={box.height} flexDirection="column">
            {blockRows(box.node.label, box.width, box.height).map(row => (
              <Text color={text} backgroundColor={fill} bold={role === 'decision'}>{row}</Text>
            ))}
          </Box>
        )
      })}
      {drawn.labels.map(label => (
        <Box position="absolute" top={label.y} left={label.x}><Text italic color={labelColor(label.text, palette)}>{label.text}</Text></Box>
      ))}
    </Box>
  )
}

// A fence the drawing cannot take: its source as it was written, the reason under it.
export function drawFence(source: string, error: string, elements: Elements) {
  const { Box, Text, Code } = elements
  return (
    <Box flexDirection="column">
      <Code source={source} language="mermaid" />
      <Text dimColor>mermaid: {error}</Text>
    </Box>
  )
}

// A reply's text split into prose and mermaid fences, in order.
export function splitReply(text: string): { kind: 'text' | 'mermaid'; body: string }[] {
  const parts: { kind: 'text' | 'mermaid'; body: string }[] = []
  let last = 0
  for (const fence of scanFences(text)) {
    const before = text.slice(last, fence.start)
    if (before.trim()) parts.push({ kind: 'text', body: before })
    parts.push({ kind: 'mermaid', body: fence.body.trim() })
    last = fence.end
  }
  const after = text.slice(last)
  if (after.trim()) parts.push({ kind: 'text', body: after })
  return parts
}

// A reply re-renders on every streaming flush and every width change, and a
// chart near the limits takes over a second to lay out: keep the recent answers.
const FITTED_KEPT = 32
const fittedCache = new Map<string, Fitted | ParseError>()

export function fitSource(source: string, columns: number): Fitted | ParseError {
  const key = `${columns}\n${source}`
  const known = fittedCache.get(key)
  if (known) return known
  const graph = parse(source)
  const fitted = 'error' in graph ? graph : fit(graph, columns)
  fittedCache.set(key, fitted)
  if (fittedCache.size > FITTED_KEPT) fittedCache.delete(fittedCache.keys().next().value as string)
  return fitted
}

// One fence: the chart when it fits, else its source with the reason. Model-written source
// crosses into the parser and layout here; a throw is caught and shown under the fence with
// its message, where uncaught it would make the engine draw the whole reply plain.
export function drawPart(source: string, columns: number, palette: Palette, elements: Elements, fitter: typeof fitSource = fitSource) {
  const { Box } = elements
  let fitted: Fitted | ParseError
  try {
    fitted = fitter(source, columns)
  } catch (thrown) {
    fitted = { error: `could not draw: ${thrown instanceof Error ? thrown.message : String(thrown)}` }
  }
  if ('error' in fitted) return drawFence(source, fitted.error, elements)
  return <Box marginY={1}><Drawing drawn={fitted.drawn} graph={fitted.graph} palette={palette} elements={elements} /></Box>
}

export const register: Register = (on, options) => {
  if (options[OPTION] === false) return

  // The prose around a fence goes back to the engine, so the reply keeps its bullet.
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    if (fencesOf(e.props.text).length === 0) return next(e)
    // Draw each fence inline, in the room the terminal has; one that does not fit stays a fence.
    const elements = $.ui.resolve(e)
    const { Box } = elements
    const theme = (await $.config.list()).find(row => row.key === 'theme')?.value
    const palette = paletteFor(theme, { theme: await $.env.get('CS_TERM_THEME'), bg: await $.env.get('CS_TERM_BG_RGB') })
    const columns = Math.max(20, (e.viewport?.columns ?? 80) - 6)
    const parts = splitReply(e.props.text)
    // The engine draws the prose, the opening bullet on the reply's first part only.
    const prose = await Promise.all(parts.map((part, index) => part.kind === 'text'
      ? next({ ...e, props: { ...e.props, text: part.body, isFirstOfReply: e.props.isFirstOfReply && index === 0 } })
      : undefined))
    return (
      <Box flexDirection="column">
        {parts.map((part, index) => (part.kind === 'text' ? prose[index] : drawPart(part.body, columns, palette, elements)))}
      </Box>
    )
  })
}
