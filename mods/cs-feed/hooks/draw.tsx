// ABOUTME: cs-feed's trees: turns a verdict into elements from $.ui.resolve(e), with the inks (§13) and the engine's own 2-column margin: ❯ before your line, nothing before Claude's.
// ABOUTME: No decisions and no $ calls but resolve; a Button never sits inside a Text (the engine refuses the whole tree).
import type { EngineInterface, RenderElement } from 'claude-code'

import type { BandVerdict, CallVerdict, Context, GroupVerdict, HelperBlock, ReplyVerdict, UserVerdict } from './verdict'
import type { FeedCommand, FieldSpec, Session, View } from './settings'
import { FIELDS, KINDS, parseFeedArgs } from './settings'
import type { FrameLine } from './words'
import { helperNowLine, helperPaneHead, helpersPaneWords, kindChip, settingCommand, settingValue, settingsWords, slashCommand } from './words'
import { backgroundLine, backgroundTail, braille, breathing, burstLine, callChips, callWords, fit, frameBody, frameHead, helperCounts, helperFraction, helperLine, helperNoteLine, hookNotice, labels, marks, moreKinds, outputLines, peerLine, pillLabel, questionLines, runChips, runWords, stepsLine, usageLabel, usagePeriods } from './words'

type Elements = ReturnType<EngineInterface['ui']['resolve']>

export type Inks = {
  readonly you: string; readonly claude: string; readonly peer: string; readonly mark: string; readonly chip: string
  readonly green: string; readonly red: string; readonly amber: string; readonly accent: string
}
/** §13 table; `light` from the /config theme, read by the 1 s tick at most every 30 s. */
export function inks(light: boolean): Inks {
  return light
    ? { you: '#2f4f6f', claude: '#8a4a1f', peer: '#5b3fb5', mark: '#5b3fb5', chip: '#e4e6eb', green: '#1f7a4a', red: '#b42318', amber: '#8a5a00', accent: '#d97757' }
    : { you: '#9fb4c8', claude: '#e3c4a2', peer: '#a78bfa', mark: '#b9acec', chip: '#3b3b3b', green: '#7fbf8f', red: '#e06c6c', amber: '#d8b36a', accent: '#d97757' }
}

/** Context every tree needs: elements, inks, room, whether chevrons are Buttons, and the press handler. */
export type Pen = {
  readonly el: Elements
  readonly ink: Inks
  readonly room: number
  readonly pad: number // 2 on the terminal, 0 on desktop
  readonly clickable: boolean
  readonly press: (key: string) => Promise<void> // session.toggle
  readonly helpers: () => Promise<void>
  readonly cx: Context
}

export const NOTHING = (pen: Pen): RenderElement => pen.el.Box({})

export function drawCommandOutput(v: { readonly text: string; readonly isErrored: boolean }, pen: Pen): RenderElement {
  const { Box, Text } = pen.el
  return <Box paddingLeft={pen.pad} flexDirection="row"><Box width={2}><Text dimColor>{marks.dot}</Text></Box><Text color={v.isErrored ? pen.ink.red : undefined} dimColor={!v.isErrored}>{v.text}</Text></Box>
}

