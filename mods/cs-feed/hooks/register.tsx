// ABOUTME: cs-feed mod: restyles the chat transcript ("the feed"). Always loaded, every hook always registered; a session whose .cs/local/feed is not exactly "on\n", or that cs -vet-session refuses, gets Claude Code's own drawing.
// ABOUTME: On/off comes from cs's band key (a ui.press hook reads the file after next) or /feed (writes it where cs -vet-session passes). PAINTERS is the one table of render sites; site() is the one caller of next().
import type { EngineInterface, On, RenderComponent, RenderElement, RenderInput, SessionMessage } from 'claude-code'

import { active, appendText, applyFeed, dirty, feedRecord, newLoad, noteStepsDrawn, noteWorking, observeAppend, observeModel, observeSpawn, observePrompt, observeTurnComplete, observeTurnStart, openTurn, readLive, readPulse, readTick, replaceResponseText, startClocks, toggle, transcript, writeFeed } from './session'
import type { Load } from './session'
import { modeOf, parseFeedArgs, transition } from './settings'
import type { FeedCommand } from './settings'
import { decideBand, decideCall, decideCommandOutput, decideGroup, decideHelpersPane, decideReply, decideSpinner, decideToolResult, decideUser, sessionModes } from './verdict'
import { callId } from './transcript'
import type { CallView, Clock, Context } from './verdict'
import { NOTHING, drawBand, drawCall, drawCommandOutput, drawGroup, drawHelpersPane, drawReply, drawSettingsPane, drawUser, inks } from './draw'
import type { Pen } from './draw'
import { commands, logs, replies } from './words'

type $ = EngineInterface

export const PANE = 'cs-feed'
export const HELPERS_PANE = 'cs-feed-helpers'

// One Load per module evaluation. A reload (a change of these files, such as a
// cs update) evaluates the module again and register() makes a new one; the
// old module keeps its own until its in-flight dispatches settle (spike Q1).
// A per-session toggle is not a reload: it is a file this load reads.
let load: Load = newLoad()

/**
 * No install switch: register() always
 * registers the one shape, and each hook returns the engine's drawing while
 * this session's feed is off. The off cost beside cs's three mods is spike4's
 * inert mod: +32 worker hops per three-turn scenario (24 ui.render, 8
 * session.append), about 1.6 ms p50 per new render hop, probably +8-10 ms at
 * each turn's end (not significant per run, n=6), +5 MB RSS. Accepted.
 */
export function register(on: On) {
  load = newLoad()
  registerFeed(on)
}

/** What /feed answers, and whether it changed nothing because the directory or cs refused (the settings pane logs those). */
type Answer = { readonly text: string; readonly refused: boolean }

/**
 * Carries out a typed /feed command or a settings-pane press for THIS session.
 * It never reloads and runs no command.
 *
 *   await feedRecord(load, $)                              // the mirror exists from here on (vetted at the load's on-read)
 *   if (cmd.kind === 'status') await applyFeed(load, $, 'status')   // status reports the file as vetted; a vet only for an outside flip to on
 *   const tr = transition(cmd, load.feed!)
 *   if (tr.session) {                                      // every write: on, off, a preset, a setting, hide/show, a chip, a pane row
 *     const done = await writeFeed(load, $, tr.session)    // asks cs -vet-session first (ruling §20.22)
 *     if (done === 'no-session') return { text: 'this directory is not a cs session (no .cs/local), so nothing changed.', refused: true }
 *     if (done !== 'written') return { text: `no feed change in this session: ${done.refused}`, refused: true }
 *   }
 *   if (tr.pane === 'open') await $.ui.open({ id: PANE, title: 'Chat view', focus: true })
 *   if (tr.pane === 'close') await $.ui.close({ id: PANE })
 *   return { text: tr.reply, refused: false }
 *
 * The texts carry no plugin name: the engine leads a command's output and a
 * `$.ui.log` line with it (`cs-feed: no feed change ...` on screen).
 *
 * A refusal writes nothing, leaves the mirror and the drawing as they were,
 * and says why in the reply: the refusal text is cs's own (session.vetRefusal),
 * in the pattern cs's band toasts it with ("cs: no rotation in this session:
 * <refusal>"). The
 * band's press asks the same cs rule with the same argv, so a session cs
 * refuses is refused by both writers. Bare /feed, /feed close and /feed status
 * write nothing and ask no vet of their own; the one cs process any of them
 * can cause is a read's (the load's feedRecord when it is the first asker, or
 * status's re-read finding an outside flip to on; ruling §20.22).
 *
 * /feed status re-reads FEED_FILE first because the mirror changes only at a
 * press, a /feed write or a load: after a hand edit, or a second Claude process
 * in this directory, it is stale. When the file differs, that read also redraws
 * this session to match (applyFeed's dirty() and invalidate); a flip to on that
 * no writer of ours vetted is vetted first, and a refusal reads off (logged
 * once, session.vetOnRead). The reply's first word is the mirror's after that
 * read: `off` in a session cs refuses, whatever the file says. The view half is
 * still the mirror's: applyFeed reads FEED_FILE only.
 *
 * writeFeed's read-back, not tr.session, sets the mirror, and its invalidate
 * redraws cs's band too (the label follows on its next redraw: inferred, see
 * session.applyFeed). /feed is `immediate`, so a typed /feed runs mid-turn at
 * once (spike3 M12: immediate lets a typed command run mid-turn).
 */
