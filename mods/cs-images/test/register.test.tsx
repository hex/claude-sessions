// ABOUTME: Exercises cs-images rendering and decode failures through the engine kit.
// ABOUTME: Keeps picture conversion responses deterministic without a terminal.
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import type { Engine } from 'claude-code/testing'

async function startSession($: Engine, on: On) {
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
}

function mountPicture($: Engine, path: string) {
  return $.ui.mount({ plugin: 'cs-images', component: 'AssistantMessage', surface: 'terminal', viewport: { columns: 14, rows: 40 }, props: { text: `![owl](${path})`, isFirstOfReply: true } })
}

test('with drawImages off, an image line stays with the engine', { options: { drawImages: false } }, async ($, on) => {
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{e.props.text}</Text>
  })
  await startSession($, on)
  const ui = await mountPicture($, '/tmp/off.png')
  expect((await ui.find({ type: 'Text' }))?.text).toBe('![owl](/tmp/off.png)')
  await ui.unmount()
})

test('a picture sips cannot read says why and keeps the line', async ($, on) => {
  mock.env(on, {})
  on('fs.stat', () => ({ value: { kind: 'file', size: 1, mtimeMs: 1, isLink: false } }))
  on('process.run', (_$, e) => ({ value: { exitCode: e.argv.includes('--version') || e.argv[0] === 'find' ? 0 : 1, stdout: '', stderr: 'no such format', isStdoutTruncated: false, isStderrTruncated: false } }))
  await startSession($, on)

  const ui = await $.ui.mount({
    plugin: 'cs-images',
    component: 'AssistantMessage',
    surface: 'terminal',
    props: { text: '![owl](/tmp/owl.png)', isFirstOfReply: true },
  })

  const row = await ui.find({ type: 'Text', text: /cannot draw/ })
  expect(row?.text).toBe('cs-images cannot draw ![owl](/tmp/owl.png): sips cannot convert it: no such format')
})

// A picture of 8 columns and 1 row needs 64x8 samples: a 24-bit BMP with its 54-byte header.
function solidBmpBase64(width = 64, height = 8): string {
  const size = 54 + Math.ceil(width * 3 / 4) * 4 * Math.abs(height)
  const bmp = new Uint8Array(size)
  const view = new DataView(bmp.buffer)
  view.setUint32(10, 54, true)
  view.setInt32(18, width, true)
  view.setInt32(22, height, true)
  view.setUint16(28, 24, true)
  bmp.fill(0x40, 54)
  return bmp.toBase64()
}

