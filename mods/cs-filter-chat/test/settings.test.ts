// ABOUTME: Tests the /filter-chat grammar and what the filter chat file's text means.
// ABOUTME: Expected values come from the switch's contract: on by default, only whole on and off lines count.
import { expect, test } from 'claude-code/testing'
import { filterChatFlag, parseFilterChatArgs, youInkOf } from '../hooks/settings'

test('filter-chat takes no word, on, off or status, whatever the case and spacing, and replies the usage line to anything else', () => {
  expect(['', '   ', 'on', 'off', 'status', ' ON ', 'Off', 'clean', 'raw', 'close', 'hide peer', 'on now', 'status please'].map(parseFilterChatArgs)).toEqual([
    { kind: 'toggle' }, { kind: 'toggle' }, { kind: 'switch', on: true }, { kind: 'switch', on: false }, { kind: 'status' },
    { kind: 'switch', on: true }, { kind: 'switch', on: false },
    { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' },
  ])
})

test('a settings file says on at CS_FILTER_CHAT=1 and off at =0, its last accepted line wins, and any other line says nothing', () => {
  expect(['', 'CS_FILTER_CHAT=1\n', 'CS_FILTER_CHAT=0\n', 'CS_FILTER_CHAT=1', 'CS_FILTER_CHAT=1\nCS_FILTER_CHAT=0\n', 'CS_FILTER_CHAT=0\nCS_FILTER_CHAT=1\n',
    'CS_FILTER_CHAT=1\nCS_FILTER_CHAT=yes\n', 'CS_NERD_FONTS=1\nCS_FILTER_CHAT=1\n', 'CS_FILTER_CHAT_X=1\n', 'X_CS_FILTER_CHAT=1\n', '#CS_FILTER_CHAT=1\n', ' CS_FILTER_CHAT=1\n', 'CS_FILTER_CHAT =1\n', 'CS_FILTER_CHAT=1 \n', 'CS_FILTER_CHAT=1\r\n', 'CS_FILTER_CHAT=\n', 'CS_FILTER_CHAT\n'].map(filterChatFlag)).toEqual([
    undefined, true, false, true, false, true,
    true, true, undefined, undefined, undefined, undefined, undefined, undefined, undefined, undefined, undefined,
  ])
})

test('the you ink option reads as its theme key, and a value the mod does not list throws, naming it and the keys it takes', () => {
  expect(['remember', 'planMode', 'success', 'merged', 'error', 'text'].map(youInk => youInkOf({ youInk }))).toEqual(['remember', 'planMode', 'success', 'merged', 'error', 'text'])
  expect(() => youInkOf({ youInk: 'permission' })).toThrow('cs-filter-chat option youInk is "permission", not one of remember, planMode, success, merged, error, text: the manifest\'s options and settings.YOU_INKS differ')
  expect(() => youInkOf({})).toThrow('cs-filter-chat option youInk is undefined, not one of remember, planMode, success, merged, error, text: the manifest\'s options and settings.YOU_INKS differ')
})
