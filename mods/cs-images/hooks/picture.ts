// ABOUTME: Pure picture logic for the cs-images mod: finding image lines in a reply and sizing and packing cells.
// ABOUTME: Holds no engine calls, so its rules are tested without a terminal or a file.

declare global {
  interface Uint8Array {
    toBase64(): string
  }
  interface Uint8ArrayConstructor {
    fromBase64(base64: string): Uint8Array
  }
}

export type ReplyPart = { kind: 'text'; body: string } | { kind: 'image'; path: string; alt: string; line: string }

const IMAGE_LINE = /^!\[([^\]]*)\]\((\/[^)\s]+\.(?:png|jpe?g|gif|heic|webp|tiff?|bmp))\)\s*$/i
const FENCE = /^ {0,3}(`{3,}|~{3,})/

export const SAMPLES_PER_CELL_SIDE = 8
const SAMPLES_PER_CELL = SAMPLES_PER_CELL_SIDE * SAMPLES_PER_CELL_SIDE

type Covers = (x: number, y: number) => boolean
type Glyph = { codePoint: number; covered: Array<{ x: number; y: number }> }

function glyph(codePoint: number, covers: Covers): Glyph {
  const covered: Glyph['covered'] = []
  for (let y = 0; y < SAMPLES_PER_CELL_SIDE; y++) {
    for (let x = 0; x < SAMPLES_PER_CELL_SIDE; x++) {
      if (covers(x, y)) covered.push({ x, y })
    }
  }
  return { codePoint, covered }
}

const MIDDLE = SAMPLES_PER_CELL_SIDE / 2
const upperLeft: Covers = (x, y) => x < MIDDLE && y < MIDDLE
const upperRight: Covers = (x, y) => x >= MIDDLE && y < MIDDLE
const lowerLeft: Covers = (x, y) => x < MIDDLE && y >= MIDDLE
const lowerRight: Covers = (x, y) => x >= MIDDLE && y >= MIDDLE
const anyOf = (...quadrants: Covers[]): Covers => (x, y) => quadrants.some(covers => covers(x, y))

// Every glyph here covers part of a cell, never all or none, so both sides always hold samples.
// Raster takes only BMP code points, which leaves out the sextants at U+1FB00.
const BLOCK_GLYPHS: Glyph[] = [
  glyph(0x2580, (_x, y) => y < MIDDLE),
  glyph(0x2590, x => x >= MIDDLE),
  glyph(0x2594, (_x, y) => y < 1),
  glyph(0x2595, x => x >= SAMPLES_PER_CELL_SIDE - 1),
  ...[1, 2, 3, 4, 5, 6, 7].map(eighths => glyph(0x2580 + eighths, (_x, y) => y >= SAMPLES_PER_CELL_SIDE - eighths)),
  ...[1, 2, 3, 4, 5, 6, 7].map(eighths => glyph(0x2588 + eighths, x => x < SAMPLES_PER_CELL_SIDE - eighths)),
  glyph(0x2596, lowerLeft),
  glyph(0x2597, lowerRight),
  glyph(0x2598, upperLeft),
  glyph(0x2599, anyOf(upperLeft, lowerLeft, lowerRight)),
  glyph(0x259a, anyOf(upperLeft, lowerRight)),
  glyph(0x259b, anyOf(upperLeft, upperRight, lowerLeft)),
  glyph(0x259c, anyOf(upperLeft, upperRight, lowerRight)),
  glyph(0x259d, upperRight),
  glyph(0x259e, anyOf(upperRight, lowerLeft)),
  glyph(0x259f, anyOf(upperRight, lowerLeft, lowerRight)),
]

export type PixelAnswer = 'drawn' | 'refused' | 'ask-again'

// The engine words every "this terminal shows the alt" refusal with this prefix; the other
// refusals (not mounted yet, terminal not asked yet) can change on a later try.
const ALT_REFUSAL = 'the Image draws its alt here'

export function pixelAnswer(answer: { deny?: string; fix?: string }): PixelAnswer {
  if (answer.deny === undefined) return 'drawn'
  return answer.fix !== undefined || answer.deny.startsWith(ALT_REFUSAL) ? 'refused' : 'ask-again'
}

const packed = (red: number, green: number, blue: number) => (red << 16) | (green << 8) | blue

// Samples holds SAMPLES_PER_CELL_SIDE RGB rows and columns per cell. For each cell, the glyph
// that splits its samples into the two most uniform halves wins; each half's mean is its colour.
export function bestGlyphCells(samples: Uint8Array, columns: number, rows: number): string {
  const bytes = new DataView(samples.buffer, samples.byteOffset, samples.byteLength)
  const stride = columns * SAMPLES_PER_CELL_SIDE
  const words = new Uint32Array(columns * rows * 3)
  for (let row = 0; row < rows; row++) {
    for (let column = 0; column < columns; column++) {
      const origin = row * SAMPLES_PER_CELL_SIDE * stride + column * SAMPLES_PER_CELL_SIDE
      let allRed = 0, allGreen = 0, allBlue = 0
      for (let y = 0; y < SAMPLES_PER_CELL_SIDE; y++) {
        for (let x = 0; x < SAMPLES_PER_CELL_SIDE; x++) {
          const at = (origin + y * stride + x) * 3
          allRed += bytes.getUint8(at)
          allGreen += bytes.getUint8(at + 1)
          allBlue += bytes.getUint8(at + 2)
        }
      }
      let bestFit = -1
      for (const candidate of BLOCK_GLYPHS) {
        let red = 0, green = 0, blue = 0
        for (const { x, y } of candidate.covered) {
          const at = (origin + y * stride + x) * 3
          red += bytes.getUint8(at)
          green += bytes.getUint8(at + 1)
          blue += bytes.getUint8(at + 2)
        }
        const count = candidate.covered.length
        const rest = SAMPLES_PER_CELL - count
        const otherRed = allRed - red, otherGreen = allGreen - green, otherBlue = allBlue - blue
        const fit = (red * red + green * green + blue * blue) / count + (otherRed * otherRed + otherGreen * otherGreen + otherBlue * otherBlue) / rest
        if (fit > bestFit) {
          bestFit = fit
          const at = (row * columns + column) * 3
          words[at] = candidate.codePoint
          words[at + 1] = packed(Math.round(red / count), Math.round(green / count), Math.round(blue / count))
          words[at + 2] = packed(Math.round(otherRed / rest), Math.round(otherGreen / rest), Math.round(otherBlue / rest))
        }
      }
    }
  }
  return new Uint8Array(words.buffer).toBase64()
}

export function replyParts(text: string): ReplyPart[] {
  const parts: ReplyPart[] = []
  let prose: string[] = []
  const flush = () => {
    if (prose.join('').trim() !== '') parts.push({ kind: 'text', body: prose.join('\n') })
    prose = []
  }
  let openFence: string | undefined
  for (const line of text.split('\n')) {
    const fence = FENCE.exec(line)?.[1]
    if (openFence === undefined && fence !== undefined) openFence = fence
    else if (openFence !== undefined && fence !== undefined && fence[0] === openFence[0] && fence.length >= openFence.length && line.trim() === fence) openFence = undefined
    else if (openFence === undefined) {
      const found = IMAGE_LINE.exec(line)
      if (found !== null) {
        flush()
        parts.push({ kind: 'image', alt: found[1] ?? '', path: found[2] ?? '', line })
        continue
      }
    }
    prose.push(line)
  }
  flush()
  return parts
}

export function hasImageLine(text: string): boolean {
  return replyParts(text).some(part => part.kind === 'image')
}

export function topDownRgbFromBmp(bmp: Uint8Array, width: number, height: number): Uint8Array {
  const view = new DataView(bmp.buffer, bmp.byteOffset, bmp.byteLength)
  const start = view.getUint32(10, true)
  const fileWidth = view.getInt32(18, true)
  const fileHeight = view.getInt32(22, true)
  const step = view.getUint16(28, true) / 8
  if (fileWidth !== width || Math.abs(fileHeight) !== height || (step !== 3 && step !== 4)) {
    throw new Error(`unexpected BMP: ${fileWidth}x${fileHeight}, ${step * 8} bits, wanted ${width}x${height}`)
  }
  const stride = Math.floor((width * step + 3) / 4) * 4
  const rgb = new Uint8Array(width * height * 3)
  for (let y = 0; y < height; y++) {
    const fileRow = fileHeight < 0 ? y : height - 1 - y
    for (let x = 0; x < width; x++) {
      const from = start + fileRow * stride + x * step
      const to = (y * width + x) * 3
      rgb[to] = view.getUint8(from + 2)
      rgb[to + 1] = view.getUint8(from + 1)
      rgb[to + 2] = view.getUint8(from)
    }
  }
  return rgb
}

// A terminal cell is not square, and nothing reports its shape to a mod. This is the
// measured ratio of iTerm cells with a 1.5 line height; other setups need their own.
const CELL_HEIGHT_PER_WIDTH = 3
const MOST_COLUMNS = 60
const MOST_ROWS = 30

export function gridFor(pixelWidth: number, pixelHeight: number, room: number): { columns: number; rows: number } {
  const columns = Math.min(MOST_COLUMNS, room)
  const rows = Math.max(1, Math.round((columns * pixelHeight) / pixelWidth / CELL_HEIGHT_PER_WIDTH))
  if (rows <= MOST_ROWS) return { columns, rows }
  return { columns: Math.max(1, Math.round((MOST_ROWS * CELL_HEIGHT_PER_WIDTH * pixelWidth) / pixelHeight)), rows: MOST_ROWS }
}
