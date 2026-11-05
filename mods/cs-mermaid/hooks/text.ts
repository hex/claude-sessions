// ABOUTME: Terminal text measurement for the mermaid drawing, in the cells Claude Code lays text out in: wide CJK and emoji two, marks none.
// ABOUTME: Pads and truncates strings to a cell width.
// Claude Code measures text with Bun.stringWidth(text, { ambiguousIsNarrow: true }), and a hooks
// module has no Bun, so this measures by the same rules: each code point by its East Asian Width
// and General Category, summed over a grapheme, and an emoji sequence two cells whole.
// test/width.census.ts holds it to Bun over every code point and the emoji sequences.

// East_Asian_Width W or F (Unicode 17.0): two cells. An ambiguous character is one.
const WIDE = /[\u{1100}-\u{115F}\u{231A}-\u{231B}\u{2329}-\u{232A}\u{23E9}-\u{23EC}\u{23F0}\u{23F3}\u{25FD}-\u{25FE}\u{2614}-\u{2615}\u{2630}-\u{2637}\u{2648}-\u{2653}\u{267F}\u{268A}-\u{268F}\u{2693}\u{26A1}\u{26AA}-\u{26AB}\u{26BD}-\u{26BE}\u{26C4}-\u{26C5}\u{26CE}\u{26D4}\u{26EA}\u{26F2}-\u{26F3}\u{26F5}\u{26FA}\u{26FD}\u{2705}\u{270A}-\u{270B}\u{2728}\u{274C}\u{274E}\u{2753}-\u{2755}\u{2757}\u{2795}-\u{2797}\u{27B0}\u{27BF}\u{2B1B}-\u{2B1C}\u{2B50}\u{2B55}\u{2E80}-\u{2E99}\u{2E9B}-\u{2EF3}\u{2F00}-\u{2FD5}\u{2FF0}-\u{303E}\u{3041}-\u{3096}\u{3099}-\u{30FF}\u{3105}-\u{312F}\u{3131}-\u{318E}\u{3190}-\u{31E5}\u{31EF}-\u{321E}\u{3220}-\u{3247}\u{3250}-\u{A48C}\u{A490}-\u{A4C6}\u{A960}-\u{A97C}\u{AC00}-\u{D7A3}\u{F900}-\u{FAFF}\u{FE10}-\u{FE19}\u{FE30}-\u{FE52}\u{FE54}-\u{FE66}\u{FE68}-\u{FE6B}\u{FF01}-\u{FF60}\u{FFE0}-\u{FFE6}\u{16FE0}-\u{16FE4}\u{16FF0}-\u{16FF6}\u{17000}-\u{18CD5}\u{18CFF}-\u{18D1E}\u{18D80}-\u{18DF2}\u{1AFF0}-\u{1AFF3}\u{1AFF5}-\u{1AFFB}\u{1AFFD}-\u{1AFFE}\u{1B000}-\u{1B122}\u{1B132}\u{1B150}-\u{1B152}\u{1B155}\u{1B164}-\u{1B167}\u{1B170}-\u{1B2FB}\u{1D300}-\u{1D356}\u{1D360}-\u{1D376}\u{1F004}\u{1F0CF}\u{1F18E}\u{1F191}-\u{1F19A}\u{1F200}-\u{1F202}\u{1F210}-\u{1F23B}\u{1F240}-\u{1F248}\u{1F250}-\u{1F251}\u{1F260}-\u{1F265}\u{1F300}-\u{1F320}\u{1F32D}-\u{1F335}\u{1F337}-\u{1F37C}\u{1F37E}-\u{1F393}\u{1F3A0}-\u{1F3CA}\u{1F3CF}-\u{1F3D3}\u{1F3E0}-\u{1F3F0}\u{1F3F4}\u{1F3F8}-\u{1F43E}\u{1F440}\u{1F442}-\u{1F4FC}\u{1F4FF}-\u{1F53D}\u{1F54B}-\u{1F54E}\u{1F550}-\u{1F567}\u{1F57A}\u{1F595}-\u{1F596}\u{1F5A4}\u{1F5FB}-\u{1F64F}\u{1F680}-\u{1F6C5}\u{1F6CC}\u{1F6D0}-\u{1F6D2}\u{1F6D5}-\u{1F6D8}\u{1F6DC}-\u{1F6DF}\u{1F6EB}-\u{1F6EC}\u{1F6F4}-\u{1F6FC}\u{1F7E0}-\u{1F7EB}\u{1F7F0}\u{1F90C}-\u{1F93A}\u{1F93C}-\u{1F945}\u{1F947}-\u{1F9FF}\u{1FA70}-\u{1FA7C}\u{1FA80}-\u{1FA8A}\u{1FA8E}-\u{1FAC6}\u{1FAC8}\u{1FACD}-\u{1FADC}\u{1FADF}-\u{1FAEA}\u{1FAEF}-\u{1FAF8}\u{20000}-\u{2FFFD}\u{30000}-\u{3FFFD}]/u
// No cells: nonspacing and enclosing marks, controls, format characters, and the Hangul jamo
// vowels and finals that join a leading consonant into one syllable.
const ZERO = /[\p{Mn}\p{Me}\p{Cc}\p{Cf}\u{1160}-\u{11FF}\u{D7B0}-\u{D7FF}]/u
// The format characters the engine still gives a cell: currency marks set above Arabic digits,
// interlinear annotation marks, Kaithi number signs and Egyptian hieroglyph format controls.
const SHOWN_FORMAT = /[\u{890}\u{891}\u{FFF9}-\u{FFFB}\u{110BD}\u{110CD}\u{13430}-\u{1343F}]/u

