// ABOUTME: cs-chat-only's trees: turns a verdict into elements from $.ui.resolve(e), with the inks (§13) and the engine's own 2-column margin: ❯ before your line, nothing before Claude's.
// ABOUTME: No decisions and no $ calls but resolve; a Button never sits inside a Text (the engine refuses the whole tree).
import type { EngineInterface, RenderElement } from 'claude-code'

import type { UserVerdict } from './verdict'
import type { ErrorLine } from './words'
import { labels, marks, slashCommand } from './words'

type Elements = ReturnType<EngineInterface['ui']['resolve']>

export type Inks = { readonly you: string; readonly violet: string; readonly red: string; readonly amber: string }
/** §13 table; `light` from the /config theme, read once per load (session.chatOnlyRecord). */
export function inks(light: boolean): Inks {
  return light
    ? { you: '#2f4f6f', violet: '#5b3fb5', red: '#b42318', amber: '#8a5a00' }
    : { you: '#9fb4c8', violet: '#a78bfa', red: '#e06c6c', amber: '#d8b36a' }
}

/** What every tree needs: elements, inks, and the engine's margin (2 on the terminal, 0 on desktop). */
export type Pen = {
  readonly el: Elements
  readonly ink: Inks
  readonly pad: number
}

/** The engine's nothing: an empty Box in the row's place. */
export const NOTHING = (pen: Pen): RenderElement => pen.el.Box({})

export function drawCommandOutput(v: { readonly text: string; readonly isErrored: boolean }, pen: Pen): RenderElement {
  const { Box, Text } = pen.el
  return <Box paddingLeft={pen.pad} flexDirection="row"><Box width={2}><Text dimColor>{marks.dot}</Text></Box><Text color={v.isErrored ? pen.ink.red : undefined} dimColor={!v.isErrored}>{v.text}</Text></Box>
}

/** Your line: ❯ in the you ink in the margin, then your text, a slash command's name in that ink and its arguments dim (§3.1). */
export function drawUser(v: Extract<UserVerdict, { draw: 'you' }>, pen: Pen): RenderElement {
  const { Box, Text } = pen.el
  const command = slashCommand(v.text)
  const text = command
    ? <Box flexGrow={1} flexDirection="row" gap={1}><Text color={pen.ink.you}>{command.name}</Text>{command.args ? <Text dimColor>{command.args}</Text> : null}</Box>
    : <Box flexGrow={1}><Text color={pen.ink.you}>{v.text}</Text></Box>
  return <Box flexDirection="column" marginTop={1}><Box flexDirection="row"><Box width={pen.pad}><Text color={pen.ink.you}>{labels.you}</Text></Box>{text}</Box></Box>
}

/**
 * Claude's reply: the ENGINE's drawing of it (passed in as `engine`) at the
 * margin. The reply's markdown is never redrawn by the mod: an inner hook's
 * drawing (cs-mermaid's diagrams) survives whichever order the two load in.
 */
export function drawReply(engine: RenderElement, pen: Pen): RenderElement {
  const { Box } = pen.el
  return <Box paddingLeft={pen.pad} flexDirection="column">{engine}</Box>
}

/** The error line in a failed reply's place, coloured by who acts (§6): violet for a safeguard stop, red when you must act, amber when Claude Code handles it. */
export function drawError(error: ErrorLine, pen: Pen): RenderElement {
  const { Box, Text } = pen.el
  return <Box flexDirection="column" paddingLeft={pen.pad}><Text color={pen.ink[error.tone]}>{error.head}</Text>{error.rest.map(line => <Text dimColor>{line}</Text>)}</Box>
}
