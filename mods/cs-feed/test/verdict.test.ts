// ABOUTME: Pins feed decisions to the prescribed ordered rules and reply ownership states.
// ABOUTME: Uses real transcript construction and explicit observations, without render mocks.
import { expect, test } from 'claude-code/testing'
import { helperState, decideCall, decideReply, stepsOwner, decideGroup, decideToolResult, decideSpinner, decideUser, decideBand, decideCommandOutput, sessionModes, type CallView, type Context, type UserRow } from '../hooks/verdict'
import type { AgentInfo } from 'claude-code'
import { stepsLine, runWords, callWords } from '../hooks/words'
import { buildTranscript, callId } from '../hooks/transcript'
import { newLoad, observeResponse, observeTurnComplete, recordStepsClaim } from '../hooks/session'

test('command answers trim the feed prefix and mode labels preserve existing session modes', () => {
  const cx = context()
  expect(decideCommandOutput({ command: 'feed', text: ' cs-feed: Chat view: clean. ', isErrored: false }, cx)).toEqual({ text: 'Chat view: clean.', isErrored: false })
  expect(decideCommandOutput({ command: 'feed', text: 'cs-feed:  ', isErrored: true }, cx)).toBe('nothing')
  expect(sessionModes(['plan'], cx.view)).toEqual(['plan', 'feed clean · /feed to switch'])
})

test('the band caps helper kinds, remembers vanished members and preserves survey and desktop composition', () => {
  const cx = context()
  const agents: AgentInfo[] = ['general-purpose', 'Explore', 'Plan', 'Review', 'Build'].map((type, index) => ({ id: `helper-${index}`, description: `Task ${index}`, type, status: 'running' }))
  for (const agent of agents) cx.obs.batch.kinds.set(agent.id, agent.type)
  cx.obs.batch.startedAt = 10000
  const props = { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 100 }
  const batch = { ...cx, agents, open: undefined, phase: 'idle' as const }
  expect(decideBand(props, {}, batch)).toEqual({ verdict: { draw: 'helpers', head: '5 helpers · 5 running · 0s', kinds: [{ kind: 'general', cells: '◐', done: 0, n: 1 }, { kind: 'Explore', cells: '◐', done: 0, n: 1 }], more: 3, spinning: true }, live: true, clock: 'both' })
  cx.obs.batch.kinds.set('gone', 'general-purpose')
  const remembered = decideBand(props, {}, batch).verdict
  expect(remembered.draw).toBe('helpers')
  if (remembered.draw !== 'helpers') throw new Error('A busy batch must have a helper band')
  expect(remembered.head).toBe('6 helpers · 1 done · 5 running · 0s')
  expect(remembered.kinds[0]).toEqual({ kind: 'general', cells: '◐●', done: 1, n: 2 })
  expect(decideBand({ ...props, hasSurvey: true }, {}, batch)).toEqual({ verdict: { draw: 'engine' }, live: false })
  cx.obs.batch.kinds.clear()
  expect(decideBand(props, { fiveHour: 20, week: 49 }, { ...cx, surface: 'desktop', agents: [], open: undefined })).toEqual({ verdict: { draw: 'desktop', usage: { fiveHour: 20, week: 49 }, pills: [] }, live: false, clock: undefined })
  expect(decideBand(props, {}, { ...cx, agents: [], open: undefined })).toEqual({ verdict: { draw: 'engine' }, live: false, clock: undefined })
  expect(decideBand({ ...props, isWorking: true }, {}, { ...cx, agents: [], open: undefined })).toEqual({ verdict: { draw: 'engine' }, live: true, clock: undefined })
  const bg = buildTranscript([{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'job', tool: 'Bash', input: { description: 'Run the unit tests', run_in_background: true }, result: { backgroundTaskId: 'task' } }] }])
  cx.obs.bgSeenAt.set(callId('job'), 0)
  expect(decideBand(props, {}, { ...cx, t: bg, open: undefined, now: 120000 })).toEqual({ verdict: { draw: 'background', words: 'Run the unit tests', isTest: true, more: 0, elapsedMs: 120000, typing: true }, live: false, clock: 'both' })
})