function perform($: $, cmd: FeedCommand): Promise<Answer> {
  if (cmd.kind === 'status' || cmd.kind === 'open' || cmd.kind === 'close' || cmd.kind === 'usage') return performNow($, cmd)
  const result = (load.writes ?? Promise.resolve()).then(() => performNow($, cmd))
  // The caller keeps result's rejection; the queue must still admit the next command.
  load.writes = result.then(() => undefined, () => undefined)
  return result
}

async function performNow($: $, cmd: FeedCommand): Promise<Answer> {
  await feedRecord(load, $)
  if (cmd.kind === 'status') await applyFeed(load, $, 'status')
  const current = load.feed
  if (!current) throw new Error('feed record did not settle')
  const changed = transition(cmd, current)
  if (changed.session) {
    const result = await writeFeed(load, $, changed.session)
    if (result === 'no-session') return { text: replies.notASession, refused: true }
    if (result !== 'written') return { text: replies.refused(result.refused), refused: true }
  }
  if (changed.pane === 'open') await $.ui.open({ id: PANE, title: 'Chat view', focus: true })
  if (changed.pane === 'close') await $.ui.close({ id: PANE })
  return { text: changed.reply, refused: false }
}

/**
 * The one shape. Nothing registered here awaits across a tool call or a
 * stream. Every hook is registered whatever this session's toggle says; the
 * toggle decides what they draw, never what is registered.
 *
 * Every hook body is a block (`=> { … }`), never an expression body: the cost
 * oracle's probe build inserts one counting statement at the top of each body
 * of a copy (Deploy touchpoints, finding 5). The probe script checks that it
 * inserted exactly as many as there are on() calls.
 */