/** Turn line, run line, call line, helper row, question rows (§4.6, §7.1, §11). */
export function drawCall(v: CallVerdict, pen: Pen): RenderElement {
  const { Box, Text, Button } = pen.el
  switch (v.draw) {
    case 'nothing': return NOTHING(pen)
    case 'turn': return <Box flexDirection="column">{v.done > 0 ? <Box paddingLeft={pen.pad} flexDirection="row" gap={1}><Text dimColor>{stepsLine(v.done)}</Text>{chevron(`turn-${v.turn}`, v.opened, pen)}</Box> : null}{v.opened ? <Box paddingLeft={2} flexDirection="column">{v.body.map(call => drawCall(call, pen))}</Box> : null}</Box>
    case 'run': {
      const naming = v.naming ? pen.cx.t.calls.get(v.naming) : undefined
      const words = runWords(v.run, pen.cx.t, naming ? callWords(naming, 'present') : undefined)
      const chips = !naming && pen.cx.view.style !== 'line' ? runChips(v.run, pen.cx.t) : []
      return <Box flexDirection="column"><Box paddingLeft={pen.pad} flexDirection="row" gap={1}><Text color={naming ? pen.ink.accent : undefined} dimColor={!naming}>{naming ? marks.live : marks.idle}</Text><Text>{fit(words, pen.room - 4)}</Text>{chips.map(chip => <Text backgroundColor={pen.ink.chip}>{chip}</Text>)}{chevron(`open-${v.run.id}`, v.opened, pen)}</Box>{v.opened ? <Box paddingLeft={2} flexDirection="column">{v.run.calls.flatMap(id => {
        const filed = pen.cx.t.calls.get(id)
        if (!filed) return []
        const done = filed.outcome.state === 'done' ? filed.outcome : undefined
        return [drawCall({ draw: 'call', call: { id, tool: filed.tool, input: filed.input, isRunning: !done, isErrored: done?.errored === true, isInterrupted: done?.interrupted === true, output: done?.output }, filed, opened: true }, pen)]
      })}</Box> : null}</Box>
    }
    case 'call': {
      const chips = pen.cx.view.style === 'line' ? [] : callChips(v.call, v.filed)
      return <Box flexDirection="column"><Box paddingLeft={pen.pad} flexDirection="row" gap={1}><Text color={v.call.isErrored ? pen.ink.red : v.call.isRunning ? pen.ink.accent : undefined} dimColor={!v.call.isRunning && !v.call.isErrored}>{v.call.isRunning ? marks.live : marks.idle}</Text><Text>{fit(callWords(v.call, v.call.isRunning ? 'present' : 'past'), pen.room - 4)}</Text>{chips.map(chip => <Text backgroundColor={pen.ink.chip}>{chip}</Text>)}{v.call.id ? chevron(v.call.id, v.opened, pen) : null}</Box>{v.opened ? <Box paddingLeft={pen.pad + 2} flexDirection="column">{outputLines(v.call.output ?? (v.filed?.outcome.state === 'done' ? v.filed.outcome.output : undefined)).map(line => <Text dimColor>{line}</Text>)}</Box> : null}</Box>
    }
    case 'helper': return <Box paddingLeft={pen.pad} flexDirection="row" gap={1}><Text color={v.state === 'failed' || v.state === 'stopped' ? pen.ink.red : pen.ink.peer}>{helperLine(v.call, v.state, v.elapsedMs)}</Text>{pen.clickable ? <Button key={`helper-${v.call.id ?? v.call.tool}`} label={marks.closed} plain dimColor onPress={pen.helpers} /> : <Text dimColor>{marks.closed}</Text>}</Box>
    case 'question': return <Box paddingLeft={pen.pad} flexDirection="column">{questionLines(v.call, v.call.id ? pen.cx.t.calls.get(v.call.id) : undefined).map(line => <Text>{line}</Text>)}</Box>
  }
}
/** 'stack' draws each call's tree in a column; 'batch' the §7.2 helper batch; 'engine' never reaches here. */
export function drawGroup(v: Exclude<GroupVerdict, { draw: 'engine' }>, pen: Pen): RenderElement {
  const { Box, Text } = pen.el
  if (v.draw === 'stack') return <Box flexDirection="column">{v.calls.map(call => drawCall(call, pen))}</Box>
  const busy = v.helpers.some(helper => helper.state === 'running' || helper.state === 'dispatched')
  const failed = v.helpers.some(helper => helper.state === 'failed' || helper.state === 'stopped')
  const kinds = [...new Set(v.helpers.map(helper => helper.kind))]
  const cell = (state: import('./verdict').HelperState) => <Text color={state === 'failed' || state === 'stopped' ? pen.ink.red : state === 'finished' ? pen.ink.green : pen.ink.peer}>{state === 'failed' || state === 'stopped' ? marks.failed : state === 'finished' ? marks.live : marks.working}</Text>
  return <Box flexDirection="column"><Box paddingLeft={pen.pad} flexDirection="row" gap={1}><Text color={busy ? pen.ink.peer : failed ? pen.ink.red : pen.ink.green}>{busy ? braille[Math.floor(pen.cx.now / 70) % braille.length] : failed ? marks.failed : marks.live}</Text><Text>{helperCounts(v.helpers.map(helper => helper.state), v.elapsedMs)}</Text>{chevron(v.key, v.opened, pen)}</Box>{kinds.map(kind => {
    const members = v.helpers.filter(helper => helper.kind === kind)
    return <Box paddingLeft={pen.pad + 2} flexDirection="row" gap={1}><Text dimColor>{fit(kind, 22)}</Text><Text dimColor>{String(members.length)}</Text>{members.map(helper => cell(helper.state))}<Text dimColor>{helperFraction(members.filter(helper => helper.state === 'finished').length, members.length, members.filter(helper => helper.state === 'failed' || helper.state === 'stopped').length)}</Text></Box>
  })}{v.opened ? v.helpers.map(helper => <Box paddingLeft={pen.pad + 2} flexDirection="row" gap={1}>{cell(helper.state)}<Text>{fit(callWords(helper.call, helper.state === 'running' || helper.state === 'dispatched' ? 'present' : 'past'), 60)}</Text></Box>) : null}</Box>
}
/** The "you" margin, the hook-text line, peer lines, bursts, frames and cards (§3.1, §8). */
export function drawUser(v: Exclude<UserVerdict, { draw: 'engine' }>, pen: Pen): RenderElement {
  const { Box, Text } = pen.el
  switch (v.draw) {
    case 'nothing': return NOTHING(pen)
    case 'you': {
      const command = slashCommand(v.text)
      const text = command
        ? <Box flexGrow={1} flexDirection="row" gap={1}><Text color={pen.ink.you}>{command.name}</Text>{command.args ? <Text dimColor>{command.args}</Text> : null}</Box>
        : <Box flexGrow={1}><Text color={pen.ink.you}>{v.text}</Text></Box>
      return <Box flexDirection="column" marginTop={1}><Box flexDirection="row"><Box width={pen.pad}><Text color={pen.ink.you}>{labels.you}</Text></Box>{text}</Box></Box>
    }
    case 'hookText': return <Box paddingLeft={pen.pad}><Text dimColor>{hookNotice(v.line)}</Text></Box>
    case 'peer': return <Box paddingLeft={pen.pad + (v.nested ? 2 : 0)}><Text color={pen.ink.peer}>{peerLine(v.sender, v.headline)}</Text></Box>
    case 'helperNote': return <Box paddingLeft={pen.pad}><Text color={pen.ink.peer}>{helperNoteLine(v.headline, v.durationMs)}</Text></Box>
    case 'backgroundNote': return <Box paddingLeft={pen.pad}><Text dimColor>{labels.backgroundUpdate}</Text></Box>
    case 'burst': {
      const head = v.members[0]
      if (!head) return NOTHING(pen)
      return <Box flexDirection="column" paddingLeft={pen.pad}><Box flexDirection="row"><Text color={pen.ink.peer}>{burstLine(v.members)}</Text>{chevron(`burst-${head.uuid}`, v.opened, pen)}</Box>{v.own ? <Box paddingLeft={2}><Text color={pen.ink.peer}>{peerLine(v.own.sender, v.own.headline)}</Text></Box> : null}</Box>
    }
    case 'frames': return <Box flexDirection="column" paddingLeft={pen.pad}>{v.frames.map(frame => <Box flexDirection="column"><Text color={pen.ink.peer}>{frameHead(frame)}</Text><Box flexDirection="column" paddingLeft={2}>{frameBody(frame).map(line => drawFrameLine(line, pen))}</Box></Box>)}</Box>
  }
}

