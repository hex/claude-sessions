// ABOUTME: cs-clean-chat mod: while clean chat is on in this session, the chat shows your messages and Claude's replies and nothing of the work between them. On by default; a session cs -vet-session refuses gets Claude Code's own drawing.
// ABOUTME: On/off comes from cs's band key (a ui.press hook reads the file after next) or /clean-chat. PAINTERS is the one table of render sites; site() is the one caller of next().
import type { EngineInterface, On, RenderComponent, RenderElement, RenderInput } from 'claude-code'

import { applyCleanChat, cleanChatRecord, newLoad, readCleanChat, writeCleanChat } from './session'
import type { Load } from './session'
import { parseCleanChatArgs } from './settings'
import type { CleanChatCommand } from './settings'
import { decideCommandOutput, decideUser, sessionModes } from './verdict'
import { NOTHING, drawCommandOutput, drawError, drawReply, drawUser, inks } from './draw'
import type { Pen } from './draw'
import { commands, errorLine, replies } from './words'

type $ = EngineInterface

// One Load per module evaluation. A reload (a change of these files, such as a
// cs update) evaluates the module again and register() makes a new one; the
// old module keeps its own until its in-flight dispatches settle (spike Q1).
// A per-session toggle is not a reload: it is a file this load reads.
let load: Load = newLoad()

/** No install switch: register() always registers the one shape, and each render hook returns the engine's drawing while clean chat is off in this session. */
export function register(on: On) {
  load = newLoad()
  registerCleanChat(on)
}

/**
 * Carries out a typed /clean-chat command for THIS session and returns its
 * reply. It never reloads and runs no command.
 *
 *   usage                             replies.usage; reads nothing
 *   await cleanChatRecord(load, $)    the mirror exists from here on (vetted at the load's on-read)
 *   status                            applyCleanChat(load, $, 'status'), then `on` or `off` as vetted
 *   toggle                            the file's value read again and flipped (not the mirror's: a hand edit is
 *                                     followed), then written as `switch` writes it
 *   switch                            writeCleanChat: asks cs -vet-session first (ruling §20.22); refused, nothing is written
 *
 * The texts carry no plugin name: the engine leads a command's output with it
 * (`cs-clean-chat: no clean chat change ...` on screen). A refusal writes nothing, leaves
 * the mirror and the drawing as they were, and says why in the reply: the
 * refusal text is cs's own (session.vetRefusal). The band's press asks the
 * same cs rule with the same argv, so a session cs refuses is refused by both
 * writers.
 *
 * Writing commands queue on load.writes, so a second /clean-chat reads the
 * file the first one wrote. /clean-chat is `immediate`, so a typed
 * /clean-chat runs mid-turn at once (spike3 M12).
 */
function perform($: $, cmd: CleanChatCommand): Promise<string> {
  if (cmd.kind === 'status' || cmd.kind === 'usage') return performNow($, cmd)
  const result = (load.writes ?? Promise.resolve()).then(() => performNow($, cmd))
  // The caller keeps result's rejection; the queue must still admit the next command.
  load.writes = result.then(() => undefined, () => undefined)
  return result
}

async function performNow($: $, cmd: CleanChatCommand): Promise<string> {
  if (cmd.kind === 'usage') return replies.usage
  await cleanChatRecord(load, $)
  if (cmd.kind === 'status') {
    await applyCleanChat(load, $, 'status')
    if (load.on === undefined) throw new Error('clean chat record did not settle')
    return replies.status(load.on)
  }
  const on = cmd.kind === 'switch' ? cmd.on : !(await readCleanChat(load, $, await $.session.cwd()))
  const result = await writeCleanChat(load, $, on)
  if (result === 'no-session') return replies.notASession
  if (result !== 'written') return replies.refused(result.refused)
  return replies.switched(on)
}

/**
 * The one shape. Nothing registered here awaits across a tool call or a
 * stream. Every hook is registered whatever this session's switch says; the
 * switch decides what they draw, never what is registered.
 */