function registerFeed(on: On) {
  // Commands do not survive a reload (spike Q2, measured): every load registers them.
  // cs's band shows the feed chord only while $.command.list() lists /feed from
  // plugin cs-feed, reads it when the band is evaluated (4-5 ms after a reloaded
  // plugin's session.start, spike3 M14), and nothing redraws the band when the
  // command list changes later. So both registrations are the FIRST statements,
  // issued before any await, and session.start settles (next) only after both
  // resolved. Nothing else may come before them. Not a manifest markdown command:
  // the band filters `source === 'plugin' && plugin === 'cs-feed'`, and /feed
  // must be answered by the command.run hook below; neither is measured for a
  // markdown command. /clear (cs's rotation) reloads nothing (spike3 M13: same
  // load, no session.start, /feed stays registered), so the gap exists only on a
  // true reload. Whether the band's post-reload evaluation waits for this hook to
  // settle is not measured (open-measurements M24).
  on('session.start', async ($, e, next) => {
    const feed = $.command.register(commands.feed)
    const helpers = $.command.register(commands.helpers)
    await Promise.all([feed, helpers])
    return next(e)
  })

  on('command.run', { command: 'feed' }, async ($, e) => {
    return { text: (await perform($, parseFeedArgs(e.args))).text }
  })

  on('command.run', { command: 'helpers' }, async ($) => {
    await $.ui.open({ id: HELPERS_PANE, title: 'Helpers', focus: true })
    return { text: replies.helpersOpen }
  })

  // cs's band key (`ctrl+x 3 feed`, Button key `cs-feed`, action strip:jump3).
  // next(e) resolves only after cs's onPress (pressFeed) promise settles
  // (spike5 M16: 64 of 64, idle and mid-turn, both --plugin-dir orders; with a
  // 400 ms sleep before the write, next took 403-415 ms). So the file read
  // straight after it is the post-press value, with no timer. Band-side
  // precondition: pressFeed awaits its $.fs.write before returning and the
  // Button's onPress returns pressFeed's promise (mods/cs/hooks/register.tsx
  // pressFeed and buildBandEntries, today). Work cs started without awaiting
  // would not be covered (inferred from the handler, spike5 "Not measured").
  // A press while one is pending gets that press's in-flight promise
  // (pressFeed is single-flight: `if (feedPressPending !== undefined) return
  // feedPressPending`) and writes nothing, so its next resolves after the first
  // press's write and both hooks read the same value. A press pressFeed refuses
  // (session not vetted, a write error) leaves the file as it is or torn; the
  // read says what both sides now show. This read is not vetted again
  // (ruling §20.22): pressFeed vetted before it wrote, so a flip to on read
  // here is the press's; an on that did not change keeps the load's cached
  // answer, so a session cs refused stays off (session.applyFeed 'press').
  // Measured alternative, not taken: an `fs.write` op hook sees the write
  // with e.text (M16), but it runs before the write lands and for every
  // fs.write of every plugin, where this runs for one Button.
  // Matcher literals: KEEP IN SYNC with settings.BAND_PLUGIN / BAND_ELEMENT (a kit test compares them).
  on('ui.press', { plugin: 'cs', element: 'cs-feed' }, async ($, e, next) => {
    const result = await next(e)
    await applyFeed(load, $, 'press')
    return result
  })

  // The two Pane bodies run ungated, whatever this session's toggle says: a
  // person opened them (/feed, /helpers). Their off cost: beside cs they join the
  // hop cs-update's bare { component: 'Pane' } hook already causes on every Pane
  // render; standalone they are new hops (host-side requestId selection is
  // open-measurements #4). spike4's inert probe had neither.
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    const session = load.feed ?? await feedRecord(load, $)
    await next(e)
    return drawSettingsPane(modeOf(session), session, { el: $.ui.resolve(e), ink: inks(load.light), room: e.props.bodyColumns }, async cmd => {
      const answer = await perform($, cmd)
      if (answer.refused) await $.ui.log(answer.text)
    })
  })

  // The Helpers pane (§7.4): the agent list, the main snapshot (for each
  // helper's Agent call: its spawn time and durationMs) and, for the newest 6,
  // each helper's own transcript. One that cannot be read leaves its head alone
  // (§7.4 (c)); its deny is logged. While a helper works the pane reads TICK
  // for its elapsed time and step.
  on('ui.render', { component: 'Pane', requestId: HELPERS_PANE }, async ($, e, next) => {
    await next(e)
    const agents = await $.agent.list()
    const t = await transcript(load, $)
    const shown = agents.filter(agent => !agent.parentId && !agent.teammateId).slice(-6)
    const own = new Map<string, readonly SessionMessage[] | undefined>()
    for (const agent of shown) {
      const rows = await $.session.messages({ agentId: agent.id })
      own.set(agent.id, Array.isArray(rows) ? rows : undefined)
      if (!Array.isArray(rows)) await $.ui.log(logs.helperUnread(agent.id, rows.deny))
    }
    const blocks = decideHelpersPane(shown, t, own, load.obs, Date.now())
    if (blocks.some(block => block.status === 'working')) await readTick($)
    return drawHelpersPane(blocks, { el: $.ui.resolve(e), ink: inks(load.light), room: e.props.bodyColumns })
  })

  // The transcript grew. One hook per door, never a bare session.append: sec-default
  // forwards attachment, hook-context, compaction, tool-message and org-plugin notes
  // past user mods (validate/verdicts.md G), and on a seat without it a bare hook would
  // be a worker hop for each of those rows too. These five are the doors whose rows
  // change what plain messages() holds or carry a fact the feed observes. A matcher
  // cannot say "no agentId", so each hook skips a helper's rows.
  //
  // Doors measured on 2.1.309 (spike Q4, spike2 M1, spike5 M19): a typed prompt, an
  // idle peer message (isMeta) and an idle task notification come on `prompt`; a
  // prompt, peer message or task notification delivered into a running turn comes on
  // `delivery` (type attachment, name queued_command). So the observers key on
  // e.origin.kind, not on the door. Teammate envelopes are inferred to share these
  // paths, not measured.
  //
  // Each observer records whatever this session's toggle says: the hop is paid
  // either way, and a flip on then finds phase and observations current.
  // dirty() schedules a refresh only while active(). No append hook calls
  // $.ui.invalidate (spike5 M18: it re-evaluates every selected instance).
  on('session.append', { door: 'prompt' }, async ($, e, next) => {
    const result = await next(e)
    if (e.agentId !== undefined) return result
    // Synchronous from here to the return: no await. spike5 M19 measured this
    // continuation running before turn.start, 0-1 ms later, which consumes it.
    observePrompt(load, { door: 'prompt', peer: e.origin.kind === 'peer', isMeta: e.message.isMeta === true })
    observeAppend(load, e)
    dirty(load, $)
    return result
  })
  on('session.append', { door: 'command' }, async ($, e, next) => {
    // A skill or slash invocation lands in plain messages() as a user entry and opens a turn (spike Q4). Dirty only.
    const result = await next(e)
    if (e.agentId === undefined) dirty(load, $)
    return result
  })
  on('session.append', { door: 'response' }, async ($, e, next) => {
    // BEFORE next, synchronously (uuid and tool_use blocks are pinned), so the
    // reply's first evaluation, +6-9 ms after this append (spike5 M18), finds it:
    if (e.agentId === undefined) observeModel(load, e.uuid, e.message.content)
    const result = await next(e)
    if (e.agentId !== undefined) return result
    if (result.message) replaceResponseText(load, e.uuid, appendText(result.message.content))
    dirty(load, $)
    return result
  })
  on('session.append', { door: 'tool-result' }, async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined) dirty(load, $)
    return result
  })
  on('session.append', { door: 'delivery' }, async ($, e, next) => {
    // Deliveries into a running turn (measured, spike2 M1). They never reach plain messages(),
    // so these observations are their only trace: the same observe(load.obs, e) by origin as
    // the prompt door (composer -> promptAt, peer -> bursts and frames, task-notification -> bgEnded).
    // A peer delivered mid-turn opens no turn, so peerPending is not touched here.
    const result = await next(e)
    if (e.agentId !== undefined) return result
    observeAppend(load, e)
    dirty(load, $)
    return result
  })

  // Consumes the prompt hook's peerPending (spike5 M19 order) into this turn's
  // record, and only then clears it, so the next response keeps its peer opener.
  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      observeTurnStart(load)
      dirty(load, $)
    }
    return next(e)
  })

  // Main loop only. A helper's end needs no event: its row's own props, ToolUseSummary.agentId
  // and durationMs, and $.agent.list() say it (verdict.helperState). Set at entry, before next.
  // Whether the final reply's first evaluation sees phase idle depends on the Stop hook: without one
  // turn.complete comes first (spike5 M18); with one it comes after both evaluations (spike4's rig,
  // 36 of 36 turns, M27), and the reply's claim is pending until this phase change's LIVE bump
  // re-evaluates it (ruling §20.23 (a)). verdict.stepsOwner is built for both orders.
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      observeTurnComplete(load)
      dirty(load, $)
    }
    return next(e)
  })

  // The one fact about a helper the transcript lacks: when a running one started.
  // It is also how the band learns of a helper without polling: the spawn asks
  // the next refresh to read $.agent.list(), and dirty() schedules it; a
  // changed Seen.helpers bumps LIVE, which the band reads while a turn is open
  // or a helper is known. A denied spawn started nothing.
  // Off cost: a new hop per helper spawn in every session, off included (no cs
  // mod hooks agent.spawn, and spike4's inert probe had none).
  on('agent.spawn', async ($, e, next) => {
    const result = await next(e)
    if (e.parentAgentId === undefined && result.deny === undefined) {
      observeSpawn(load, e.tool_use_id)
      dirty(load, $)
    }
    return result
  })

  sites(on, PAINTERS)
}

