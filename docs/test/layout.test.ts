// ABOUTME: Unit tests for the mod band layout engine in docs/mods-layout.js.
// ABOUTME: Covers Text runs, Box flex in both directions, nesting, borders and the shipped rotate band as an oracle.
import { test, expect } from 'bun:test'
const { layout, toText } = require('../mods-layout.js')

const T = (props: any, s: string) => ({ type: 'Text', props, children: [s] })

test('a Text node lays out as one row carrying its style', () => {
  const g = layout(T({ color: 'claude', bold: true }, 'rotate'), 40)
  expect(toText(g)).toEqual(['rotate'])
  expect(g.rows[0][0].st.color).toBe('claude')
  expect(g.rows[0][0].st.bold).toBe(true)
})

const B = (props: any, ...children: any[]) => ({ type: 'Box', props, children })

test('a row Box places its children side by side with gap cells between', () => {
  const g = layout(B({ gap: 2 }, T({}, 'ab'), T({}, 'cd')), 40)
  expect(toText(g)).toEqual(['ab  cd'])
  expect(g.w).toBe(6)
})

test('a column Box stacks its children and pads them to the widest', () => {
  const g = layout(B({ flexDirection: 'column' }, T({}, 'one'), T({}, 'three')), 40)
  expect(toText(g)).toEqual(['one  ', 'three'])
})

test('a row Box top-aligns children of different heights', () => {
  // The width-2 Box is what makes "abcd" wrap; the row itself is roomy.
  const g = layout(B({ gap: 1 }, B({ width: 2 }, T({ wrap: 'wrap' }, 'abcd')), T({}, 'x')), 40)
  expect(toText(g)).toEqual(['ab x', 'cd  '])
})

test('an explicit width holds a Box open, and clips it when overflow is hidden', () => {
  expect(toText(layout(B({ width: 8 }, T({}, 'ab')), 40))).toEqual(['ab      '])
  expect(toText(layout(B({ width: 3, overflow: 'hidden' }, T({ wrap: 'end' }, 'abcdef')), 40))).toEqual(['ab…'])
})

test('padding and a border grow the Box around its content', () => {
  const g = layout(B({ borderStyle: 'round', paddingX: 1 }, T({}, 'hi')), 40)
  expect(toText(g)).toEqual(['╭────╮', '│ hi │', '╰────╯'])
})

test('a Box nests inside a Box', () => {
  const g = layout(B({ flexDirection: 'column' }, B({ gap: 1 }, T({}, 'a'), T({}, 'b')), T({}, 'cc')), 40)
  expect(toText(g)).toEqual(['a b', 'cc '])
})

test('justifyContent spreads the slack inside a fixed width', () => {
  const row = (just: string) => toText(layout(B({ width: 9, justifyContent: just }, T({}, 'ab'), T({}, 'cd')), 40))[0]
  expect(row('flex-start')).toBe('abcd     ')
  expect(row('center')).toBe('  abcd   ')
  expect(row('flex-end')).toBe('     abcd')
  expect(row('space-between')).toBe('ab     cd')
})

test('flexGrow takes the slack before justifyContent sees it', () => {
  const g = layout(B({ width: 10, justifyContent: 'flex-end' }, T({ flexGrow: 1 }, 'ab'), T({}, 'cd')), 40)
  expect(toText(g)).toEqual(['ab      cd'])
})

test('alignItems places a short child against a taller sibling', () => {
  const tall = B({ flexDirection: 'column' }, T({}, 'x'), T({}, 'y'), T({}, 'z'))
  expect(toText(layout(B({ gap: 1, alignItems: 'flex-end' }, tall, T({}, 'o')), 40))).toEqual(['x  ', 'y  ', 'z o'])
  expect(toText(layout(B({ gap: 1, alignItems: 'center' }, tall, T({}, 'o')), 40))).toEqual(['x  ', 'y o', 'z  '])
})