test('a picture whose decode was aborted is decoded again rather than reported', async ($, on) => {
  mock.env(on, {})
  let converts = 0
  on('fs.stat', () => ({ value: { kind: 'file', size: 1, mtimeMs: 2, isLink: false } }))
  on('fs.read', () => ({ value: { base64: solidBmpBase64() } }))
  on('process.run', (_$, e) => {
    if (e.argv[0] === 'rm' || e.argv[0] === 'find' || e.argv.includes('--version')) return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    if (e.argv.includes('-g')) return { value: { exitCode: 0, stdout: 'pixelWidth: 9\npixelHeight: 3\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    if (e.argv.includes('png')) return { value: { exitCode: 1, stdout: '', stderr: 'no png here', isStdoutTruncated: false, isStderrTruncated: false } }
    converts++
    if (converts === 1) throw new Error('$.process.run(sips) aborted')
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })

  await startSession($, on)
  const ui = await $.ui.mount({
    plugin: 'cs-images',
    component: 'AssistantMessage',
    surface: 'terminal',
    viewport: { columns: 7, rows: 40 },
    props: { text: '![owl](/tmp/aborted.png)', isFirstOfReply: true },
  })

  expect(await ui.find({ type: 'Text', text: /cannot draw/ })).toBeUndefined()
  expect((await ui.find({ type: 'Raster' }))?.props.columns).toBe(8)
  expect(converts).toBe(4)
})

function pictureWorld(on: On, options: { sips?: 'nonzero' | 'throws'; png?: 'fails' | 'oversized'; answers?: Array<{ deny?: string }>; rotated?: boolean; tmpdir?: string; probe?: Promise<void> } = {}) {
  const w = { logs: [] as string[], runs: [] as string[][], blits: [] as string[], invalidations: [] as string[], sizeReads: 0 }
  const clock = mock.clock(on)
  mock.env(on, options.tmpdir === undefined ? {} : { TMPDIR: options.tmpdir })
  on('fs.stat', () => ({ value: { kind: 'file', size: 1, mtimeMs: 1, isLink: false } }))
  on('fs.read', (_$, e) => {
    if (!e.path.endsWith('.bmp')) return { value: { base64: options.png === 'oversized' ? 'A'.repeat(2796204)
      : 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII=' } }
    const conversion = w.runs.find(argv => argv[argv.indexOf('--out') + 1] === e.path)
    if (conversion === undefined) throw new Error(`no conversion wrote ${e.path}`)
    const z = conversion.indexOf('-z')
    if (z < 0) {
      w.sizeReads++
      return { value: { base64: options.rotated ? solidBmpBase64(480, -640) : solidBmpBase64(512, 512) } }
    }
    const rows = Number(conversion[z + 1]), columns = Number(conversion[z + 2])
    const from = conversion[conversion.indexOf('--out') - 1]
    return { value: { base64: options.rotated && from === '/tmp/rotated.jpg'
      ? solidBmpBase64(rows, -columns) : solidBmpBase64(columns, -rows) } }
  })
  on('process.run', async (_$, e) => {
    w.runs.push([...e.argv])
    if (e.argv.includes('--version')) {
      await options.probe
      if (options.sips === 'throws') throw new Error('sips is absent')
      if (options.sips === 'nonzero') return { value: { exitCode: 127, stdout: '', stderr: 'sips not found', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    if (e.argv.includes('png') && options.png === 'fails') return { value: { exitCode: 1, stdout: '', stderr: 'png conversion failed', isStdoutTruncated: false, isStderrTruncated: false } }
    return { value: { exitCode: 0, stdout: e.argv.includes('-g') ? options.rotated ? 'pixelWidth: 640\npixelHeight: 480\n' : 'pixelWidth: 512\npixelHeight: 512\n' : '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.log', (_$, e) => { w.logs.push(e.text); return { value: undefined } })
  on('ui.blit', (_$, e) => { w.blits.push(e.key); return { value: options.answers?.[w.blits.length - 1] ?? {} } })
  on('ui.invalidate', (_$, e, next) => { w.invalidations.push(e.event); return next(e) })
  return { w, clock }
}

test('widths 120 and 121 share one displayed-size read above the 60-column cap', async ($, on) => {
  const { w } = pictureWorld(on)
  await startSession($, on)
  for (const columns of [120, 121]) {
    const ui = await $.ui.mount({ plugin: 'cs-images', component: 'AssistantMessage', surface: 'terminal', viewport: { columns, rows: 40 }, props: { text: '![owl](/tmp/capped.png)', isFirstOfReply: true } })
    expect((await ui.find({ type: 'Image' }))?.props.columns).toBe(60)
    await ui.unmount()
  }
  expect(w.sizeReads).toBe(1)
})

test('a successful sips probe redraws a reply rendered while the probe was pending', async ($, on) => {
  const options: { sips?: 'nonzero'; probe?: Promise<void> } = { sips: 'nonzero' }
  const { w, clock } = pictureWorld(on, options)
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{e.props.text}</Text>
  })
  await startSession($, on)
  delete options.sips
  let release = () => {}
  options.probe = new Promise<void>(resolve => { release = resolve })
  const starting = $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
  await clock.settle()
  const ui = await mountPicture($, '/tmp/pending-probe.png')
  expect((await ui.find({ type: 'Text' }))?.text).toBe('![owl](/tmp/pending-probe.png)')
  release()
  await starting
  expect(w.invalidations).toEqual(['ui.render'])
  expect((await ui.find({ type: 'Image' }))?.props.rows).toBe(4)
  await ui.unmount()
})

for (const pixels of [true, false]) {
  test(`a rotated photo keeps displayed proportions as ${pixels ? 'pixels' : 'cells'}`, async ($, on) => {
    pictureWorld(on, { rotated: true, ...(pixels ? {} : { png: 'fails' }) })
    await startSession($, on)
    const ui = await $.ui.mount({ plugin: 'cs-images', component: 'AssistantMessage', surface: 'terminal', viewport: { columns: 80, rows: 40 }, props: { text: '![photo](/tmp/rotated.jpg)', isFirstOfReply: true } })
    const picture = await ui.find({ type: pixels ? 'Image' : 'Raster' })
    expect({ columns: picture?.props.columns, rows: picture?.props.rows }).toEqual({ columns: 45, rows: 30 })
    await ui.unmount()
  })
}

for (const ratio of [0, 9]) {
  test(`cellHeightRatio ${String(ratio)} draws at 2 and logs its value once`, { options: { cellHeightRatio: ratio } }, async ($, on) => {
    const { w } = pictureWorld(on)
    await startSession($, on)
    const ui = await mountPicture($, `/tmp/ratio-${String(ratio)}.png`)
    expect((await ui.find({ type: 'Image' }))?.props.rows).toBe(4)
    await ui.redraw()
    expect(w.logs).toEqual([`cellHeightRatio ${String(ratio)} is not a finite number from 1 to 5; using 2`])
    await ui.unmount()
  })
}

for (const availability of ['nonzero', 'throws'] as const) {
  test(`an unavailable sips (${availability}) leaves image lines as text`, async ($, on) => {
    const { w } = pictureWorld(on, { sips: availability })
    on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
      const { Text } = $.ui.resolve(e)
      return <Text>{e.props.text}</Text>
    })
    await startSession($, on)
    const ui = await mountPicture($, `/tmp/absent-${availability}.png`)
    expect((await ui.find({ type: 'Text' }))?.text).toBe(`![owl](/tmp/absent-${availability}.png)`)
    await ui.redraw()
    expect(w.runs).toEqual([['sips', '--version']])
    await ui.unmount()
  })
}

test('session start probes sips once and removes only stale cs-images temp files', async ($, on) => {
  const { w } = pictureWorld(on)
  await startSession($, on)
  expect(w.runs).toEqual([
    ['sips', '--version'],
    ['find', '/tmp/', '-maxdepth', '1', '-type', 'f', '-name', 'cs-images-tmp-*', '-mmin', '+60', '-delete'],
  ])
  const ui = await mountPicture($, '/tmp/present.png')
  expect((await ui.find({ type: 'Image' }))?.props.rows).toBe(4)
  await ui.redraw()
  expect(w.runs.filter(argv => argv.includes('--version'))).toEqual([['sips', '--version']])
  await ui.unmount()
})

test('conversion and stale-file cleanup use the per-user temp directory', async ($, on) => {
  const { w } = pictureWorld(on, { tmpdir: '/private/tmp/image user' })
  await startSession($, on)
  const ui = await mountPicture($, '/tmp/private.png')
  expect(w.runs.filter(argv => argv[0] === 'find')).toEqual([
    ['find', '/private/tmp/image user/', '-maxdepth', '1', '-type', 'f', '-name', 'cs-images-tmp-*', '-mmin', '+60', '-delete'],
  ])
  const files = w.runs.filter(argv => argv.includes('--out')).map(argv => argv[argv.indexOf('--out') + 1]?.replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, '<uuid>'))
  expect(files).toEqual(['/private/tmp/image user/cs-images-tmp-<uuid>.bmp', '/private/tmp/image user/cs-images-tmp-<uuid>.png'])
  await ui.unmount()
})

test('an alt-only blit denial turns the next drawing into cells', async ($, on) => {
  const { w, clock } = pictureWorld(on, { answers: [{ deny: 'the Image draws its alt here: x' }] })
  await startSession($, on)
  const ui = await mountPicture($, '/tmp/denied.png')
  expect({ imageRows: (await ui.find({ type: 'Image' }))?.props.rows }).toEqual({ imageRows: 4 })
  await clock.advance(99)
  expect(w.blits).toEqual([])
  await clock.advance(1)
  await clock.settle()
  expect(w.blits).toEqual(['picture-0'])
  expect(w.logs).toEqual(['pixels refused: the Image draws its alt here: x'])
  await ui.redraw()
  expect({ rasterRows: (await ui.find({ type: 'Raster' }))?.props.rows }).toEqual({ rasterRows: 4 })
  expect(await ui.find({ type: 'Image' })).toBeUndefined()
  await ui.unmount()
})

test('an accepted blit keeps pixels on subsequent drawings', async ($, on) => {
  const { w, clock } = pictureWorld(on, { answers: [{}] })
  await startSession($, on)
  const ui = await mountPicture($, '/tmp/accepted.png')
  expect((await ui.find({ type: 'Image' }))?.props.rows).toBe(4)
  await clock.advance(100)
  await clock.settle()
  expect(w.blits).toEqual(['picture-0'])
  expect(w.logs).toEqual(['pixels drawn: drawn'])
  await ui.redraw({ text: '![owl](/tmp/accepted-again.png)', isFirstOfReply: true })
  expect((await ui.find({ type: 'Image' }))?.props.rows).toBe(4)
  expect(await ui.find({ type: 'Raster' })).toBeUndefined()
  await clock.advance(100)
  expect(w.blits).toEqual(['picture-0'])
  await ui.unmount()
})

test('a not-mounted blit retries and then accepts pixels', async ($, on) => {
  const { w, clock } = pictureWorld(on, { answers: [{ deny: 'not mounted' }, {}] })
  await startSession($, on)
  const ui = await mountPicture($, '/tmp/retry.png')
  await clock.advance(100)
  await clock.settle()
  expect(w.blits).toEqual(['picture-0'])
  expect(w.logs).toEqual([])
  expect((await ui.find({ type: 'Image' }))?.props.rows).toBe(4)
  await clock.advance(100)
  await clock.settle()
  expect(w.blits).toEqual(['picture-0', 'picture-0'])
  expect(w.logs).toEqual(['pixels drawn: drawn'])
  await ui.redraw()
  expect((await ui.find({ type: 'Image' }))?.props.rows).toBe(4)
  expect(await ui.find({ type: 'Raster' })).toBeUndefined()
  await ui.unmount()
})

for (const png of ['fails', 'oversized'] as const) {
  test(`a png that ${png} draws cells without a blit`, async ($, on) => {
    const { w, clock } = pictureWorld(on, { png })
    await startSession($, on)
    const ui = await mountPicture($, `/tmp/png-${png}.png`)
    expect((await ui.find({ type: 'Raster' }))?.props.rows).toBe(4)
    expect(await ui.find({ type: 'Image' })).toBeUndefined()
    await clock.advance(200)
    await clock.settle()
    expect(w.blits).toEqual([])
    expect(w.runs.filter(argv => argv.includes('png')).length).toBe(1)
    expect(w.runs.filter(argv => argv.includes('bmp')).length).toBe(3)
    expect(w.runs.filter(argv => argv[0] === 'rm').length).toBe(4)
    await ui.unmount()
  })
}