// ---------------------------------------------------------------------------
// The render sites: one table, one wrapper.
// ---------------------------------------------------------------------------

/** The sites the feed draws. AskUserQuestion, InfoNotice and PromptHint stay the engine's (ruling §20.13); Pane is hooked by requestId in both shapes. */
type Hooked = Exclude<RenderComponent, 'AskUserQuestion' | 'InfoNotice' | 'PromptHint' | 'Pane'>
type Props<C extends RenderComponent> = Partial<RenderInput<C>['props']>

/**
 * What a painter decides for one draw. Only site() turns it into calls of next():
 *   engine   next(e), props untouched
 *   rewrite  next with these props; the engine draws the row (its clock, tokens, cs's tip)
 *   frame    the engine's drawing (props rewritten when given) placed inside a tree of ours
 *   tree     ours; next(e) has still run, so observers beneath (cs's rail) saw the row
 *   nothing  no row; next(e) has still run
 */
export type Drawn<C extends RenderComponent> =
  | { readonly kind: 'engine' }
  | { readonly kind: 'rewrite'; readonly props: Props<C> }
  | { readonly kind: 'frame'; readonly props?: Props<C>; readonly frame: (drawn: RenderElement) => RenderElement }
  | { readonly kind: 'tree'; readonly tree: RenderElement }
  | { readonly kind: 'nothing' }

