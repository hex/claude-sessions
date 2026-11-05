// ABOUTME: Engine test-kit tests for the cell measurement the drawing aligns on: emoji and CJK two cells, marks none.
// ABOUTME: Pins the Unicode rules a terminal draws by: Emoji_Presentation, a base with U+FE0F, a flag pair, a base with U+FE0E.
import { test, expect } from 'claude-code/testing'

import { cellWidth, padToWidth, truncateToWidth } from '../hooks/text'
import { blockRows } from '../hooks/register'

test('an emoji a terminal draws two cells wide measures two', () => {
  // Emoji_Presentation=Yes: drawn wide with no selector.
  expect(cellWidth('✅')).toBe(2) // ✅
  expect(cellWidth('\u{1F680}')).toBe(2) // 🚀
  expect(cellWidth('⭐')).toBe(2) // ⭐
  // Emoji_Presentation=No, so wide only with U+FE0F after it.
  expect(cellWidth('❤️')).toBe(2) // ❤️
  expect(cellWidth('❤')).toBe(1) // ❤ as text
  expect(cellWidth('©️')).toBe(2) // ©️
  expect(cellWidth('©')).toBe(1)
  // U+FE0E asks for text presentation: one cell even on an Emoji_Presentation base.
  expect(cellWidth('✅︎')).toBe(1)
  // A regional-indicator pair is one flag.
  expect(cellWidth('\u{1F1EF}\u{1F1F5}')).toBe(2) // 🇯🇵
  // A ZWJ family and a skin-toned hand are one glyph each.
  expect(cellWidth('\u{1F468}‍\u{1F469}‍\u{1F467}')).toBe(2)
  expect(cellWidth('\u{1F44D}\u{1F3FD}')).toBe(2)
  // A keycap: a digit, U+FE0F and the enclosing keycap mark.
  expect(cellWidth('1️⃣')).toBe(2)
})

test('CJK stays two cells, a combining mark none, plain text one each', () => {
  expect(cellWidth('中')).toBe(2)
  expect(cellWidth('界界')).toBe(4)
  expect(cellWidth('é')).toBe(1)
  expect(cellWidth('́')).toBe(0)
  expect(cellWidth('abc')).toBe(3)
  expect(cellWidth('')).toBe(0)
  expect(cellWidth('ok ✅')).toBe(5)
})

test('a block row with an emoji label is padded to the block width in cells', () => {
  // `ok ✅` is five cells; in a nine-cell block two cells of air sit on each side.
  expect(blockRows('ok ✅', 9, 3)).toEqual(['         ', '  ok ✅  ', '         '])
  expect(padToWidth('\u{1F680}', 4)).toBe('\u{1F680}  ')
  expect(truncateToWidth('go \u{1F680}\u{1F680}', 6)).toBe('go \u{1F680}…')
})