test('user routing preserves authorship, quiet hook text and conservative task notifications', () => {
  const cx = context()
  const peer: UserRow = { uuid: 'peer', text: 'Build finished.\nAll 12 checks pass.', origin: { kind: 'peer' }, isExpanded: false, from: { name: 'build-helper' } }
  expect(decideUser(peer, cx)).toEqual({ verdict: { draw: 'peer', sender: 'build-helper', headline: 'Build finished.' }, live: false })
  expect(decideUser({ ...peer, text: '[build] ready' }, cx)).toEqual({ verdict: { draw: 'peer', sender: 'build-helper', headline: '[build] ready' }, live: false })
  expect(decideUser({ ...peer, text: '{"type":"idle_notification"}' }, cx)).toEqual({ verdict: { draw: 'frames', frames: [{ from: 'build-helper', state: 'waiting', at: undefined, summary: undefined, relays: false, lead: undefined }] }, live: false })
  expect(decideUser({ ...peer, text: '{"type":"idle_notification","from":"helper"}' }, cx)).toEqual({ verdict: { draw: 'frames', frames: [{ from: 'helper', state: 'waiting', at: undefined, summary: undefined, relays: false, lead: undefined }] }, live: false })
  expect(decideUser({ ...peer, isExpanded: true }, cx)).toEqual({ verdict: { draw: 'engine' }, live: false })
  expect(decideUser({ uuid: 'you', text: 'Work', origin: { kind: 'composer' }, isExpanded: false }, cx)).toEqual({ verdict: { draw: 'you', text: 'Work', at: undefined }, live: false })
  expect(decideUser({ uuid: 'you', text: 'Work', origin: { kind: 'unclassified' }, from: { name: '' }, isExpanded: false }, cx)).toEqual({ verdict: { draw: 'you', text: 'Work', at: undefined }, live: false })
  expect(decideUser({ uuid: 'you', text: 'Work', origin: { kind: 'composer' }, isExpanded: false }, { ...cx, surface: 'desktop' })).toEqual({ verdict: { draw: 'engine' }, live: false })
  expect(decideUser({ ...peer, text: 'Stop hook feedback:\nTry again' }, { ...cx, view: { ...cx.view, hide: ['peer', 'you'] } })).toEqual({ verdict: { draw: 'hookText', line: 'Try again' }, live: false })
  const task: UserRow = { uuid: 'task', text: 'Finished.', origin: { kind: 'task-notification' }, isExpanded: false, task: { id: 'unknown', durationMs: 4000 } }
  expect(decideUser(task, cx)).toEqual({ verdict: { draw: 'nothing' }, live: false })
  expect(decideUser(task, { ...cx, view: { ...cx.view, keep: true } })).toEqual({ verdict: { draw: 'backgroundNote' }, live: false })
  expect(decideUser(task, { ...cx, agents: [{ id: 'unknown', type: 'Explore', description: 'Read', status: 'completed' }] })).toEqual({ verdict: { draw: 'helperNote', durationMs: 4000, headline: 'Finished.' }, live: false })
  cx.obs.bursts.of.set('peer', 'peer')
  cx.obs.bursts.of.set('second', 'peer')
  cx.obs.bursts.members.set('peer', [{ uuid: 'peer', sender: 'build-helper', at: 1000 }, { uuid: 'second', sender: 'reviewer', at: 2000 }])
  expect(decideUser(peer, cx).verdict).toEqual({ draw: 'burst', members: [{ uuid: 'peer', sender: 'build-helper', at: 1000 }, { uuid: 'second', sender: 'reviewer', at: 2000 }], opened: false })
  expect(decideUser({ ...peer, uuid: 'second' }, cx).verdict).toEqual({ draw: 'nothing' })
})