/** A decision, whether it was taken from the open turn's state (site() then reads LIVE), and the clock tokens it moves with (verdict.Clock). */
export type Decided<D> = { readonly drawn: D; readonly live: boolean; readonly claim?: import('./verdict').StepsClaim; readonly clock?: Clock }

/** A painter sees its row, the context and a pen. It has no `$` and no `next`: it cannot write, and it cannot skip the engine. */
export type Painter<C extends RenderComponent, D extends Drawn<C> = Drawn<C>> = (e: RenderInput<C>, cx: Context, pen: Pen) => Promise<Decided<D>>

/** The engine draws the row; we may only change its props. A replacing Spinner drops the cs tip (explore-cs 1.3, 0 of 60). */
export type RewriteOnly<C extends RenderComponent> = Extract<Drawn<C>, { kind: 'engine' | 'rewrite' }>
/** Ours goes around what next(e) drew (cs's band), never in its place. */
export type AroundOnly<C extends RenderComponent> = Extract<Drawn<C>, { kind: 'engine' | 'frame' }>

type Limits = {
  Spinner: RewriteOnly<'Spinner'>
  ToolProgress: RewriteOnly<'ToolProgress'>
  SessionMode: RewriteOnly<'SessionMode'>
  AbovePrompt: AroundOnly<'AbovePrompt'>
}
/** Every hooked site exactly once, each limited to what it may draw. A missing site, an extra one, or a Spinner painter that returns a tree is a compile error. */
export type PainterTable = { readonly [C in Hooked]: Painter<C, C extends keyof Limits ? Limits[C] : Drawn<C>> }

