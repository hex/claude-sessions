// ABOUTME: Pins feed wording to the feature specification's literal examples.
// ABOUTME: Covers cleaning at the transcript text boundary without drawing hooks.
import { expect, test } from 'claude-code/testing'
import { callWords, clean, toolName, isRefusal, looksLikeTest, stepsLine, fit, elapsed, hhmm, runWords, runChips, callChips } from '../hooks/words'
import { buildTranscript, callId } from '../hooks/transcript'
import { repliesOwnSteps } from '../hooks/words'
import { errorLine } from '../hooks/words'
import { peerHeadline, senderOf, hookTextLine } from '../hooks/words'
import { parseEnvelopes, framesFromText } from '../hooks/words'

test('helper envelopes preserve report data as inert frames and bound plain leads', () => {
  expect(parseEnvelopes('<teammate-message teammate_id="reviewer" summary="Review">Looks good.\n\n{"status":"passed","target":{"name":"app","model":"small"},"checks":[{"status":"passed"},{"status":"failed"}],"notes":["one","two"],"report_file":"/tmp/report.md"}</teammate-message>')).toEqual([{ from: 'reviewer', summary: 'Review', state: undefined, at: undefined, relays: false, lead: { sentence: 'Looks good.', card: { tone: 'ok', status: 'passed', sub: undefined, target: 'app · small', scores: [{ label: 'checks', dots: ['ok', 'bad'], pass: 1, of: 2 }], lists: [{ label: 'notes', count: 2, first: 'one' }], report: 'report.md' }, more: 0 } }])
  expect(framesFromText('{"type":"idle_notification","from":"reader","summary":"Ready"}')).toEqual([{ from: 'reader', state: 'waiting', at: undefined, summary: 'Ready', relays: false, lead: undefined }])
  expect(parseEnvelopes('<teammate-message from="reader"><relay-marker/>\nThis agent read text written by people other than you\nOne\nTwo\nThree\nFour\nFive\nSix\nSeven\nEight</teammate-message>')).toEqual([{ from: 'reader', state: undefined, at: undefined, summary: undefined, relays: true, lead: { text: 'One\nTwo\nThree\nFour\nFive\nSix', more: 2 } }])
  expect(parseEnvelopes('ordinary text')).toEqual([])
  expect(parseEnvelopes('<teammate-message from="docs">Built.\n\n- a\n- b</teammate-message>')[0]?.lead).toEqual({ text: 'Built.', more: 2 })
  expect(parseEnvelopes('<teammate-message from="docs">[1,2,3]</teammate-message>')[0]?.lead).toEqual({ text: '3 items', more: 0 })
  expect(parseEnvelopes('<teammate-message from="docs">{not json}</teammate-message>')[0]?.lead).toEqual({ text: 'a structured report', more: 0 })
  expect(framesFromText('Build finished.\nAll 12 checks pass.')).toEqual([])
})

test('peer and hook labels clean only their display text and keep safe fallbacks', () => {
  expect(peerHeadline('Build finished.\nAll 12 checks pass.', 80)).toBe('Build finished.')
  expect(peerHeadline('<note>Saved /private/tmp/build/report.txt</note>', 80)).toBe('Saved report.txt')
  expect(peerHeadline('{"type":"idle_notification","summary":"Ready"}', 80)).toBe('waiting · Ready')
  expect(senderOf({ name: 'build-helper' })).toBe('build-helper')
  expect(senderOf(undefined, '<teammate-message teammate_id="reader">done</teammate-message>')).toBe('reader')
  expect(senderOf(undefined)).toBe('another session')
  expect(hookTextLine('Stop hook feedback:\n\nTests need another pass')).toBe('Tests need another pass')
  expect(hookTextLine('UserPromptSubmit context:')).toBe('hook feedback')
  expect(hookTextLine('A normal message')).toBeUndefined()
})

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

