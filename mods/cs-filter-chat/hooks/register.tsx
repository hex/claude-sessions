// ABOUTME: cs-filter-chat mod: while filter chat is on in this session, the chat shows your messages and Claude's replies and nothing of the work between them. Off by default; a session cs -vet-session refuses gets Claude Code's own drawing.
// ABOUTME: On/off comes from cs's key under the prompt (a ui.press hook reads the setting after next) or /filter-chat. PAINTERS is the one table of render sites; site() is the one caller of next().
import type { EngineInterface, On, PluginOptions, RenderComponent, RenderElement, RenderInput } from 'claude-code'

import { applyFilterChat, filterChatRecord, newLoad, readFilterChat, writeFilterChat } from './session'
import type { Load } from './session'
import { parseFilterChatArgs, youInkOf } from './settings'
import type { FilterChatCommand } from './settings'
import { decideCommandOutput, decideUser, sessionModes } from './verdict'
import { INKS, NOTHING, drawCommandOutput, drawError, drawReply, drawUser } from './draw'
import type { Inks, Pen } from './draw'
import { commands, errorLine, replies } from './words'

type $ = EngineInterface

// One Load per module evaluation. A reload (a change of these files, such as a
// cs update) evaluates the module again and register() makes a new one; the
// old module keeps its own until its in-flight dispatches settle (spike Q1).
// A per-session toggle is not a reload: it is a setting this load reads.
let load: Load = newLoad()

/**
 * No install switch: register() always registers the one shape, and each render
 * hook returns the engine's drawing while filter chat is off in this session.
 * `options` carries only the you ink (the /config row cs-filter-chat.youInk).
 * Claude Code reloads the mod when it changes and calls register() again with
 * the new value; the hooks close over each call's inks.
 */
export function register(on: On, options: PluginOptions) {
  const ink: Inks = { ...INKS, you: youInkOf(options) }
  load = newLoad()
  registerFilterChat(on, ink)
}

/**
 * Carries out a typed /filter-chat command for THIS session and returns its
 * reply. It never reloads and runs no command.
 *
 *   usage                             replies.usage; reads nothing
 *   await filterChatRecord(load, $)    the mirror exists from here on (vetted at the load's on-read)
 *   status                            applyFilterChat(load, $, 'status'), then `on` or `off` as vetted
 *   toggle                            the setting's value read again and flipped (not the mirror's: a hand edit is
 *                                     followed), then written as `switch` writes it
 *   switch                            writeFilterChat: asks cs -vet-session first (ruling §20.22); refused, nothing is written
 *
 * The texts carry no plugin name: the engine leads a command's output with it
 * (`cs-filter-chat: no filter chat change ...` on screen). A refusal writes nothing, leaves
 * the mirror and the drawing as they were, and says why in the reply: the
 * refusal text is cs's own (session.vetRefusal). The band's press asks the
 * same cs rule with the same argv, so a session cs refuses is refused by both
 * writers.
 *
 * Writing commands queue on load.writes, so a second /filter-chat reads the
 * file the first one wrote. /filter-chat is `immediate`, so a typed
 * /filter-chat runs mid-turn at once (spike3 M12).
 */
function perform($: $, cmd: FilterChatCommand): Promise<string> {
  if (cmd.kind === 'status' || cmd.kind === 'usage') return performNow($, cmd)
  const result = (load.writes ?? Promise.resolve()).then(() => performNow($, cmd))
  // The caller keeps result's rejection; the queue must still admit the next command.
  load.writes = result.then(() => undefined, () => undefined)
  return result
}

async function performNow($: $, cmd: FilterChatCommand): Promise<string> {
  if (cmd.kind === 'usage') return replies.usage
  await filterChatRecord(load, $)
  if (cmd.kind === 'status') {
    await applyFilterChat(load, $, 'status')
    if (load.on === undefined) throw new Error('filter chat record did not settle')
    return replies.status(load.on)
  }
  const on = cmd.kind === 'switch' ? cmd.on : !(await readFilterChat(load, $, await $.session.cwd()))
  const result = await writeFilterChat(load, $, on)
  if (result === 'no-session') return replies.notASession
  if (result !== 'written') return replies.refused(result.refused)
  return load.on === on ? replies.switched(on) : replies.pinned(!on)
}

/**
 * The one shape. Nothing registered here awaits across a tool call or a
 * stream. Every hook is registered whatever this session's switch says; the
 * switch decides what they draw, never what is registered.
 */
