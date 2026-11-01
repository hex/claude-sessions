// ABOUTME: Pins chat only's error lines to the feature specification's literal examples.
// ABOUTME: A failed reply's text in, the line that takes its place out; no drawing hooks.
import { expect, test } from 'claude-code/testing'
import { errorLine } from '../hooks/words'

test('error rules preserve ordered literal remedies and reject quoted safeguard prose', () => {
  expect(errorLine("Sonnet's safeguards stopped the response above\nThis is a quoted example.")).toBeUndefined()
  expect(errorLine("Sonnet's safeguards stopped the response above")).toEqual({ head: "Sonnet's safeguards cut the reply above", rest: ['Claude continues', 'esc esc goes back to an earlier message'], tone: 'violet', act: false })
  expect(errorLine('A normal reply')).toBeUndefined()
  expect(errorLine("API Error: Sonnet's safeguards stopped the response above")).toEqual({ head: "Sonnet's safeguards cut the reply above", rest: ['Claude continues', 'esc esc goes back to an earlier message'], tone: 'violet', act: false })
  expect(errorLine('API Error: stopped by a safety classifier')).toEqual({ head: 'A safeguard cut the reply above', rest: ['Claude continues', 'esc esc goes back to an earlier message'], tone: 'violet', act: false })
  expect(errorLine("API Error: Sonnet 5.5's safeguards flagged this message (/legal/aup).")).toEqual({ head: "Sonnet 5.5's safeguards stopped this reply", rest: ['often a false alarm', 'esc esc to edit your message, or /model to switch'], tone: 'violet', act: true })
  expect(errorLine('API Error: 529 overloaded')).toEqual({ head: "Claude's servers are busy", rest: ['not your setup', 'Claude Code retries, or send again'], tone: 'amber', act: false })
  expect(errorLine('Claude AI usage limit reached, resets 3pm')).toEqual({ head: 'Usage limit reached', rest: ['resets 3pm', 'nothing is lost', '/model to switch'], tone: 'red', act: true })
  expect(errorLine('Prompt is too long')).toEqual({ head: 'This chat is too long for the model', rest: ['run /compact', 'nothing is lost'], tone: 'red', act: true })
  expect(errorLine('Invalid API key')).toEqual({ head: 'Login needed', rest: ['run /login', 'nothing is lost'], tone: 'red', act: true })
  expect(errorLine('Credit balance exhausted')).toEqual({ head: 'Billing problem on the account', rest: ['nothing is lost'], tone: 'red', act: true })
  expect(errorLine('API Error: Connection error.')).toEqual({ head: 'Connection lost', rest: ['check your internet', 'send again to retry'], tone: 'amber', act: false })
  expect(errorLine('API Error: 500 internal')).toEqual({ head: "Server error on Claude's side", rest: ['your work is kept', 'send a message to try again'], tone: 'amber', act: false })
  expect(errorLine('API Error: 400 invalid_request')).toEqual({ head: 'Claude refused this request', rest: ['ctrl+o shows why', 'esc esc to edit your message'], tone: 'red', act: true })
  expect(errorLine('Error: unknown')).toEqual({ head: 'Claude Code hit an error', rest: ['ctrl+o shows it'], tone: 'amber', act: false })
})