test('spinner rewrites only an empty engine message using machinery steps and response mode', () => {
  const cx = context()
  expect(decideSpinner({ message: null, mode: 'tool-use' }, cx)).toEqual({ verdict: { draw: 'rewrite', message: 'Reading app.py · step 3', suffix: '' }, live: true })
  expect(decideSpinner({ message: null, mode: 'responding' }, cx)).toEqual({ verdict: { draw: 'rewrite', message: 'Writing · step 3', suffix: '' }, live: true })
  expect(decideSpinner({ message: null, mode: 'responding' }, { ...cx, view: { ...cx.view, group: false } })).toEqual({ verdict: { draw: 'rewrite', message: 'Working · step 3', suffix: '' }, live: true })
  expect(decideSpinner({ message: 'Compacting conversation', mode: 'thinking' }, cx)).toEqual({ verdict: { draw: 'engine' }, live: false })
  expect(decideSpinner({ message: null, mode: 'thinking' }, { ...cx, open: undefined })).toEqual({ verdict: { draw: 'engine' }, live: false })
})

test('groups preserve non-call content and expansion, and known results ride on their calls', () => {
  const cx = context()
  expect(decideGroup({ calls: [call()], isActive: false, isExpanded: false }, cx)).toEqual({ verdict: { draw: 'engine' }, live: false })
  expect(decideGroup({ calls: [call()], isActive: false, isExpanded: true, isCallsOnly: true }, cx)).toEqual({ verdict: { draw: 'engine' }, live: false })
  const t = buildTranscript([{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'h1', tool: 'Agent', input: {}, result: {} }, { tool_use_id: 'h2', tool: 'Task', input: {}, result: {} }] }])
  const helpers = [call('h1', 'Agent'), call('h2', 'Task')]
  expect(decideGroup({ calls: helpers, isActive: false, isExpanded: false, isCallsOnly: true }, { ...cx, t, open: undefined })).toEqual({ verdict: { draw: 'batch', key: 'helpers-h1', opened: false, elapsedMs: undefined, helpers: [{ call: helpers[0], kind: 'general-purpose', state: 'finished' }, { call: helpers[1], kind: 'general-purpose', state: 'finished' }] }, live: false })
  expect(decideGroup({ calls: [call('unknown', 'Agent')], isActive: false, isExpanded: false, isCallsOnly: true }, cx).verdict.draw).toBe('stack')
  expect(decideToolResult(callId('a'), false, cx)).toBe('nothing')
  expect(decideToolResult(callId('a'), true, cx)).toBe('engine')
  expect(decideToolResult(callId('unknown'), false, cx)).toBe('engine')
})

test('a reply evaluated before turn completion stays pending then claims exactly once', () => {
  const load = newLoad()
  const t = buildTranscript([{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'done', tool: 'Bash', input: {}, result: { stdout: 'ok' } }] }])
  observeResponse(load, { uuid: 'tool', text: '', calls: ['done'] })
  observeResponse(load, { uuid: 'reply', text: 'Finished.', calls: [] })
  const cx = { ...context(), t, obs: load.obs, open: t.turns[0] }
  const row = { uuid: 'reply', text: 'Finished.', isFirstOfReply: true }
  expect(stepsOwner(callId('done'), cx)).toBe('pending')
  const pending = decideReply(row, cx)
  expect(pending).toEqual({ verdict: { body: 'engine', name: true }, claim: 'pending', live: true })
  expect(recordStepsClaim(load, row.uuid, pending.claim)).toBe(false)
  expect([...load.obs.stepsDrawn]).toEqual([])
  observeTurnComplete(load)
  const spent = { ...cx, open: undefined, phase: load.obs.phase }
  expect(stepsOwner(callId('done'), spent)).toBe('pending')
  const settled = decideReply(row, spent)
  expect(settled).toEqual({ verdict: { body: 'engine', name: true, stepsLine: { draw: 'turn', turn: 'done', done: 1, opened: false, body: [] } }, claim: 'drawn', live: false })
  expect(recordStepsClaim(load, row.uuid, settled.claim)).toBe(true)
  expect(stepsOwner(callId('done'), spent)).toEqual({ reply: 'reply' })
  expect(decideCall(call('done'), spent)).toEqual({ verdict: { draw: 'nothing' }, live: false })
  expect(decideReply(row, spent)).toEqual(settled)
  expect(recordStepsClaim(load, row.uuid, 'declined')).toBe(false)
  expect([...load.obs.stepsDrawn]).toEqual([['reply', true]])
})