export const PAINTERS = {
  UserMessage: async (e, cx, pen) => {
    const { verdict, live } = decideUser({ ...e.props, uuid: e.requestId }, cx)
    return { drawn: verdict.draw === 'engine' ? { kind: 'engine' } : { kind: 'tree', tree: drawUser(verdict, pen) }, live }
  },
  AssistantMessage: async (e, cx, pen) => {
    // decideReply: error -> tree(error line); said hidden -> nothing;
    // else frame: props { isFirstOfReply: false } (no engine bullet), frame = drawn => drawReply(verdict, drawn, pen).
    // The markdown is the engine's (or cs-mermaid's) drawing in either load order.
    // Live only while the steps-line claim is pending (verdict.ReplyDecision,
    // ruling §20.23 (a)): the instance does not exist while the reply streams
    // and is evaluated twice once stored (spike5 M18), before turn.complete
    // when a Stop hook runs (M27); a pending reply reads LIVE, so the
    // turn.complete bump re-evaluates it and it settles the claim then. This
    // entry hands site() the claim with its Decided (the sketch leaves that
    // one field untyped on the table); site() records a settled claim
    // (session.noteStepsDrawn) and later evaluations reuse it (verdict.stepsOwner).
    const { verdict, live, claim } = decideReply({ ...e.props, uuid: e.requestId }, cx)
    return { drawn: { kind: 'frame', props: { isFirstOfReply: false }, frame: drawn => drawReply(verdict, drawn, pen) }, live, claim }
  },
  ToolUse: async (e, cx, pen) => {
    // decideCall(toCallView(e.props), cx) -> nothing | tree(drawCall). Under the default renderer a lone call
    // arrives here, under fullscreen as a one-call ToolGroup (spike2 M3): both go through decideCall.
    const { verdict, live, clock } = decideCall(toCallView(e.props), cx)
    return { drawn: { kind: 'tree', tree: drawCall(verdict, pen) }, live, clock }
  },
  ToolGroup: async (e, cx, pen) => {
    const { verdict, live, clock } = decideGroup({ ...e.props, calls: e.props.calls.map(toCallView) }, cx)
    return { drawn: verdict.draw === 'engine' ? { kind: 'engine' } : { kind: 'tree', tree: drawGroup(verdict, pen) }, live, clock }
  },
  ToolResult: async (e, cx, pen) => {
    return { drawn: { kind: decideToolResult(callId(e.props.tool_use_id), e.props.isExpanded, cx) }, live: false }
  },
  ToolProgress: async () => ({ drawn: { kind: 'rewrite', props: { hint: '' } }, live: false }),
  TurnDuration: async () => ({ drawn: { kind: 'nothing' }, live: false }),
  CommandOutput: async (e, cx, pen) => {
    const verdict = decideCommandOutput(e.props, cx)
    return { drawn: typeof verdict === 'string' ? { kind: verdict } : { kind: 'tree', tree: drawCommandOutput(verdict, pen) }, live: false }
  },
  Spinner: async (e, cx) => {
    // The working line: the engine's own row with our words as its message, never a tree of ours.
    // "Writing" comes from the row's own mode ('responding'), not from the transcript: the reply's
    // row is stored only once it has streamed (spike5 M18), too late for the line it names.
    const { verdict, live, clock } = decideSpinner(e.props, cx)
    return { drawn: verdict.draw === 'rewrite' ? { kind: 'rewrite', props: { message: verdict.message, suffix: '' } } : { kind: 'engine' }, live, clock }
  },
  SessionMode: async (e, cx) => {
    return { drawn: { kind: 'rewrite', props: { modes: sessionModes(e.props.modes, cx.view) } }, live: false }
  },
  AbovePrompt: async (e, cx, pen) => {
    // Ours ABOVE what next(e) drew, cs's band included; the tokens it reads are the decision's (decideBand).
    const { verdict, live, clock } = decideBand(e.props, cx.usage ?? {}, cx)
    return { drawn: verdict.draw === 'engine' ? { kind: 'engine' } : { kind: 'frame', frame: beneath => drawBand(verdict, beneath, Math.floor(cx.now / 70), pen) }, live, clock }
  },
} satisfies PainterTable