function registerFilterChat(on: On, ink: Inks) {
  // Commands do not survive a reload (spike Q2, measured): every load registers it.
  // cs's band shows the filter chat key only while $.command.list() lists
  // /filter-chat from plugin cs-filter-chat, reads it when the band is evaluated
  // (4-5 ms after a reloaded plugin's session.start, spike3 M14), and nothing
  // redraws the band when the command list changes later. So the registration
  // is the FIRST statement, issued before any await, and session.start settles
  // (next) only after it resolved. Not a manifest markdown command: the band
  // filters `source === 'plugin' && plugin === 'cs-filter-chat'`, and
  // /filter-chat must be answered by the command.run hook below. /clear (cs's
  // rotation) reloads nothing (spike3 M13: same load, no session.start,
  // /filter-chat stays registered).
  on('session.start', async ($, e, next) => {
    await $.command.register(commands.filterChat)
    return next(e)
  })

  on('command.run', { command: 'filter-chat' }, async ($, e) => {
    return { text: await perform($, parseFilterChatArgs(e.args)) }
  })

  // cs's key under the prompt (`filter chat`, Button key `cs-filter-chat`,
  // pressed by a click). next(e) resolves only after cs's onPress
  // (pressFilterChat) promise settles (spike5 M16: 64 of 64, idle and
  // mid-turn, both --plugin-dir orders), so the setting read straight after it
  // is the post-press value, with no timer. Band-side precondition:
  // pressFilterChat awaits its cs write before returning and the Button's
  // onPress returns pressFilterChat's promise. A press while one is pending
  // gets that press's in-flight promise (pressFilterChat is single-flight) and
  // writes nothing, so both hooks read the same value. A press pressFilterChat
  // refuses (session not vetted, a write error) leaves the setting as it is;
  // the read says what both sides now show. This read is not vetted
  // again (ruling §20.22): pressFilterChat vetted before it wrote, so a flip
  // to on read here is the press's; an on that did not change keeps the
  // load's cached answer, so a session cs refused stays off
  // (session.applyFilterChat 'press').
  // Matcher literals: KEEP IN SYNC with settings.BAND_PLUGIN / BAND_ELEMENT (a kit test compares them).
  on('ui.press', { plugin: 'cs', element: 'cs-filter-chat' }, async ($, e, next) => {
    const result = await next(e)
    await applyFilterChat(load, $, 'press')
    return result
  })

  sites(on, PAINTERS, ink)
}

// ---------------------------------------------------------------------------
// The render sites: one table, one wrapper.
// ---------------------------------------------------------------------------

/**
 * The sites filter chat draws. AskUserQuestion, InfoNotice and PromptHint stay
 * the engine's (ruling §20.13), and so does the row above the prompt
 * (AbovePrompt, cs's band) and the working line (Spinner, Claude Code's own
 * animated sign that a turn runs). Pane is no site: filter chat opens none.
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
 *   - filter chat off in this session returns the engine's drawing too. The
 *     check reads the per-load mirror (session.filterChatRecord), not the
 *     file, so off costs the hop and next(e), no op; applyFilterChat()
 *     invalidates on every flip. The mirror says off in a session cs -vet-session refuses,
 *     whatever the setting says (ruling §20.22). Until the load's record
 *     settles, every evaluation awaits it here: in a session whose setting reads
 *     on, that wait holds the load's vet (one cs process,
 *     0.15-0.44 s).
 *   - a throw draws the engine's component (IDX:4102); next has already run.
 */
async function site<C extends Hooked>($: $, e: RenderInput<C>, next: (e: RenderInput<C>) => Promise<RenderElement>, paint: Painter<C>, ink: Inks): Promise<RenderElement> {
  let drawn: Promise<RenderElement> | undefined
  const engine = (props?: Props<C>) => drawn ??= next(props ? { ...e, props: { ...e.props, ...props } } : e)
  try {
    if ('isExpanded' in e.props && e.props.isExpanded) return await engine()
    const on = load.on ?? await filterChatRecord(load, $)
    if (!on) return await engine()
    const pen: Pen = { el: $.ui.resolve(e), ink, pad: e.surface === 'terminal' ? 2 : 0 }
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

/** Installs every typed table entry through site(), with literal matchers for the engine's scan and this load's inks. */
function sites(on: On, table: PainterTable, ink: Inks): void {
  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => { return site<'UserMessage'>($, e, next, table.UserMessage, ink) })
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => { return site<'AssistantMessage'>($, e, next, table.AssistantMessage, ink) })
  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => { return site<'ToolUse'>($, e, next, table.ToolUse, ink) })
  on('ui.render', { component: 'ToolGroup' }, async ($, e, next) => { return site<'ToolGroup'>($, e, next, table.ToolGroup, ink) })
  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => { return site<'ToolResult'>($, e, next, table.ToolResult, ink) })
  on('ui.render', { component: 'ToolProgress' }, async ($, e, next) => { return site<'ToolProgress'>($, e, next, table.ToolProgress, ink) })
  on('ui.render', { component: 'TurnDuration' }, async ($, e, next) => { return site<'TurnDuration'>($, e, next, table.TurnDuration, ink) })
  on('ui.render', { component: 'CommandOutput' }, async ($, e, next) => { return site<'CommandOutput'>($, e, next, table.CommandOutput, ink) })
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => { return site<'SessionMode'>($, e, next, table.SessionMode, ink) })
}