test('reply claims settle in either evaluation order and fragments remain write-once', () => {
  const t = buildTranscript([{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'done', tool: 'Bash', input: {}, result: { stdout: 'ok' } }] }])
  const whole = { uuid: 'reply', text: 'Whole reply.', isFirstOfReply: true }
  const fragment = { ...whole, text: 'Whole' }
  const setup = () => {
    const load = newLoad()
    observeResponse(load, { uuid: 'tool', text: '', calls: ['done'] })
    observeResponse(load, { uuid: 'reply', text: 'Whole reply.', calls: [] })
    return { load, cx: { ...context(), t, obs: load.obs, open: t.turns[0] } }
  }
  for (const order of ['complete-first', 'reply-first', 'tool-first', 'live-fragment'] as const) {
    const { load, cx } = setup()
    if (order !== 'complete-first') {
      const pending = decideReply(order === 'live-fragment' ? fragment : whole, cx)
      expect(pending.claim).toBe('pending')
      expect(pending.live).toBe(true)
      expect(pending.verdict.stepsLine).toBeUndefined()
      expect(recordStepsClaim(load, 'reply', pending.claim)).toBe(false)
    }
    observeTurnComplete(load)
    const spent = { ...cx, phase: load.obs.phase, open: undefined }
    if (order === 'tool-first') expect(decideCall(call('done'), spent)).toEqual({ verdict: { draw: 'turn', turn: 'done', done: 1, opened: false, body: [] }, live: true })
    const settled = decideReply(whole, spent)
    expect(settled).toEqual({ verdict: { body: 'engine', name: true, stepsLine: { draw: 'turn', turn: 'done', done: 1, opened: false, body: [] } }, claim: 'drawn', live: false })
    expect(recordStepsClaim(load, 'reply', settled.claim)).toBe(true)
    expect(stepsOwner(callId('done'), spent)).toEqual({ reply: 'reply' })
    expect(decideCall(call('done'), spent)).toEqual({ verdict: { draw: 'nothing' }, live: false })
    expect(recordStepsClaim(load, 'reply', decideReply(whole, spent).claim)).toBe(false)
  }
  const { load, cx } = setup()
  observeTurnComplete(load)
  const spent = { ...cx, phase: load.obs.phase, open: undefined }
  const declined = decideReply(fragment, spent)
  expect(declined).toEqual({ verdict: { body: 'engine', name: false }, claim: 'declined', live: false })
  expect(recordStepsClaim(load, 'reply', declined.claim)).toBe(false)
  expect(decideReply(whole, spent)).toEqual({ verdict: { body: 'engine', name: true }, claim: 'declined', live: false })
  expect([...load.obs.stepsDrawn]).toEqual([['reply', false]])
  expect(stepsOwner(callId('done'), spent)).toBe('tool')
  const withHelper = buildTranscript([{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'done', tool: 'Bash', input: {}, result: {} }, { tool_use_id: 'helper', tool: 'Agent', input: {}, result: {} }] }])
  const pendingLoad = newLoad()
  observeResponse(pendingLoad, { uuid: 'tool', text: '', calls: ['done'] })
  observeResponse(pendingLoad, { uuid: 'reply', text: 'Whole reply.', calls: [] })
  expect(decideReply(whole, { ...cx, t: withHelper, obs: pendingLoad.obs, open: withHelper.turns[0] })).toEqual({ verdict: { body: 'engine', name: true }, claim: 'declined', live: false })
  expect(stepsOwner(callId('done'), { ...cx, t: withHelper, obs: pendingLoad.obs })).toBe('tool')
})