/**
 * The only way this mod hooks a render site, so the composition rules hold by
 * construction rather than by each painter remembering them. sites() declares
 * literal matchers for the host's static scan and delegates every evaluation
 * here. The engine's matcher union does not accept a generic component value;
 * literal declarations also give validate an exact component inventory.
 *
 *   - next(e) runs exactly once per draw, whatever the decision. `engine(p?)`
 *     calls it (with props rewritten when given) and memoises; the `finally`
 *     calls it if nothing else did. An inner hook (cs's UserMessage rail
 *     observer, cs's band, cs-mermaid) therefore always runs, whichever order
 *     the user-tier plugins load in (CS:464-475, T:13457).
 *   - this session's feed off, or the row's own isExpanded (ctrl+o, --verbose)
 *     returns the engine's drawing with props untouched (§10, per row: no module
 *     flag). The off check reads the per-load mirror (session.feedRecord), not
 *     the file, so off costs the hop and next(e), no op; applyFeed() invalidates
 *     on every flip. The mirror says off in a session cs -vet-session refuses,
 *     whatever the file says (ruling §20.22). Until the load's record settles,
 *     every evaluation awaits it here, before next(e) and before context():
 *     in an on-session that wait holds the load's vet (one cs process,
 *     0.15-0.44 s), so the first painted draw after a load waits for it before
 *     the refresh's two messages() reads (Q-idle-delivery option B).
 *   - a decision that is `live` reads LIVE, subscribing this instance alone to
 *     the next refresh; one with a `clock` reads TICK or PULSE (or both), only
 *     while what it draws moves; every other row is never redrawn by the
 *     feed's own updates.
 *   - a throw draws the engine's component (IDX:4102); next has already run.
 *   - for AssistantMessage, the reply's steps-line claim is recorded once,
 *     when it settles (noteStepsDrawn after the painter returns, claim
 *     'drawn' or 'declined'; a 'pending' claim records nothing and its
 *     decision is live): module memory, plus at most one $.clock.after(0)
 *     LIVE bump. Nothing else a render does writes.
 *
 *   on('ui.render', { component }, async ($, e, next) => {
 *     let drawn: Promise<RenderElement> | undefined
 *     const engine = (p?) => (drawn ??= next(p ? { ...e, props: { ...e.props, ...p } } : e))
 *     try {
 *       if (e.component === 'AbovePrompt') noteWorking(load, $, e.props.isWorking)   // the phase stays settled while off
 *       if (ownExpanded(e)) return await engine()
 *       const s = load.feed ?? await feedRecord(load, $)   // in an on-session the load's vet (one cs process) is awaited here
 *       if (!s.on) return await engine()
 *       const cx = await context($, e, s)
 *       const { drawn: d, live, clock } = await paint(e, cx, pen($, e, cx))
 *       if (live) await read($, LIVE)
 *       if (clock is 'tick' or 'both') await read($, TICK)     // an elapsed time or a polled count it shows
 *       if (clock is 'pulse' or 'both') await read($, PULSE)   // an animation it shows
 *       switch (d.kind) {
 *         case 'engine':  return await engine()
 *         case 'rewrite': return await engine(d.props)
 *         case 'frame':   return d.frame(await engine(d.props))
 *         case 'tree':    await engine(); return d.tree
 *         case 'nothing': await engine(); return NOTHING(pen)
 *       }
 *     } finally {
 *       await engine()
 *     }
 *   })
 */
async function site<C extends Hooked>($: $, e: RenderInput<C>, next: (e: RenderInput<C>) => Promise<RenderElement>, paint: Painter<C>): Promise<RenderElement> {
    let drawn: Promise<RenderElement> | undefined
    const engine = (props?: Props<C>) => drawn ??= next(props ? { ...e, props: { ...e.props, ...props } } : e)
    try {
      if ('isWorking' in e.props) noteWorking(load, $, e.props.isWorking)
      if ('isExpanded' in e.props && e.props.isExpanded) return await engine()
      const session = load.feed ?? await feedRecord(load, $)
      if (!session.on) return await engine()
      const cx = await context($, e, session)
      const pen: Pen = {
        el: $.ui.resolve(e), ink: inks(load.light), room: cx.room,
        pad: e.surface === 'terminal' ? 2 : 0, clickable: cx.clickable,
        press: key => toggle(load, $, key),
        helpers: async () => { await $.ui.open({ id: HELPERS_PANE, title: 'Helpers', focus: true }) }, cx,
      }
      const decision = await paint(e as RenderInput<C>, cx, pen)
      if (e.component === 'AssistantMessage' && decision.claim !== undefined && decision.claim !== 'pending') noteStepsDrawn(load, $, e.requestId, decision.claim === 'drawn')
      if (decision.live) await readLive($)
      if (decision.clock === 'tick' || decision.clock === 'both') await readTick($)
      if (decision.clock === 'pulse' || decision.clock === 'both') await readPulse($)
      switch (decision.drawn.kind) {
        case 'engine': return await engine()
        case 'rewrite': return await engine(decision.drawn.props)
        case 'frame': return decision.drawn.frame(await engine(decision.drawn.props))
        case 'tree': await engine(); return decision.drawn.tree
        case 'nothing': await engine(); return NOTHING(pen)
      }
    } finally {
      await engine()
    }
}

