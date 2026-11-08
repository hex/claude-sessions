// ABOUTME: cs-images: where a reply has a line like ![alt](/absolute/path.png), draws the picture in the chat.
// ABOUTME: Tries real pixels once per session and falls back to best-fitting block glyphs, which also work under tmux -CC.
import type { EngineInterface, Register } from 'claude-code'

import { bestGlyphCells, cellHeightRatioFor, gridFor, hasImageLine, pixelAnswer, replyParts, SAMPLES_PER_CELL_SIDE, topDownRgbFromBmp } from './picture'

type Grid = { columns: number; rows: number; longestEdge: number }
type Cells = { columns: number; rows: number; cells: string }
type Pixels = { columns: number; rows: number; png: string }

const SIPS_TIMEOUT_MS = 8000
const MOST_REMEMBERED = 64
const MOST_PIXELS_REMEMBERED = 16
const MOST_DECODE_ATTEMPTS = 3
const LONGEST_PNG_EDGE = 800
const MOST_PNG_BYTES = 2 * 1024 * 1024
const ASK_TERMINAL_AFTER_MS = 100
const MOST_TERMINAL_ASKS = 20

const allCells = new Map<string, Promise<Cells | string>>()
const allPixels = new Map<string, Promise<Pixels | string>>()

// untried: no Image has been asked about yet. asking: one Image is mounted and being asked about.
let terminalDrawsPixels: 'untried' | 'asking' | 'yes' | 'no' = 'untried'
let sipsAvailable = false
let temporaryDirectory = '/tmp/'

async function gridOf($: EngineInterface, path: string, room: number, cellHeightRatio: number): Promise<Grid | string> {
  const size = await $.process.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path], { timeoutMs: SIPS_TIMEOUT_MS })
  const pixelWidth = Number(/pixelWidth: (\d+)/.exec(size.stdout)?.[1])
  const pixelHeight = Number(/pixelHeight: (\d+)/.exec(size.stdout)?.[1])
  if (size.exitCode !== 0 || !(pixelWidth > 0) || !(pixelHeight > 0)) return `sips cannot read it: ${size.stderr.trim() || size.stdout.trim()}`
  return { ...gridFor(pixelWidth, pixelHeight, room, cellHeightRatio), longestEdge: Math.max(pixelWidth, pixelHeight) }
}

async function converted<T>($: EngineInterface, path: string, format: 'bmp' | 'png', resize: string[], use: (out: string) => Promise<T>): Promise<T | { failure: string }> {
  const out = `${temporaryDirectory}cs-images-tmp-${crypto.randomUUID()}.${format}`
  try {
    const made = await $.process.run(['sips', '-s', 'format', format, ...resize, path, '--out', out], { timeoutMs: SIPS_TIMEOUT_MS })
    if (made.exitCode !== 0) return { failure: `sips cannot convert it: ${made.stderr.trim() || made.stdout.trim()}` }
    return await use(out)
  } finally {
    await $.process.run(['rm', '-f', out])
  }
}

async function decodeCells($: EngineInterface, path: string, room: number, cellHeightRatio: number): Promise<Cells | string> {
  const picture = await converted($, path, 'bmp', [], async upright => {
    const grid = await gridOf($, upright, room, cellHeightRatio)
    if (typeof grid === 'string') return grid
    const { columns, rows } = grid
    return converted($, upright, 'bmp', ['-z', String(rows * SAMPLES_PER_CELL_SIDE), String(columns * SAMPLES_PER_CELL_SIDE)], async out => {
      const { base64: resized } = await $.fs.read(out, { as: 'bytes' })
      const samples = topDownRgbFromBmp(Uint8Array.fromBase64(resized), columns * SAMPLES_PER_CELL_SIDE, rows * SAMPLES_PER_CELL_SIDE)
      return { columns, rows, cells: bestGlyphCells(samples, columns, rows) }
    })
  })
  return typeof picture === 'string' ? picture : 'failure' in picture ? picture.failure : picture
}

async function decodePixels($: EngineInterface, path: string, room: number, cellHeightRatio: number): Promise<Pixels | string> {
  const picture = await converted($, path, 'bmp', [], async upright => {
    const grid = await gridOf($, upright, room, cellHeightRatio)
    if (typeof grid === 'string') return grid
    return converted($, upright, 'png', grid.longestEdge > LONGEST_PNG_EDGE ? ['-Z', String(LONGEST_PNG_EDGE)] : [], async out => {
      const { base64: png } = await $.fs.read(out, { as: 'bytes' })
      if ((png.length * 3) / 4 > MOST_PNG_BYTES) return 'the picture is too large to send as pixels'
      return { columns: grid.columns, rows: grid.rows, png }
    })
  })
  return typeof picture === 'string' ? picture : 'failure' in picture ? picture.failure : picture
}

function remembered<T>(known: Map<string, Promise<T>>, most: number, id: string, load: () => Promise<T>): Promise<T> {
  const held = known.get(id)
  if (held !== undefined) return held
  const loading = load()
  known.set(id, loading)
  loading.catch(() => known.delete(id))
  const oldest = known.keys().next().value
  if (known.size > most && oldest !== undefined) known.delete(oldest)
  return loading
}

