// ABOUTME: Engine test-kit tests for the cell measurement the drawing aligns on: emoji and CJK two cells, marks none.
// ABOUTME: Each literal is what Claude Code's own measure, Bun.stringWidth with ambiguous characters narrow, gives; test/width.census.ts sweeps the rest.
import { test, expect } from 'claude-code/testing'

import { cellWidth, padToWidth, truncateToWidth } from '../hooks/text'
import { blockRows } from '../hooks/register'

test('an emoji Claude Code lays out two cells wide measures two', () => {
  // Emoji_Presentation=Yes: two cells with no selector.
  expect(cellWidth('✅')).toBe(2) // ✅
  expect(cellWidth('\u{1F680}')).toBe(2) // 🚀
  expect(cellWidth('⭐')).toBe(2) // ⭐
  // Emoji_Presentation=No, so two cells only with U+FE0F after it.
  expect(cellWidth('❤\u{FE0F}')).toBe(2) // ❤️
  expect(cellWidth('❤')).toBe(1) // ❤ as text
  expect(cellWidth('©\u{FE0F}')).toBe(2) // ©️
  expect(cellWidth('©')).toBe(1)
  expect(cellWidth('\u{1F321}')).toBe(1) // 🌡 as text
  expect(cellWidth('\u{1F321}\u{FE0F}')).toBe(2)
  // U+FE0E asks for text presentation, but the engine's measure keeps an Emoji_Presentation
  // base two cells; a text-presentation base stays one.
  expect(cellWidth('✅\u{FE0E}')).toBe(2)
  expect(cellWidth('\u{231A}\u{FE0E}')).toBe(2) // ⌚
  expect(cellWidth('❤\u{FE0E}')).toBe(1)
  // A regional-indicator pair is one flag; one alone is one cell.
  expect(cellWidth('\u{1F1EF}\u{1F1F5}')).toBe(2) // 🇯🇵
  expect(cellWidth('\u{1F1EF}')).toBe(1)
  // A ZWJ family, a ZWJ flag and a skin-toned hand are one glyph each.
  expect(cellWidth('\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}')).toBe(2)
  expect(cellWidth('\u{1F3F3}\u{200D}\u{1F308}')).toBe(2) // 🏳‍🌈
  expect(cellWidth('\u{1F44D}\u{1F3FD}')).toBe(2)
  // A keycap needs U+20E3; a digit or `#` with U+FE0F alone stays one cell.
  expect(cellWidth('1\u{FE0F}\u{20E3}')).toBe(2) // 1️⃣
  expect(cellWidth('1\u{20E3}')).toBe(2)
  expect(cellWidth('1\u{FE0F}')).toBe(1)
  expect(cellWidth('#\u{FE0F}')).toBe(1)
})

test('CJK and the other East Asian wide scripts are two cells, a combining mark none, plain text one each', () => {
  expect(cellWidth('中')).toBe(2)
  expect(cellWidth('中\u{FE0E}')).toBe(2)
  expect(cellWidth('界界')).toBe(4)
  expect(cellWidth('\u{1F200}')).toBe(2) // 🈀 squared hiragana
  expect(cellWidth('\u{17000}')).toBe(2) // Tangut
  expect(cellWidth('\u{1100}\u{1161}')).toBe(2) // a Hangul syllable spelled in jamo
  expect(cellWidth('é')).toBe(1)
  expect(cellWidth('\u{301}')).toBe(0)
  // A visarga, a spacing mark the engine keeps, takes its own cell; a virama none.
  expect(cellWidth('\u{903}')).toBe(1)
  expect(cellWidth('\u{915}\u{94D}\u{937}')).toBe(2) // क्ष
  expect(cellWidth('\u{200B}')).toBe(0)
  expect(cellWidth('abc')).toBe(3)
  expect(cellWidth('')).toBe(0)
  expect(cellWidth('ok ✅')).toBe(5)
})

// Bun's measure gives no cell to most vowel signs of the Indic scripts, spacing marks (Mc) drawn
// beside the consonant they follow, so a Hindi or Bengali label is narrower than its code points.
test('an Indic word measures the cells the engine measures it in', () => {
  expect(cellWidth('का')).toBe(1)
  expect(cellWidth('हिन्दी')).toBe(3)
  expect(cellWidth('বাংলা')).toBe(2)
  expect(cellWidth('मराठी डेटा')).toBe(6)
  // Three cells of label in a twelve-cell block: four of air before it, five after.
  expect(blockRows('हिन्दी', 12, 3)).toEqual(['            ', '    हिन्दी     ', '            '])
})

test('a block row with an emoji label is padded to the block width in cells', () => {
  // `ok ✅` is five cells; in a nine-cell block two cells of air sit on each side.
  expect(blockRows('ok ✅', 9, 3)).toEqual(['         ', '  ok ✅  ', '         '])
  // With U+FE0E the engine still lays ✅ out two cells, so the row keeps the same air.
  expect(blockRows('ok ✅\u{FE0E}', 9, 3)).toEqual(['         ', '  ok ✅\u{FE0E}  ', '         '])
  expect(padToWidth('\u{1F680}', 4)).toBe('\u{1F680}  ')
  expect(truncateToWidth('go \u{1F680}\u{1F680}', 6)).toBe('go \u{1F680}…')
})
