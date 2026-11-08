// ABOUTME: Checks cs-images reply parsing, cell proportions, glyph colours and terminal answers.
// ABOUTME: Uses exact expected picture shapes and packed colour values.
import { expect, test } from 'claude-code/testing'

import { bestGlyphCells, cellHeightRatioFor, gridFor, pixelAnswer, replyParts } from '../hooks/picture'

test('a line inside a code fence stays text', () => {
  const reply = 'Write it like this:\n```\n![owl](/tmp/owl.png)\n```\nDone.'
  expect(replyParts(reply)).toEqual([{ kind: 'text', body: reply }])
})

test('only an absolute path to a picture file is drawn', () => {
  for (const line of ['![a](pics/owl.png)', '![a](https://example.com/owl.png)', '![a](/tmp/notes.txt)', '![a](/tmp/script.sh)', 'See ![a](/tmp/owl.png) here']) {
    expect(replyParts(line)).toEqual([{ kind: 'text', body: line }])
  }
  expect(replyParts('![a](/tmp/Owl.HEIC)')).toEqual([{ kind: 'image', alt: 'a', path: '/tmp/Owl.HEIC', line: '![a](/tmp/Owl.HEIC)' }])
})

test('the grid keeps the picture\'s proportions in cells three times as tall as wide', () => {
  expect(gridFor(512, 512, 200, 3)).toEqual({ columns: 60, rows: 20 })
  expect(gridFor(512, 512, 30, 3)).toEqual({ columns: 30, rows: 10 })
  expect(gridFor(100, 1000, 200, 3)).toEqual({ columns: 9, rows: 30 })
  expect(gridFor(2000, 100, 200, 3)).toEqual({ columns: 60, rows: 1 })
})

test('the grid uses the configured cell height ratio', () => {
  expect(gridFor(512, 512, 200, 2)).toEqual({ columns: 60, rows: 30 })
  expect(gridFor(512, 512, 200, 3)).toEqual({ columns: 60, rows: 20 })
  expect(gridFor(100, 1000, 200, 2)).toEqual({ columns: 6, rows: 30 })
})

test('invalid cell height ratios use 2, including NaN before config serialization', () => {
  for (const value of [0, 9, NaN, Infinity, -Infinity, '3', null]) {
    expect(cellHeightRatioFor(value)).toBe(2)
    expect(gridFor(512, 512, 200, cellHeightRatioFor(value))).toEqual({ columns: 60, rows: 30 })
  }
  for (const value of [1, 2, 3, 5]) expect(cellHeightRatioFor(value)).toBe(value)
})

function cellWords(paint: (x: number, y: number) => number): number[] {
  const samples = new Uint8Array(8 * 8 * 3)
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      const at = (y * 8 + x) * 3
      const color = paint(x, y)
      samples[at] = color >> 16
      samples[at + 1] = (color >> 8) & 0xff
      samples[at + 2] = color & 0xff
    }
  }
  return [...new Uint32Array(Uint8Array.fromBase64(bestGlyphCells(samples, 1, 1)).buffer)]
}

test('a cell takes the block glyph that matches its edge, with the two colours on each side', () => {
  expect(cellWords((x) => (x < 2 ? 0xff0000 : 0x0000ff))).toEqual([0x258e, 0xff0000, 0x0000ff])
  expect(cellWords((_x, y) => (y >= 5 ? 0x00ff00 : 0x102030))).toEqual([0x2583, 0x00ff00, 0x102030])
  expect(cellWords((x, y) => ((x < 4) === (y < 4) ? 0x00ff00 : 0x000000))).toEqual([0x259a, 0x00ff00, 0x000000])
})

test('a one-colour cell uses that colour on both sides', () => {
  expect(cellWords(() => 0xabcdef)).toEqual([0x2580, 0xabcdef, 0xabcdef])
})

test('a blit answer says whether this terminal draws pixels', () => {
  expect(pixelAnswer({})).toBe('drawn')
  expect(pixelAnswer({ deny: 'the Image draws its alt here: tmux does not know which terminal is outside it' })).toBe('refused')
  expect(pixelAnswer({ deny: 'tmux holds images back', fix: 'tmux-passthrough' })).toBe('refused')
  expect(pixelAnswer({ deny: 'the terminal has not yet said whether it reads files on this machine; asked now, blit again' })).toBe('ask-again')
  expect(pixelAnswer({ deny: 'nothing of this plugin is mounted there' })).toBe('ask-again')
})