function pointCells(point: string): number {
  if (SHOWN_FORMAT.test(point)) return 1
  if (ZERO.test(point)) return 0
  return WIDE.test(point) ? 2 : 1
}

// An emoji sequence is two cells whatever it holds: a keycap (anything before U+20E3), an
// Emoji_Presentation character with either variation selector (U+FE0E leaves it two cells, and
// lifts a lone regional indicator to two), or a pictograph with U+FE0F, a skin tone, or a ZWJ
// joining the next one. After ©, ®, 〰, 〽, ㊗ or ㊙ a bare ZWJ joins nothing: those sum.
const KEYCAP = '\u{20E3}'
const ZWJ = '\u{200D}'
const SELECTED = /^\p{Emoji_Presentation}[\u{FE0E}\u{FE0F}]/u
const PICTOGRAPH = /^\p{Extended_Pictographic}/u
const PRESENTED = /[\u{FE0F}\p{Emoji_Modifier}]/u
const UNJOINED = /^[\u{A9}\u{AE}\u{3030}\u{303D}\u{3297}\u{3299}]/u

function isEmojiSequence(grapheme: string): boolean {
  if (grapheme.includes(KEYCAP) || SELECTED.test(grapheme)) return true
  if (!PICTOGRAPH.test(grapheme)) return false
  return PRESENTED.test(grapheme) || (grapheme.includes(ZWJ) && !UNJOINED.test(grapheme))
}

// One segmenter for every measurement: layout measures tens of thousands of labels and runs.
const Segmenter = (Intl as { Segmenter?: new (locale: string, options: { granularity: 'grapheme' }) => { segment(input: string): Iterable<{ segment: string }> } }).Segmenter
const segmenter = Segmenter ? new Segmenter('en', { granularity: 'grapheme' }) : undefined

export function graphemes(text: string): string[] {
  if (!segmenter) return Array.from(text)
  return Array.from(segmenter.segment(text), piece => piece.segment)
}

function cellsOf(grapheme: string): number {
  if (isEmojiSequence(grapheme)) return 2
  let cells = 0
  for (const point of grapheme) cells += pointCells(point)
  return cells
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