/** Installs every typed table entry through site(), with literal matchers for the engine's scan. */
function sites(on: On, table: PainterTable): void {
  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => { return site<'UserMessage'>($, e, next, table.UserMessage) })
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => { return site<'AssistantMessage'>($, e, next, table.AssistantMessage) })
  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => { return site<'ToolUse'>($, e, next, table.ToolUse) })
  on('ui.render', { component: 'ToolGroup' }, async ($, e, next) => { return site<'ToolGroup'>($, e, next, table.ToolGroup) })
  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => { return site<'ToolResult'>($, e, next, table.ToolResult) })
  on('ui.render', { component: 'ToolProgress' }, async ($, e, next) => { return site<'ToolProgress'>($, e, next, table.ToolProgress) })
  on('ui.render', { component: 'TurnDuration' }, async ($, e, next) => { return site<'TurnDuration'>($, e, next, table.TurnDuration) })
  on('ui.render', { component: 'CommandOutput' }, async ($, e, next) => { return site<'CommandOutput'>($, e, next, table.CommandOutput) })
  on('ui.render', { component: 'Spinner' }, async ($, e, next) => { return site<'Spinner'>($, e, next, table.Spinner) })
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => { return site<'SessionMode'>($, e, next, table.SessionMode) })
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => { return site<'AbovePrompt'>($, e, next, table.AbovePrompt) })
}

/**
 * What every painter reads, built once per painted draw: this session's view
 * (from the record site() already holds) + transcript snapshot + open turn +
 * observations. site() has noted the band's `isWorking` before this (the one
 * place a render prop feeds the load); this starts the clocks on a painted draw.
 * It awaits transcript(), which starts the refresh itself when one is only
 * scheduled (session.Snap), so a first draw never takes a snapshot older than
 * the dirty() that preceded it.
 *
 *   startClocks(load, $)
 *   const t = await transcript(load, $)
 *   { t, view: s.view, obs: load.obs, opened: load.opened, open: openTurn(load, t), phase: load.obs.phase,
 *     agents: load.agents, now: Date.now(), surface: e.surface,
 *     clickable: e.surface !== 'terminal' || !!e.viewport?.isFullscreen, room: (e.viewport?.columns ?? 80) - pad,
 *     usage: the desktop band's rate limits, one $.session.usage() per desktop AbovePrompt draw }
 */
async function context($: $, e: RenderInput, s: import('./settings').Session): Promise<Context> {
  const desktopBand = e.component === 'AbovePrompt' && e.surface === 'desktop'
  startClocks(load, $, desktopBand)
  const t = await transcript(load, $)
  return {
    t, view: s.view, obs: load.obs, opened: load.opened, open: openTurn(load, t),
    phase: load.obs.phase, agents: load.agents, now: Date.now(), surface: e.surface,
    clickable: e.surface !== 'terminal' || e.viewport?.isFullscreen === true,
    room: Math.max(1, (e.viewport?.columns ?? 80) - (e.surface === 'terminal' ? 7 : 0)),
    usage: desktopBand ? bandUsage(await $.session.usage()) : undefined,
  }
}

/** §9.2 (b): the desktop band's two rate-limit windows, from session.usage (five_hour, seven_day); a window with no reading is left out. */
function bandUsage(usage: import('claude-code').SessionUsage): { fiveHour?: number; week?: number } {
  const percent = (kind: string) => usage.rateLimits.find(limit => limit.kind === kind)?.percentUsed
  return { fiveHour: percent('five_hour'), week: percent('seven_day') }
}

/** ToolUse props or one ToolGroupCall, parsed at the boundary. */
function toCallView(call: unknown): CallView {
  if (!call || typeof call !== 'object' || Array.isArray(call) || !('tool' in call) || typeof call.tool !== 'string') throw new Error('tool row has no tool name')
  const row = call as Record<string, unknown>
  return {
    id: typeof row.tool_use_id === 'string' && row.tool_use_id ? callId(row.tool_use_id) : undefined,
    tool: call.tool,
    input: row.input && typeof row.input === 'object' && !Array.isArray(row.input) ? row.input as Record<string, unknown> : {},
    isRunning: row.isRunning === true, isErrored: row.isErrored === true, isInterrupted: row.isInterrupted === true, output: row.output,
  }
}
