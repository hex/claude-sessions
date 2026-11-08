// ABOUTME: Exercises cs-images rendering and decode failures through the engine kit.
// ABOUTME: Keeps picture conversion responses deterministic without a terminal.
import { expect, test } from 'claude-code/testing'

test('a picture sips cannot read says why and keeps the line', async ($, on) => {
  on('fs.stat', () => ({ value: { kind: 'file', size: 1, mtimeMs: 1, isLink: false } }))
  on('process.run', () => ({ value: { exitCode: 1, stdout: '', stderr: 'no such format', isStdoutTruncated: false, isStderrTruncated: false } }))

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
function solidBmpBase64(): string {
  const size = 54 + 64 * 8 * 3
  const bmp = new Uint8Array(size)
  const view = new DataView(bmp.buffer)
  view.setUint32(10, 54, true)
  view.setInt32(18, 64, true)
  view.setInt32(22, 8, true)
  view.setUint16(28, 24, true)
  bmp.fill(0x40, 54)
  return bmp.toBase64()
}

test('a picture whose decode was aborted is decoded again rather than reported', async ($, on) => {
  let converts = 0
  on('fs.stat', () => ({ value: { kind: 'file', size: 1, mtimeMs: 2, isLink: false } }))
  on('fs.read', () => ({ value: { base64: solidBmpBase64() } }))
  on('process.run', (_$, e) => {
    if (e.argv[0] === 'rm') return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    if (e.argv.includes('-g')) return { value: { exitCode: 0, stdout: 'pixelWidth: 9\npixelHeight: 3\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    if (e.argv.includes('png')) return { value: { exitCode: 1, stdout: '', stderr: 'no png here', isStdoutTruncated: false, isStderrTruncated: false } }
    converts++
    if (converts === 1) throw new Error('$.process.run(sips) aborted')
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })

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
