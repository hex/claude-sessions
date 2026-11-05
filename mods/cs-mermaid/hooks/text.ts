// ABOUTME: Terminal text measurement for the mermaid drawing: wide CJK and emoji count two cells, combining marks none.
// ABOUTME: Pads and truncates strings to a cell width.
// Terminal text measurement: a cell count, not a UTF-16 length.

const WIDE = /[ᄀ-ᅟ⺀-〾ぁ-㏿㐀-䶿一-鿿ꀀ-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]|[\u{1F300}-\u{1F64F}]|[\u{1F900}-\u{1F9FF}]|[\u{20000}-\u{3FFFD}]/u
const ZERO = /^[\p{M}​-‏️]+$/u

export function graphemes(text: string): string[] {
  const Segmenter = (Intl as { Segmenter?: new (locale: string, options: { granularity: 'grapheme' }) => { segment(input: string): Iterable<{ segment: string }> } }).Segmenter
  if (!Segmenter) return Array.from(text)
  return Array.from(new Segmenter('en', { granularity: 'grapheme' }).segment(text), piece => piece.segment)
}

// Emoji a terminal draws two cells wide: one presented as emoji by default, an emoji base
// that U+FE0F asks to present as emoji (❤️, ©️, a keycap), or a regional-indicator pair
// (a flag). U+FE0E asks an emoji for text presentation: one cell.
const EMOJI_WIDE = /^(?:\p{Emoji_Presentation}|\p{Emoji}️|\p{Regional_Indicator}\p{Regional_Indicator})/u

function cellsOf(grapheme: string): number {
  if (ZERO.test(grapheme)) return 0
  if (EMOJI_WIDE.test(grapheme)) return grapheme.includes('︎') ? 1 : 2
  const base = grapheme.replace(/[\p{M}​-‏️]/gu, '')
  return WIDE.test(base) ? 2 : 1
}

export function cellWidth(text: string): number {
  let width = 0
  for (const grapheme of graphemes(text)) width += cellsOf(grapheme)
  return width
}

// The longest prefix at most `width` cells wide, ending in `…` when anything was cut.
export function truncateToWidth(text: string, width: number): string {
  if (cellWidth(text) <= width) return text
  if (width <= 0) return ''
  let out = ''
  let used = 0
  for (const grapheme of graphemes(text)) {
    const cells = cellsOf(grapheme)
    if (used + cells > width - 1) break
    out += grapheme
    used += cells
  }
  return out + '…'
}

export function padToWidth(text: string, width: number): string {
  return text + ' '.repeat(Math.max(0, width - cellWidth(text)))
}