test('failed replies remain visible when said is hidden and desktop keeps the engine body', () => {
  const cx = context()
  const hidden = { ...cx, view: { ...cx.view, hide: ['said'] as const } }
  expect(decideReply({ uuid: 'error', text: 'API Error: Connection error.', isFirstOfReply: true }, hidden)).toEqual({ verdict: { body: { error: { head: 'Connection lost', rest: ['check your internet', 'send again to retry'], tone: 'amber', act: false } }, name: false }, claim: 'declined', live: false })
  expect(decideReply({ uuid: 'normal', text: 'Hello.', isFirstOfReply: true }, hidden)).toEqual({ verdict: { body: 'nothing', name: false }, claim: 'declined', live: false })
  expect(decideReply({ uuid: 'normal', text: 'Hello.', isFirstOfReply: true }, { ...cx, surface: 'desktop' })).toEqual({ verdict: { body: 'engine', name: false }, claim: 'declined', live: false })
})

function context(): Context {
  const t = buildTranscript([{ role: 'user', text: 'work', toolUses: [] }, { role: 'assistant', text: '', toolUses: [
    { tool_use_id: 'a', tool: 'Bash', input: {}, result: { stdout: 'ok' } },
    { tool_use_id: 'b', tool: 'Bash', input: {}, result: { stdout: 'ok' } },
    { tool_use_id: 'c', tool: 'Read', input: { file_path: '/repo/app.py' } },
  ] }])
  return { t, view: { group: true, clear: true, keep: false, style: 'subtle', commands: 'grouped', after: 'clear', hide: [] }, obs: newLoad().obs, opened: new Set(), open: t.turns[0], phase: 'live', agents: [], now: 10000, surface: 'terminal', clickable: true, room: 80 }
}

function call(id = 'a', tool = 'Bash', running = false): CallView {
  return { id: callId(id), tool, input: {}, isRunning: running, isErrored: false, isInterrupted: false }
}

test('rule 1 folds a live turn onto its first machinery call and counts only completed steps', () => {
  const cx = context()
  expect(decideCall(call(), cx)).toEqual({ verdict: { draw: 'turn', turn: 'a', done: 2, opened: false, body: [] }, live: true })
  expect(stepsLine(2)).toBe('· 2 steps')
  expect(decideCall(call('b'), cx)).toEqual({ verdict: { draw: 'nothing' }, live: true })
  expect(decideCall(call(), { ...cx, view: { ...cx.view, hide: ['tool'] } }).verdict).toEqual({ draw: 'turn', turn: 'a', done: 2, opened: false, body: [] })
})

test('a call the snapshot does not hold is live only while a turn is open, running or done', () => {
  const cx = context()
  expect(decideCall(call('unfiled', 'Read', true), cx)).toEqual({ verdict: { draw: 'nothing' }, live: true })
  expect(decideCall(call('unfiled', 'Read'), cx).live).toBe(true)
  const idle = { ...cx, open: undefined, phase: 'idle' as const }
  expect(decideCall(call('unfiled', 'Read'), idle).live).toBe(false)
  expect(decideCall({ ...call('unfiled', 'Read'), id: undefined }, idle).live).toBe(false)
  expect(decideGroup({ calls: [call('unfiled', 'Read'), call('other', 'Bash')], isActive: false, isExpanded: false, isCallsOnly: true }, idle).live).toBe(false)
})

test('rule 2 hides a spent turn when clear is on and keep and group are off', () => {
  const cx = context()
  expect(decideCall(call(), { ...cx, open: undefined, phase: 'idle', view: { ...cx.view, group: false } })).toEqual({ verdict: { draw: 'nothing' }, live: false })
})

test('rule 3 suppresses a still-running call when its kept turn is folded', () => {
  const cx = context()
  expect(decideCall(call('c', 'Read', true), { ...cx, open: undefined, phase: 'idle', view: { ...cx.view, keep: true } })).toEqual({ verdict: { draw: 'nothing' }, live: false })
})