// The engine aborts a dispatch's $ calls when it abandons that dispatch, and a later drawing can
// be waiting on the same decode, so a rejected decode is forgotten and this dispatch starts its own.
export async function settled<T>(load: () => Promise<T | string>, signal: AbortSignal): Promise<T | string> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await load()
    } catch (error) {
      if (attempt === MOST_DECODE_ATTEMPTS || signal.aborted) return String(error)
    }
  }
}

// Only a mounted Image can be asked whether this terminal shows it, so the first Image is
// drawn and then asked about; refused, every drawing goes back to cells.
function askTerminal($: EngineInterface, requestId: string, key: string, png: string, asksLeft: number): void {
  $.clock.after(ASK_TERMINAL_AFTER_MS, () => {
    $.ui.blit({ requestId, key, source: { png } }).then(
      answer => ({ verdict: pixelAnswer(answer), words: answer.deny ?? 'drawn' }),
      error => ({ verdict: 'ask-again' as const, words: String(error) }),
    ).then(({ verdict, words }) => {
      if (verdict === 'ask-again' && asksLeft > 1) {
        askTerminal($, requestId, key, png, asksLeft - 1)
        return
      }
      $.ui.log(`pixels ${verdict}: ${words}`, { to: 'debug' })
      terminalDrawsPixels = verdict === 'drawn' ? 'yes' : 'no'
      if (terminalDrawsPixels === 'no') $.ui.invalidate('ui.render')
    })
  })
}

export const register: Register = (on, options) => {
  if (options.drawImages === false) return
  const requestedRatio = options.cellHeightRatio === undefined ? 2 : options.cellHeightRatio
  const cellHeightRatio = cellHeightRatioFor(requestedRatio)
  let ratioLogged = false

  on('session.start', async ($, e, next) => {
    terminalDrawsPixels = 'untried'
    sipsAvailable = false
    let present = false
    try {
      present = (await $.process.run(['sips', '--version'], { timeoutMs: SIPS_TIMEOUT_MS })).exitCode === 0
    } catch {
      present = false
    }
    if (present) {
      const directory = await $.env.get('TMPDIR') || '/tmp/'
      temporaryDirectory = directory.endsWith('/') ? directory : `${directory}/`
      const cleaned = await $.process.run(['find', temporaryDirectory, '-maxdepth', '1', '-type', 'f', '-name', 'cs-images-tmp-*', '-mmin', '+60', '-delete'])
      if (cleaned.exitCode !== 0) await $.ui.log(`temp sweep exited ${cleaned.exitCode}: ${JSON.stringify(cleaned.stderr.trim())}`, { to: 'debug' })
      sipsAvailable = true
      $.ui.invalidate('ui.render')
    }
    return next(e)
  })

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (!sipsAvailable || e.surface !== 'terminal' || !hasImageLine(e.props.text)) return next(e)
    if (requestedRatio !== cellHeightRatio && !ratioLogged) {
      ratioLogged = true
      await $.ui.log(`cellHeightRatio ${String(requestedRatio)} is not a finite number from 1 to 5; using 2`, { to: 'debug' })
    }
    const { Box, Text, Raster, Image } = $.ui.resolve(e)
    const room = Math.min(60, Math.max(8, (e.viewport?.columns ?? 80) - 6))
    const parts = replyParts(e.props.text)
    const firstText = parts.findIndex(part => part.kind === 'text')
    const drawn = await Promise.all(parts.map(async (part, index) => {
      if (part.kind === 'text') {
        return next({ ...e, props: { ...e.props, text: part.body, isFirstOfReply: e.props.isFirstOfReply && index === firstText } })
      }
      const changedAt = await $.fs.stat(part.path).then(stat => stat?.mtimeMs ?? 0, () => 0)
      const id = `${part.path}@${room}@${changedAt}@${cellHeightRatio}`
      if (terminalDrawsPixels !== 'no') {
        const pixels = await settled(() => remembered(allPixels, MOST_PIXELS_REMEMBERED, id, () => decodePixels($, part.path, room, cellHeightRatio)), next.signal)
        if (typeof pixels !== 'string') {
          const key = `picture-${index}`
          if (terminalDrawsPixels === 'untried') {
            terminalDrawsPixels = 'asking'
            askTerminal($, e.requestId, key, pixels.png, MOST_TERMINAL_ASKS)
          }
          return <Image key={key} source={{ png: pixels.png }} columns={pixels.columns} rows={pixels.rows} alt={part.alt || ' '} />
        }
      }
      const picture = await settled(() => remembered(allCells, MOST_REMEMBERED, id, () => decodeCells($, part.path, room, cellHeightRatio)), next.signal)
      return typeof picture === 'string'
        ? <Text>cs-images cannot draw {part.line}: {picture}</Text>
        : <Raster key={`picture-${index}`} columns={picture.columns} rows={picture.rows} cells={picture.cells} />
    }))
    return <Box flexDirection="column">{drawn}</Box>
  })
}
