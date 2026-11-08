// ABOUTME: Checks cs-images decode retry boundaries with real abort signals.
// ABOUTME: Counts callback invocations and preserves the exact reported errors.
import { expect, test } from 'claude-code/testing'

import { settled } from '../hooks/register'

test('an aborted decode returns its error without retrying', async () => {
  const controller = new AbortController()
  controller.abort()
  let attempts = 0
  const result = await settled(async () => {
    attempts++
    throw new Error('dispatch aborted')
  }, controller.signal)
  expect({ result, attempts }).toEqual({ result: 'Error: dispatch aborted', attempts: 1 })
})

test('a decode stops after exactly three failed attempts', async () => {
  let attempts = 0
  const result = await settled(async () => {
    attempts++
    if (attempts === 4) return 'late image'
    throw new Error('cannot decode')
  }, new AbortController().signal)
  expect({ result, attempts }).toEqual({ result: 'Error: cannot decode', attempts: 3 })
})
