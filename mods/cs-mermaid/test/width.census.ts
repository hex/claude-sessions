// ABOUTME: Census of the mod's cell measurement against Bun.stringWidth(text, { ambiguousIsNarrow: true }), the measure Claude Code lays text out by.
// ABOUTME: Run under bun by tests/test_mod_mermaid.sh (a hooks module has no Bun); prints one summary line and fails on any difference it does not know.
import { cellWidth } from '../hooks/text'

type StringWidth = (text: string, options: { ambiguousIsNarrow: boolean }) => number
// Bun is this script's runtime global; the engine kit never loads the file (no `.test.` in its name).
const { stringWidth } = (globalThis as unknown as { Bun: { stringWidth: StringWidth } }).Bun
const engine = (text: string) => stringWidth(text, { ambiguousIsNarrow: true })

const ZWJ = '\u{200D}'
const TEXT_STYLE = '\u{FE0E}'
const EMOJI_STYLE = '\u{FE0F}'
const KEYCAP = '\u{20E3}'
const CHECK = '\u{2705}'

function codePoints(pattern?: RegExp): string[] {
  const out: string[] = []
  for (let point = 0; point <= 0x10FFFF; point++) {
    if (point >= 0xD800 && point <= 0xDFFF) continue
    const char = String.fromCodePoint(point)
    if (!pattern || pattern.test(char)) out.push(char)
  }
  return out
}

const emoji = codePoints(/^\p{Emoji}$/u)
const pictographs = codePoints(/^\p{Extended_Pictographic}$/u).filter(char => !/^\p{Cn}$/u.test(char))
const regional = codePoints(/^\p{Regional_Indicator}$/u)
const modifiers = codePoints(/^\p{Emoji_Modifier}$/u)
const keycapBases = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '#', '*']

const sets: [string, string[]][] = [
  ['code points', codePoints()],
  ['emoji+FE0E', emoji.map(char => char + TEXT_STYLE)],
  ['emoji+FE0F', emoji.map(char => char + EMOJI_STYLE)],
  ['regional', [...regional, ...regional.flatMap(first => regional.map(second => first + second))]],
  ['keycaps', keycapBases.flatMap(base => ['', EMOJI_STYLE, TEXT_STYLE].flatMap(style => [base + style, base + style + KEYCAP]))],
  ['skin tones', codePoints(/^\p{Emoji_Modifier_Base}$/u).flatMap(base => modifiers.map(modifier => base + modifier)).concat(modifiers.map(modifier => 'a' + modifier))],
  ['zwj', pictographs.flatMap(base => [base + ZWJ + CHECK, base + EMOJI_STYLE + ZWJ + CHECK, base + ZWJ])],
  ['labels', [
    'ok \u{2705}\u{FE0E}', '  ok \u{2705}\u{FE0E}  ', '\u{2705} done', '\u{1F680} ship', '\u{4E2D}\u{6587} label', 'na\u{EF}ve caf\u{E9}',
    'v1 \u{2192} v2', '\u{26A0}\u{FE0F} warn', '1\u{FE0F}\u{20E3} first', '\u{1F1EF}\u{1F1F5} Japan', '\u{1F44D}\u{1F3FD} ok',
    '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} family', '\u{1F3F3}\u{FE0F}\u{200D}\u{1F308} pride',
    '\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F} England', '\u{D55C}\u{AD6D}\u{C5B4}', '\u{1100}\u{1161}\u{11A8}',
  ]],
]

// Where Bun's own tables leave the Unicode properties this measure follows. Each class measures
// wider than Bun, never narrower, so a block sized by it still holds the label the engine draws.
const INDIC = /^[\p{sc=Deva}\p{sc=Beng}\p{sc=Guru}\p{sc=Gujr}\p{sc=Orya}\p{sc=Taml}\p{sc=Telu}\p{sc=Knda}\p{sc=Mlym}]$/u
const known: [string, (char: string, ours: number, bun: number) => boolean][] = [
  ['Indic signs', (char, ours, bun) => INDIC.test(char) && bun === 0 && ours === 1],
  ['unassigned', (char, ours, bun) => /^\p{Cn}$/u.test(char) && ours > bun],
]

const counts = new Map(known.map(([name]) => [name, 0]))
const differ: string[] = []
for (const [, strings] of sets) for (const text of strings) {
  const ours = cellWidth(text)
  const bun = engine(text)
  if (ours === bun) continue
  const kind = known.find(([, matches]) => matches(text, ours, bun))
  if (kind) counts.set(kind[0], counts.get(kind[0])! + 1)
  else differ.push(`${[...text].map(char => 'U+' + char.codePointAt(0)!.toString(16).toUpperCase().padStart(4, '0')).join(' ')}: ours ${ours}, bun ${bun}`)
}

for (const line of differ.slice(0, 40)) console.log(line)
const sizes = sets.map(([name, strings]) => `${name} ${strings.length}`).join(', ')
const kinds = known.map(([name]) => `${name} ${counts.get(name)}`).join(', ')
console.log(`census: ${sizes}; differ ${differ.length}; known wider: ${kinds}`)
if (differ.length > 0) throw new Error(`${differ.length} strings measure other than Bun.stringWidth`)