test('display none draws nothing and takes no room', () => {
  expect(toText(layout(B({}, B({ display: 'none' }, T({}, 'gone')), T({}, 'here')), 40))).toEqual(['here'])
})

test('a Text nested in a Text is one inline run per child, each with its own style', () => {
  const g = layout({ type: 'Text', props: {}, children: [T({ dimColor: true }, '  ·  '), T({ color: 'claude', bold: true }, '47%')] }, 40)
  expect(toText(g)).toEqual(['  ·  47%'])
  expect(g.rows[0][0].st.dim).toBe(true)
  expect(g.rows[0][5].st.color).toBe('claude')
})

// The engine drops a whole band that nests a block element in a Text, and it
// does so silently — the editor refuses the nest instead.
test('validate names the nests the engine refuses', () => {
  const { validate } = require('../mods-layout.js')
  expect(validate({ type: 'Text', props: {}, children: [{ type: 'Button', props: { label: 'x' }, children: [] }] }))
    .toEqual(['A Button inside a Text: the engine drops the whole tree.'])
  expect(validate(B({}, T({}, 'ok')))).toEqual([])
  expect(validate(B({ hover: { color: 'claude' } }, T({}, 'x'))))
    .toEqual(['hover on a Box needs a key or a hover.scope.'])
})

// The oracle: the band the shipped mod draws (percent 47, nothing armed),
// read off mods/cs-rotate/hooks/register.tsx and hand-worked, not recomputed.
test('the shipped rotate band lays out as the mod draws it', () => {
  const band = B({ borderStyle: 'round', borderColor: 'claude', paddingX: 1, key: 'cs-rotate-band' },
    T({ color: 'coral', bold: true }, '✳ '),
    { type: 'Button', props: { key: 'cs-rotate', hotkey: '1', plain: true, label: 'rotate this conversation' }, children: [] },
    T({ dimColor: true }, '  ·  '),
    { type: 'Button', props: { key: 'cs-wrap', hotkey: '2', plain: true, label: 'wrap up this session' }, children: [] },
    { type: 'Text', props: {}, children: [
      T({ dimColor: true }, '  ·  '),
      T({ color: 'warning' }, '█'.repeat(5)),
      T({ dimColor: true }, '░'.repeat(5)),
      T({ color: 'warning', bold: true }, ' 47%'),
    ] },
  )
  const content = '✳ 1: rotate this conversation  ·  2: wrap up this session  ·  '
    + '█████░░░░░ 47%'
  expect(content.length).toBe(76)
  expect(toText(layout(band, 100))).toEqual([
    '╭' + '─'.repeat(78) + '╮',
    '│ ' + content + ' │',
    '╰' + '─'.repeat(78) + '╯',
  ])
})

test('toJsx emits the tree the lab prints, palette keys quoted and raw inks braced', () => {
  const { toJsx } = require('../mods-layout.js')
  const tree = B({ borderStyle: 'round', borderColor: 'CORAL', paddingX: 1, key: 'band' },
    T({ color: 'claude', bold: true }, '✳ '),
    { type: 'Button', props: { key: 'go', hotkey: '1', plain: true, label: 'rotate' }, children: [] })
  expect(toJsx(tree)).toBe(
    '<Box key="band" borderStyle="round" borderColor={CORAL} paddingX={1}>\n'
    + '  <Text color="claude" bold>{\'\\u2733 \'}</Text>\n'
    + '  <Button key="go" hotkey="1" plain label="rotate" onPress={press} />\n'
    + '</Box>')
})

test('toJsx keeps plain ASCII text unescaped and nests inline Text on one line', () => {
  const { toJsx } = require('../mods-layout.js')
  expect(toJsx(T({ dimColor: true }, 'ctx 47%'))).toBe('<Text dimColor>ctx 47%</Text>')
  expect(toJsx({ type: 'Text', props: {}, children: [T({ dimColor: true }, 'a'), T({ bold: true }, 'b')] }))
    .toBe('<Text><Text dimColor>a</Text><Text bold>b</Text></Text>')
})