function drawFrameLine(line: FrameLine, pen: Pen): RenderElement {
  const { Box, Markdown, Text } = pen.el
  const tone = (value: 'ok' | 'bad' | 'mid') => value === 'ok' ? pen.ink.green : value === 'bad' ? pen.ink.red : pen.ink.amber
  switch (line.kind) {
    case 'markdown': return <Markdown text={line.text} />
    case 'status': return <Box flexDirection="row" gap={1}><Text color={tone(line.tone)}>{line.glyph}</Text>{line.status ? <Text>{line.status}</Text> : null}{line.sub ? <Text dimColor>{line.sub}</Text> : null}</Box>
    case 'text': return <Text>{line.text}</Text>
    case 'score': return <Box flexDirection="row" gap={1}><Text>{line.label}</Text><Box flexDirection="row">{line.dots.map(dot => <Text color={tone(dot)}>{marks.live}</Text>)}</Box><Text dimColor>{line.tally}</Text></Box>
    case 'list': return <Box flexDirection="row" gap={1}><Text>{line.label}</Text><Text bold>{line.count}</Text><Text dimColor>{line.first}</Text></Box>
    case 'hint': return <Text dimColor>{line.text}</Text>
  }
}

function chevron(key: string, opened: boolean, pen: Pen): RenderElement {
  const { Button, Text } = pen.el
  const label = opened ? marks.opened : marks.closed
  return pen.clickable ? <Button key={key} label={label} plain dimColor onPress={() => pen.press(key)} /> : <Text dimColor>{label}</Text>
}
/**
 * The "claude" margin beside the ENGINE's drawing of the reply (passed in as
 * `engine`), the error line in its place, and the steps line under it. The
 * reply's markdown is never redrawn by the mod: an inner hook's drawing (cs-
 * mermaid's diagrams) survives whichever order the two load in.
 */
