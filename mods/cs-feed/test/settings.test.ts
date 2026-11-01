// ABOUTME: Tests the /feed grammar and what the feed file's text means.
// ABOUTME: Expected values come from the switch's contract: on by default, only whole on and off lines count.
import { expect, test } from 'claude-code/testing'
import { feedState, parseFeedArgs } from '../hooks/settings'

test('feed takes no word, on, off or status, whatever the case and spacing, and replies the usage line to anything else', () => {
  expect(['', '   ', 'on', 'off', 'status', ' ON ', 'Off', 'clean', 'raw', 'close', 'hide peer', 'on now', 'status please'].map(parseFeedArgs)).toEqual([
    { kind: 'toggle' }, { kind: 'toggle' }, { kind: 'switch', on: true }, { kind: 'switch', on: false }, { kind: 'status' },
    { kind: 'switch', on: true }, { kind: 'switch', on: false },
    { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' }, { kind: 'usage' },
  ])
})

test('no feed file reads on, only the whole on and off lines count, and any other text reads off with its problem', () => {
  expect([undefined, 'on\n', 'off\n', 'on', '', 'off', 'on\n\n', ' on\n', 'ON\n', 'on\r\n', 'yes\n'].map(feedState)).toEqual([
    { on: true }, { on: true }, { on: false },
    { on: false, problem: 'torn' }, { on: false, problem: 'torn' }, { on: false, problem: 'torn' },
    { on: false, problem: 'other' }, { on: false, problem: 'other' }, { on: false, problem: 'other' }, { on: false, problem: 'other' }, { on: false, problem: 'other' },
  ])
})
