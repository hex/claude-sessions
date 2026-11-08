// ABOUTME: Exercises cs-images rendering and decode failures through the engine kit.
// ABOUTME: Keeps picture conversion responses deterministic without a terminal.
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import type { Engine } from 'claude-code/testing'

async function startSession($: Engine, on: On) {
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
}

test('with drawImages off, an image line stays with the engine', { options: { drawImages: false } }, async ($, on) => {
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>{e.props.text}</Text>
  })
  const ui = await $.ui.mount({ plugin: 'cs-images', component: 'AssistantMessage', surface: 'terminal', props: { text: '![owl](/tmp/off.png)', isFirstOfReply: true } })
  expect((await ui.find({ type: 'Text' }))?.text).toBe('![owl](/tmp/off.png)')
  await ui.unmount()
})

test('a picture sips cannot read says why and keeps the line', async ($, on) => {
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
  expect(row?.text).toBe('cs-images cannot draw ![owl](/tmp/owl.png): sips cannot read it: no such format')
})

// A picture of 8 columns and 1 row needs 64x8 samples: a 24-bit BMP with its 54-byte header.
function solidBmpBase64(width = 64, height = 8): string {
  const size = 54 + width * height * 3
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
  expect(converts).toBe(2)
})

function pictureWorld(on: On, availability: 'present' | 'nonzero' | 'throws' = 'present') {
  const w = { logs: [] as string[], runs: [] as string[][] }
  const clock = mock.clock(on)
  on('fs.stat', () => ({ value: { kind: 'file', size: 1, mtimeMs: 1, isLink: false } }))
  on('fs.read', (_$, e) => ({ value: { base64: e.path.endsWith('.bmp') ? solidBmpBase64(64, 32) : 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII=' } }))
  on('process.run', (_$, e) => {
    w.runs.push([...e.argv])
    if (e.argv.includes('--version')) {
      if (availability === 'throws') throw new Error('sips is absent')
      if (availability === 'nonzero') return { value: { exitCode: 127, stdout: '', stderr: 'sips not found', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    return { value: { exitCode: 0, stdout: e.argv.includes('-g') ? 'pixelWidth: 512\npixelHeight: 512\n' : '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.log', (_$, e) => { w.logs.push(e.text); return { value: undefined } })
  return { w, clock }
}

for (const ratio of [0, 9]) {
  test(`cellHeightRatio ${String(ratio)} draws at 2 and logs its value once`, { options: { cellHeightRatio: ratio } }, async ($, on) => {
    const { w } = pictureWorld(on)
    await startSession($, on)
    const ui = await $.ui.mount({ plugin: 'cs-images', component: 'AssistantMessage', surface: 'terminal', viewport: { columns: 14, rows: 40 }, props: { text: `![owl](/tmp/ratio-${String(ratio)}.png)`, isFirstOfReply: true } })
    expect((await ui.find({ type: 'Image' }))?.props.rows).toBe(4)
    await ui.redraw()
    expect(w.logs).toEqual([`cellHeightRatio ${String(ratio)} is not a finite number from 1 to 5; using 2`])
    await ui.unmount()
  })
}

for (const availability of ['nonzero', 'throws'] as const) {
  test(`an unavailable sips (${availability}) leaves image lines as text`, async ($, on) => {
    const { w } = pictureWorld(on, availability)
    on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
      const { Text } = $.ui.resolve(e)
      return <Text>{e.props.text}</Text>
    })
    await startSession($, on)
    const ui = await $.ui.mount({ plugin: 'cs-images', component: 'AssistantMessage', surface: 'terminal', viewport: { columns: 14, rows: 40 }, props: { text: `![owl](/tmp/absent-${availability}.png)`, isFirstOfReply: true } })
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
    ['find', '/tmp', '-maxdepth', '1', '-name', 'cs-images-*', '-mmin', '+60', '-delete'],
  ])
  const ui = await $.ui.mount({ plugin: 'cs-images', component: 'AssistantMessage', surface: 'terminal', viewport: { columns: 14, rows: 40 }, props: { text: '![owl](/tmp/present.png)', isFirstOfReply: true } })
  expect((await ui.find({ type: 'Image' }))?.props.rows).toBe(4)
  await ui.redraw()
  expect(w.runs.filter(argv => argv.includes('--version'))).toEqual([['sips', '--version']])
  await ui.unmount()
})