function registerCleanChat(on: On) {
  // Commands do not survive a reload (spike Q2, measured): every load registers it.
  // cs's band shows the clean chat key only while $.command.list() lists
  // /clean-chat from plugin cs-clean-chat, reads it when the band is evaluated
  // (4-5 ms after a reloaded plugin's session.start, spike3 M14), and nothing
  // redraws the band when the command list changes later. So the registration
  // is the FIRST statement, issued before any await, and session.start settles
  // (next) only after it resolved. Not a manifest markdown command: the band
  // filters `source === 'plugin' && plugin === 'cs-clean-chat'`, and
  // /clean-chat must be answered by the command.run hook below. /clear (cs's
  // rotation) reloads nothing (spike3 M13: same load, no session.start,
  // /clean-chat stays registered).
  on('session.start', async ($, e, next) => {
    await $.command.register(commands.cleanChat)
    return next(e)
  })

  on('command.run', { command: 'clean-chat' }, async ($, e) => {
    return { text: await perform($, parseCleanChatArgs(e.args)) }
  })

  // cs's band key (`clean chat`, Button key `cs-clean-chat`, pressed by a
  // click or the band's focus). next(e) resolves only after cs's onPress
  // (pressCleanChat) promise settles (spike5 M16: 64 of 64, idle and
  // mid-turn, both --plugin-dir orders), so the file read straight after it
  // is the post-press value, with no timer. Band-side precondition:
  // pressCleanChat awaits its $.fs.write before returning and the Button's
  // onPress returns pressCleanChat's promise. A press while one is pending
  // gets that press's in-flight promise (pressCleanChat is single-flight) and
  // writes nothing, so both hooks read the same value. A press pressCleanChat
  // refuses (session not vetted, a write error) leaves the file as it is or
  // torn; the read says what both sides now show. This read is not vetted
  // again (ruling §20.22): pressCleanChat vetted before it wrote, so a flip
  // to on read here is the press's; an on that did not change keeps the
  // load's cached answer, so a session cs refused stays off
  // (session.applyCleanChat 'press').
  // Matcher literals: KEEP IN SYNC with settings.BAND_PLUGIN / BAND_ELEMENT (a kit test compares them).
  on('ui.press', { plugin: 'cs', element: 'cs-clean-chat' }, async ($, e, next) => {
    const result = await next(e)
    await applyCleanChat(load, $, 'press')
    return result
  })

  sites(on, PAINTERS)
}

// ---------------------------------------------------------------------------
// The render sites: one table, one wrapper.
// ---------------------------------------------------------------------------

/**
 * The sites clean chat draws. AskUserQuestion, InfoNotice and PromptHint stay
 * the engine's (ruling §20.13), and so do the working line (Spinner, Claude
 * Code's own liveness signal) and the row above the prompt (AbovePrompt,
 * cs's band). Pane is no site: clean chat opens none.
 */
type Hooked = Exclude<RenderComponent, 'AskUserQuestion' | 'InfoNotice' | 'PromptHint' | 'Pane' | 'Spinner' | 'AbovePrompt'>
type Props<C extends RenderComponent> = Partial<RenderInput<C>['props']>

/**
 * What a painter decides for one draw. Only site() turns it into calls of next():
 *   engine   next(e), props untouched
 *   rewrite  next with these props; the engine draws the row
 *   frame    the engine's drawing (props rewritten when given) placed inside a tree of ours
 *   tree     ours; next(e) has still run, so observers beneath (cs's rail) saw the row
 *   nothing  the engine's nothing, an empty Box; next(e) has still run
 */
export type Drawn<C extends RenderComponent> =
  | { readonly kind: 'engine' }
  | { readonly kind: 'rewrite'; readonly props: Props<C> }
  | { readonly kind: 'frame'; readonly props?: Props<C>; readonly frame: (drawn: RenderElement) => RenderElement }
  | { readonly kind: 'tree'; readonly tree: RenderElement }
  | { readonly kind: 'nothing' }