// cs-mermaid draws a reply itself exactly when its scanner finds a mermaid
// fence with a non-blank body (mods/cs-mermaid/hooks/register.tsx: fencesOf
// drops blank bodies, and the hook hands the reply to the engine whole when it
// finds none); a reply owns its steps line exactly when cs-mermaid does not
// draw it. The texts are the ones cs-mermaid's own fence tests use
// (mods/cs-mermaid/test/register.test.tsx), with the answer its fencesOf gives
// each, plus blank fences. The kit refuses an import from outside this
// plugin's folder, so cs-mermaid's scanner cannot run here.
test('steps ownership agrees with the mermaid scanner on its fence fixtures and on blank fences', () => {
  const rows: readonly [string, boolean][] = [
    [['Flow:', '', '```mermaid', 'graph TD', '  A[prompt] --> B{cached?}', '  B -->|no| C[render]', '```'].join('\n'), false],
    ['```ts\nconst a = 1\n```', true],
    ['x\n````mermaid\ngraph TD\nA-->B\n````\n', true],
    ['Write it like this:\n````markdown\n```mermaid\ngraph TD\nA --> B\n```\n````\nthen run it.', true],
    ['~~~\n```mermaid\ngraph TD\nA --> B\n```\n~~~', true],
    ['````\nquoted\n````\n```mermaid\ngraph TD\nA --> B\n```', false],
    ['a\n```mermaid\ngraph TD\nA --> B\n```\nb\n```mermaid\ngraph LR\nC --> D\n```', false],
    ['```mermaid\n```', true],
    ['```mermaid\n   \n```\nthen prose', true],
    ['```mermaid\n```\n```mermaid\ngraph TD\n```', false],
  ]
  for (const [text, owns] of rows) {
    expect({ text, owns: repliesOwnSteps(text) }).toEqual({ text, owns })
  }
})

test('run summaries count kinds and chips without counting refused calls as failed work', () => {
  const t = buildTranscript([{ role: 'assistant', text: '', toolUses: [
    { tool_use_id: 'a', tool: 'Bash', input: {}, result: { stdout: 'ok' } },
    { tool_use_id: 'b', tool: 'Bash', input: {}, result: { stdout: 'done' } },
    { tool_use_id: 'c', tool: 'Read', input: {}, result: { stdout: 'file' } },
    { tool_use_id: 'd', tool: 'Read', input: {}, isError: true, text: 'blocked by a hook' },
  ] }])
  const run = t.runs.get(callId('a'))
  if (!run) throw new Error('The fixture must file one run')
  expect(runWords(run, t)).toBe('Ran 2 shell commands · read 1 file')
  expect(runWords(run, t, 'Reading app.py')).toBe('Reading app.py')
  expect(runWords({ ...run, calls: [callId('a'), callId('c')] }, t)).toBe('Read 1 file · ran 1 shell command')
  expect(runWords({ ...run, calls: [callId('d')] }, t)).toBe('1 step refused by a hook')
  expect(runChips(run, t)).toEqual(['1 step refused by a hook', '+4 lines'])
  expect(callChips({ tool: 'Bash', input: {}, isRunning: false, isErrored: false, isInterrupted: false }, t.calls.get(callId('a')))).toEqual(['+1 line'])
  expect(runChips({ ...run, calls: [callId('a')] }, t)).toEqual(['+1 line'])
})

test('compact labels preserve singular counts and bounded time and text', () => {
  expect(stepsLine(1)).toBe('· 1 step')
  expect(stepsLine(3)).toBe('· 3 steps')
  expect(elapsed(-1000)).toBe('0s')
  expect(elapsed(8000)).toBe('8s')
  expect(elapsed(72000)).toBe('1m 12s')
  expect(elapsed(3780000)).toBe('1h 3m')
  expect(hhmm(new Date(2026, 0, 1, 9, 7).getTime())).toBe('09:07')
  expect(fit('short', 12)).toBe('short')
  expect(fit('Reading a large file', 14)).toBe('Reading a…')
  expect(fit('abcdefghijk', 2)).toBe('abcd…')
})

test('call labels clean descriptions and name tools without exposing commands', () => {
  expect(callWords({ tool: 'Bash', input: { command: 'cd /private/tmp/x && python3 run.py' } }, 'present')).toBe('Running a shell command')
  expect(callWords({ tool: 'Read', input: { file_path: '/repo/src/app.py' } }, 'present')).toBe('Reading app.py')
  expect(callWords({ tool: 'WebFetch', input: { url: 'https://www.example.com/a/b?c=1' } }, 'present')).toBe('Opening example.com')
  expect(callWords({ tool: 'WebFetch', input: { url: 'https://reader:example@example.com/a' } }, 'present')).toBe('Opening example.com')
  expect(callWords({ tool: 'WebFetch', input: { url: 'not a URL' } }, 'present')).toBe('Opening a web page')
  expect(clean('Run the tests in /private/tmp/12345678-abcd-1234-abcd-123456789abc/run')).toBe('Run the tests in run')
  expect(toolName('mcp__claude_ai_Slack__send')).toBe('Slack send')
})

test('hook refusals and background test words use the specified phrases', () => {
  expect(isRefusal('PreToolUse:Agent hook error: provide a brief')).toBe(true)
  expect(isRefusal('PermissionRequest hook denied')).toBe(true)
  expect(isRefusal('blocked by a hook')).toBe(true)
  expect(isRefusal('network failed')).toBe(false)
  expect(looksLikeTest('Run the unit tests')).toBe(true)
  expect(looksLikeTest('Build the docs site')).toBe(false)
})