test('rule 4 groups commands at the first run call and names its live call', () => {
  const cx = context()
  const normal = { ...cx, view: { ...cx.view, group: false, clear: false, keep: true, after: 'keep' as const } }
  const decision = decideCall(call(), normal)
  expect(decision.verdict.draw).toBe('run')
  if (decision.verdict.draw !== 'run') throw new Error('Rule 4 must select the run')
  expect(decision.verdict.naming).toBe('c')
  expect(decision.verdict.opened).toBe(false)
  expect(runWords(decision.verdict.run, cx.t)).toBe('Ran 2 shell commands · read 1 file')
  expect(decideCall(call('b'), normal)).toEqual({ verdict: { draw: 'nothing' }, live: true })
})

test('rule 5 collapses spent each-command rows when after is clear and keep is off', () => {
  const cx = context()
  const spent = { ...cx, open: undefined, phase: 'idle' as const, view: { ...cx.view, group: false, clear: false, commands: 'each' as const } }
  expect(decideCall(call(), spent).verdict.draw).toBe('run')
  expect(decideCall(call('b'), spent)).toEqual({ verdict: { draw: 'nothing' }, live: false })
})

test('rule 6 draws the call’s own words and honors expanded style', () => {
  const cx = context()
  const row = { ...call('c', 'Read', true), input: { file_path: '/repo/app.py' } }
  const decision = decideCall(row, { ...cx, view: { ...cx.view, group: false, commands: 'each', style: 'expanded' } })
  expect(decision.verdict.draw).toBe('call')
  if (decision.verdict.draw !== 'call') throw new Error('Rule 6 must select the call')
  expect(decision.verdict.opened).toBe(true)
  expect(callWords(decision.verdict.call, 'present')).toBe('Reading app.py')
})

test('standalone and unknown calls obey kind hiding and preserve observed helper timing', () => {
  const cx = context()
  expect(decideCall(call('unknown', 'Read', true), cx)).toEqual({ verdict: { draw: 'nothing' }, live: true })
  expect(decideCall(call('unknown', 'Read'), { ...cx, open: undefined }).verdict.draw).toBe('call')
  expect(decideCall(call('question', 'AskUserQuestion'), cx).verdict).toEqual({ draw: 'question', call: call('question', 'AskUserQuestion'), opened: false })
  const t = buildTranscript([{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'helper', tool: 'Agent', input: {}, agentId: 'worker', durationMs: 4000, result: {} }] }])
  expect(decideCall(call('helper', 'Agent'), { ...cx, t, open: undefined }).verdict).toEqual({ draw: 'helper', call: call('helper', 'Agent'), state: 'finished', elapsedMs: 4000 })
  expect(decideCall(call('helper', 'Agent'), { ...cx, t, agents: [{ id: 'worker', type: 'Explore', description: 'Read notes', status: 'running' }] }).verdict).toEqual({ draw: 'helper', call: call('helper', 'Agent'), state: 'running', elapsedMs: undefined })
  expect(decideCall(call('helper', 'Agent'), { ...cx, t, view: { ...cx.view, hide: ['agent'] } }).verdict).toEqual({ draw: 'nothing' })
  expect(decideCall(call('b'), { ...cx, view: { ...cx.view, group: false, hide: ['tool'] } }).verdict).toEqual({ draw: 'nothing' })
})

test('helper state derives all five states from call outcome and the agent list', () => {
  const t = buildTranscript([{ role: 'assistant', text: '', toolUses: [{ tool_use_id: 'helper', tool: 'Agent', input: {}, agentId: 'worker', durationMs: 4000, result: {} }] }])
  const filed = t.calls.get(callId('helper'))
  expect(helperState(call('helper', 'Agent', true), filed, [])).toBe('dispatched')
  expect(helperState(call('helper', 'Agent'), filed, [{ id: 'worker', description: 'Read notes', type: 'Explore', status: 'running' }])).toBe('running')
  expect(helperState(call('helper', 'Agent'), filed, [])).toBe('finished')
  expect(helperState({ ...call('helper', 'Agent'), isErrored: true }, filed, [])).toBe('failed')
  expect(helperState({ ...call('helper', 'Agent'), isInterrupted: true }, filed, [])).toBe('stopped')
})