/** A painter sees its row and a pen. It has no `$` and no `next`: it cannot write, and it cannot skip the engine. */
export type Painter<C extends RenderComponent, D extends Drawn<C> = Drawn<C>> = (e: RenderInput<C>, pen: Pen) => D

/** The engine draws the row; we may only change its props. */
export type RewriteOnly<C extends RenderComponent> = Extract<Drawn<C>, { kind: 'engine' | 'rewrite' }>

type Limits = {
  SessionMode: RewriteOnly<'SessionMode'>
}
/** Every hooked site exactly once, each limited to what it may draw. A missing site, an extra one, or a SessionMode painter that returns a tree is a compile error. */
export type PainterTable = { readonly [C in Hooked]: Painter<C, C extends keyof Limits ? Limits[C] : Drawn<C>> }

export const PAINTERS = {
  UserMessage: (e, pen) => {
    const verdict = decideUser(e.props, e.surface)
    return verdict.draw === 'you' ? { kind: 'tree', tree: drawUser(verdict, pen) } : { kind: verdict.draw }
  },
  AssistantMessage: (e, pen) => {
    // The markdown is the engine's (or cs-mermaid's) drawing in either load
    // order, with isFirstOfReply rewritten to false so it draws no bullet of its own.
    const error = errorLine(e.props.text)
    return error ? { kind: 'tree', tree: drawError(error, pen) } : { kind: 'frame', props: { isFirstOfReply: false }, frame: drawn => drawReply(drawn, pen) }
  },
  ToolUse: () => ({ kind: 'nothing' }),
  ToolGroup: () => ({ kind: 'nothing' }),
  ToolResult: () => ({ kind: 'nothing' }),
  ToolProgress: () => ({ kind: 'nothing' }),
  TurnDuration: () => ({ kind: 'nothing' }),
  CommandOutput: (e, pen) => {
    const verdict = decideCommandOutput(e.props)
    return verdict === 'nothing' ? { kind: 'nothing' } : { kind: 'tree', tree: drawCommandOutput(verdict, pen) }
  },
  SessionMode: (e) => ({ kind: 'rewrite', props: { modes: sessionModes(e.props.modes) } }),
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
 *     observer, cs-mermaid) therefore always runs, whichever order the
 *     user-tier plugins load in (CS:464-475, T:13457).
 *   - the row's own isExpanded (ctrl+o, --verbose) returns the engine's
 *     drawing with props untouched (§10, per row: no module flag), so the
 *     detailed view still shows everything.
 *   - clean chat off in this session returns the engine's drawing too. The
 *     check reads the per-load mirror (session.cleanChatRecord), not the
 *     file, so off costs the hop and next(e), no op; applyCleanChat()
 *     invalidates on every flip. The mirror says off in a session cs -vet-session refuses,
 *     whatever the file says (ruling §20.22). Until the load's record
 *     settles, every evaluation awaits it here: in a session whose file reads
 *     on, absent included, that wait holds the load's vet (one cs process,
 *     0.15-0.44 s).
 *   - a throw draws the engine's component (IDX:4102); next has already run.
 */
async function site<C extends Hooked>($: $, e: RenderInput<C>, next: (e: RenderInput<C>) => Promise<RenderElement>, paint: Painter<C>): Promise<RenderElement> {
  let drawn: Promise<RenderElement> | undefined
  const engine = (props?: Props<C>) => drawn ??= next(props ? { ...e, props: { ...e.props, ...props } } : e)
  try {
    if ('isExpanded' in e.props && e.props.isExpanded) return await engine()
    const on = load.on ?? await cleanChatRecord(load, $)
    if (!on) return await engine()
    const pen: Pen = { el: $.ui.resolve(e), ink: inks(load.light), pad: e.surface === 'terminal' ? 2 : 0 }
    const decision = paint(e, pen)
    switch (decision.kind) {
      case 'engine': return await engine()
      case 'rewrite': return await engine(decision.props)
      case 'frame': return decision.frame(await engine(decision.props))
      case 'tree': await engine(); return decision.tree
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
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => { return site<'SessionMode'>($, e, next, table.SessionMode) })
}
