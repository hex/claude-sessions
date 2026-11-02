// ABOUTME: Tests the /chat-only grammar and what the chat only file's text means.
// ABOUTME: Expected values come from the switch's contract: on by default, only whole on and off lines count.
import { expect, test } from 'claude-code/testing'
import { chatOnlyState, parseChatOnlyArgs, youInkOf } from '../hooks/settings'

test('chat-only takes no word, on, off or status, whatever the case and spacing, and replies the usage line to anything else', () => {
  expect(['', '   ', 'on', 'off', 'status', ' ON ', 'Off', 'clean', 'raw', 'close', 'hide peer', 'on now', 'status please'].map(parseChatOnlyArgs)).toEqual([
    { kind: 'toggle' }, { kind: 'toggle' }, { kind: 'switch', on: true }, { kind: 'switch', on: false }, { kind: 'status' },
    { kind: 'switch', on: true }, { kind: 'switch', on: false },
    { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' },
  ])
})

test('no chat only file reads on, only the whole on and off lines count, and any other text reads off with its problem', () => {
  expect([undefined, 'on\n', 'off\n', 'on', '', 'off', 'on\n\n', ' on\n', 'ON\n', 'on\r\n', 'yes\n'].map(chatOnlyState)).toEqual([
    { on: true }, { on: true }, { on: false },
    { on: false, problem: 'torn' }, { on: false, problem: 'torn' }, { on: false, problem: 'torn' },
    { on: false, problem: 'other' }, { on: false, problem: 'other' }, { on: false, problem: 'other' }, { on: false, problem: 'other' }, { on: false, problem: 'other' },
  ])
})

test('the you ink option reads as its theme key, and a value the mod does not list throws, naming it and the keys it takes', () => {
  expect(['remember', 'planMode', 'success', 'merged', 'error', 'text'].map(youInk => youInkOf({ youInk }))).toEqual(['remember', 'planMode', 'success', 'merged', 'error', 'text'])
  expect(() => youInkOf({ youInk: 'permission' })).toThrow('cs-chat-only option youInk is "permission", not one of remember, planMode, success, merged, error, text: the manifest\'s options and settings.YOU_INKS differ')
  expect(() => youInkOf({})).toThrow('cs-chat-only option youInk is undefined, not one of remember, planMode, success, merged, error, text: the manifest\'s options and settings.YOU_INKS differ')
})