export function drawReply(v: ReplyVerdict, engine: RenderElement, pen: Pen): RenderElement {
  const { Box, Text } = pen.el
  const body = typeof v.body === 'object'
    ? <Box flexDirection="column" paddingLeft={pen.pad}><Text color={v.body.error.tone === 'red' ? pen.ink.red : v.body.error.tone === 'amber' ? pen.ink.amber : pen.ink.peer}>{v.body.error.head}</Text>{v.body.error.rest.map(line => <Text dimColor>{line}</Text>)}</Box>
    : v.body === 'nothing' ? NOTHING(pen)
      : <Box paddingLeft={pen.pad} flexDirection="column">{engine}</Box>
  return <Box flexDirection="column">{body}{v.stepsLine ? drawCall(v.stepsLine, pen) : null}</Box>
}
/** Ours above `beneath` (what next(e) drew: cs's band, or the engine's), in one column. */
export function drawBand(v: Exclude<BandVerdict, { draw: 'engine' }>, beneath: RenderElement, frame: number, pen: Pen): RenderElement {
  const { Box, Text } = pen.el
  let ours: RenderElement
  switch (v.draw) {
    case 'helpers': ours = <Box flexDirection="column" paddingLeft={pen.pad}><Box flexDirection="row" gap={1}><Text color={pen.ink.peer}>{v.spinning ? braille[frame % braille.length] : marks.live}</Text><Text color={pen.ink.peer}>{v.head}</Text></Box>{v.kinds.map(kind => <Box flexDirection="row" gap={1}><Text dimColor>{kind.kind}</Text>{[...kind.cells].map(cell => <Text color={cell === marks.working ? pen.ink.peer : cell === marks.failed ? pen.ink.red : pen.ink.green}>{cell}</Text>)}<Text dimColor>{helperFraction(kind.done, kind.n)}</Text></Box>)}{v.more ? <Text dimColor>{moreKinds(v.more)}</Text> : null}</Box>; break
    case 'background': ours = <Box paddingLeft={pen.pad} flexDirection="row" gap={1}><Text color={pen.ink.accent}>{breathing[Math.floor(frame / 2) % breathing.length]}</Text><Text>{fit(backgroundLine(v.words, v.isTest, v.more), pen.room)}</Text><Text dimColor>{backgroundTail(v.elapsedMs, v.typing)}</Text></Box>; break
    case 'desktop': ours = <Box justifyContent="flex-end" flexDirection="row" gap={1}>{v.usage.fiveHour === undefined ? null : <Text>{usageLabel(v.usage.fiveHour, usagePeriods.fiveHour)}</Text>}{v.usage.week === undefined ? null : <Text>{usageLabel(v.usage.week, usagePeriods.week)}</Text>}{v.pills.map(pill => <Text backgroundColor={pen.ink.chip}>{pillLabel(pill)}</Text>)}</Box>; break
  }
  return <Box flexDirection="column">{ours}{beneath}</Box>
}

/** The "Chat view" pane (§2.3) for this session: header, an on/off row (FeedCommand `switch`), one row per FIELDS entry with its picture, the Show chips. Buttons are siblings of Texts, never inside one. A Button never shrinks, so the chips wrap onto another row when the pane is narrower than them; `columnGap`, not `gap`, which would also put a blank row between the two. */
export function drawSettingsPane(mode: string, session: Session, pen: Pick<Pen, 'el' | 'ink' | 'room'>, onPress: (cmd: FeedCommand) => Promise<void>): RenderElement {
  const { Box, Text, Button } = pen.el
  return <Box flexDirection="column"><Box flexDirection="row" gap={1}><Text bold>{settingsWords.title}</Text><Text color={pen.ink.accent}>{mode}</Text><Text dimColor>{settingsWords.shortcuts}</Text></Box><Box flexDirection="row" gap={1}><Button key="btn-feed" label={settingsWords.switch} onPress={() => onPress({ kind: 'switch', on: !session.on })} /><Text color={pen.ink.accent} bold>{settingValue(session.on)}</Text></Box>{FIELDS.map(spec => {
    const current = session.view[spec.field]
    const next = spec.values[(spec.values.findIndex(value => value === current) + 1) % spec.values.length]
    if (next === undefined) throw new Error(`setting ${spec.field} has no next value`)
    const command = settingCommand(spec.word, next)
    return <Box flexDirection="column"><Box flexDirection="row" gap={1}><Button key={`btn-${spec.field}`} label={spec.title} onPress={() => onPress(parseFeedArgs(command.slice(6)))} /><Text color={pen.ink.accent} bold>{settingValue(current)}</Text><Text dimColor>{`${marks.dot} ${command}`}</Text></Box><Box paddingLeft={2} flexDirection="column">{fieldPicture(spec, session.view).map(line => <Text dimColor>{fit(line, Math.max(1, pen.room - 4))}</Text>)}</Box></Box>
  })}<Text bold>{settingsWords.show}</Text><Box flexDirection="row" flexWrap="wrap" columnGap={1}>{KINDS.map(kind => {
    const shown = !session.view.hide.includes(kind)
    return <Button key={`kind-${kind}`} label={kindChip(kind, shown)} onPress={() => onPress({ kind: shown ? 'hide' : 'show', what: kind })} />
  })}</Box><Text dimColor>{settingsWords.hideHelp}</Text></Box>
}

function fieldPicture(spec: FieldSpec, view: View): readonly string[] {
  switch (spec.field) {
    case 'group': case 'clear': case 'keep': return spec.picture(view[spec.field])
    case 'style': return spec.picture(view.style)
    case 'commands': return spec.picture(view.commands)
    case 'after': return spec.picture(view.after)
  }
}
/** The "Helpers" pane (§7.4): the newest helpers first, each a head with the live glyph while it works, "now:" and its own last calls, indented. */
export function drawHelpersPane(blocks: readonly HelperBlock[], pen: Pick<Pen, 'el' | 'ink' | 'room'>): RenderElement {
  const { Box, Text } = pen.el
  if (!blocks.length) return <Box><Text dimColor>{helpersPaneWords.none}</Text></Box>
  const room = Math.max(1, pen.room - 2)
  return <Box flexDirection="column">{blocks.map(block => {
    const working = block.status === 'working'
    return <Box flexDirection="column"><Box flexDirection="row" gap={1}><Text color={working ? pen.ink.accent : block.status === 'finished' ? undefined : pen.ink.red} dimColor={!working}>{working ? marks.live : marks.idle}</Text><Text>{fit(helperPaneHead(block.name, block.status, block.elapsedMs), room)}</Text></Box>{block.now ? <Box paddingLeft={2}><Text dimColor>{fit(helperNowLine(block.now), room)}</Text></Box> : null}{block.calls.map(call => <Box paddingLeft={2}><Text dimColor>{fit(call, room)}</Text></Box>)}</Box>
  })}</Box>
}
