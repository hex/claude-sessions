/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-rotate mod: one button above the prompt, rotate past the threshold or /clear once a handoff is armed.
// ABOUTME: The rotate press runs /rotate, the armed press runs /clear; session.start writes a heartbeat for doctor.
import type { On, EngineInterface } from 'claude-code'

declare const h: any
declare const Fragment: any

// KEEP IN SYNC with the ctx warn and crit defaults in bin/cs-statusline
// (_seg_ctx): by default the band appears where the status bar turns amber and
// the Stop hook gives its headroom notice, and the gauge changes ink where the
// bar's does. CS_STATUSLINE_CTX_WARN and _CRIT in the process environment move
// both, as they move the bar; CS_ROTATE_BUTTON_CTX moves the band alone. A
// value that is not a number is ignored.
export const DEFAULT_PERCENT = 40
export const DEFAULT_CRIT = 65

// Doctor observes the mod RUNNING, not merely installed: under a managed
// machine's policy a mod can load and never run. Written when the plugin loads
// (process start or reload; session.start does not fire on /clear). Path is
// relative to the session's cwd, which under cs is the session directory (or
// its worktree).
export const HEARTBEAT = '.cs/local/cs-rotate.heartbeat'

// The rotate skill's last step writes the handoff's basename here; cs's
// SessionStart hook reads it on the next conversation and starts the handoff's
// next step. While it names a handoff the conversation has nothing left to do
// but /clear, whatever the context reads.
export const MARKER = '.cs/local/pending-handoff'
export const HANDOFFS = '.cs/handoffs'

export function register(on: On) {
  on('session.start', async ($, e, next) => {
    // Only a cs session has .cs/local; anywhere else the mod stays silent.
    const local = `${e.cwd}/.cs/local`
    if (await $.fs.exists(local)) {
      await $.fs.write(`${e.cwd}/${HEARTBEAT}`, `${new Date().toISOString()}\n`)
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const drawn = await next(e)
    // A survey owns the band; a running turn cannot be rotated out of.
    if (e.props.hasSurvey || e.props.isWorking) return drawn
    const armed = await handoffArmed($)
    const { context } = await $.session.usage()
    const percent = context.percent
    const bands = await gaugeBands($)
    if (!armed && (percent === undefined || percent < (await threshold($, bands)))) return drawn
    if (!(await ownsRotation($))) return drawn
    const { Box, Text, Button } = await $.ui.resolve(e)
    // One capsule in the status bar's idiom: the Claude mark in coral, the
    // button, and the context gauge that explains why the capsule is there,
    // in the ink the bar paints that band (amber past warn, red past crit).
    return (
      <Box flexDirection="column">
        {drawn}
        <Box>
          <Box borderStyle="round" borderColor={armed ? 'claude' : gaugeColor(percent, bands)} paddingX={1}>
            <Text color="claude" bold>{'\u2733 '}</Text>
            {/* plain draws "1: label", so the hotkey is discoverable */}
            {armed
              ? <Button key="cs-rotate" hotkey="1" plain label="/clear and continue from the handoff"
                        onPress={() => clearAndContinue($)} />
              : <Button key="cs-rotate" hotkey="1" plain label="rotate this conversation"
                        onPress={() => rotate($)} />}
            {percent !== undefined && (
              <Text>
                <Text dimColor>{'  \u00b7  '}</Text>
                <Text color={gaugeColor(percent, bands)} bold>{`${pie(percent, bands)} ctx ${percent}%`}</Text>
              </Text>
            )}
          </Box>
        </Box>
      </Box>
    )
  })
}

export type Bands = { warn: number; crit: number }

// KEEP IN SYNC with the pie steps in bin/cs-statusline (_ctx_pie): the two
// fixed steps, 13 and 88, and the two that follow the bands.
export function pie(percent: number, bands: Bands): string {
  if (percent >= 88) return '\u25cf'
  if (percent >= bands.crit) return '\u25d5'
  if (percent >= bands.warn) return '\u25d1'
  if (percent >= 13) return '\u25d4'
  return '\u25cb'
}
export function gaugeColor(percent: number | undefined, bands: Bands): string {
  if (percent === undefined) return 'text'
  if (percent >= bands.crit) return 'error'
  if (percent >= bands.warn) return 'warning'
  return 'text'
}

// The bar's own bands, read the way the bar reads them. Each variable's name
// is a literal: `claude plugin validate` lists what a module reads, and a
// name it does not spell is refused.
async function gaugeBands($: EngineInterface): Promise<Bands> {
  return {
    warn: numberOr(await $.env.get("CS_STATUSLINE_CTX_WARN"), DEFAULT_PERCENT),
    crit: numberOr(await $.env.get("CS_STATUSLINE_CTX_CRIT"), DEFAULT_CRIT),
  }
}

function numberOr(raw: string | undefined, fallback: number): number {
  return raw !== undefined && /^\d+$/.test(raw.trim()) ? Number(raw.trim()) : fallback
}

// The band's own threshold; without one it is the bar's warn band. `claude plugin validate` lists what a
// module reads, and a name it does not spell is refused.
async function threshold($: EngineInterface, bands: Bands): Promise<number> {
  return numberOr(await $.env.get("CS_ROTATE_BUTTON_CTX"), bands.warn)
}

// Armed means the marker names a handoff the SessionStart hook will accept
// after the /clear: a bare basename (the hook rejects a separator), a file in
// the store, and frontmatter that still says unconsumed. A marker an aborted
// rotation left behind, or one naming a handoff since consumed, would offer a
// /clear that lands in a conversation with nothing to continue from, so it
// does not arm. One exists per render; the reads only while the marker is there.
async function handoffArmed($: EngineInterface): Promise<boolean> {
  const cwd = await $.session.cwd()
  if (!(await $.fs.exists(`${cwd}/${MARKER}`))) return false
  try {
    const name = (await $.fs.read(`${cwd}/${MARKER}`)).trim()
    if (name === '' || /[/\\]/.test(name)) return false
    return isUnconsumed(await $.fs.read(`${cwd}/${HANDOFFS}/${name}`))
  } catch {
    return false
  }
}

// The hook's own rule: a frontmatter block opened by `---` on the first line,
// carrying `status: unconsumed` before the closing `---`.
export function isUnconsumed(text: string): boolean {
  const lines = text.split('\n')
  if (lines[0] !== '---') return false
  for (const line of lines.slice(1)) {
    if (line === '---') return false
    if (line === 'status: unconsumed') return true
  }
  return false
}

// Only the lead conversation of a cs session may be offered a rotation. The
// rotate skill refuses outside a cs session, .cs/local/disabled opts a
// directory out of cs entirely, and the handoff it writes carries the UUID in
// .cs/local/state, which belongs to the one conversation cs launched: a
// teammate claude in the same directory would arm the lead's marker under the
// lead's identity. The checks run only once the band has a button to draw.
// The value may be quoted and may carry trailing spaces, as cs's own state
// readers allow.
async function ownsRotation($: EngineInterface): Promise<boolean> {
  const local = `${await $.session.cwd()}/.cs/local`
  if (!(await $.fs.exists(local)) || (await $.fs.exists(`${local}/disabled`))) return false
  let state: string
  try {
    state = await $.fs.read(`${local}/state`)
  } catch {
    return false
  }
  const lead = state.match(/^claude_session_id: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
  return lead !== undefined && lead === (await $.session.id())
}

// Runs the rotate skill as if the person had typed /rotate: the skill draws
// the purpose from the conversation itself.
async function rotate($: EngineInterface) {
  await $.command.run({ command: 'rotate', args: '' })
}

// /clear ends this conversation, and cs's SessionStart hook then starts the
// armed handoff's next step in the new one.
// Measured: the run resolves once the screen has cleared and a new transcript
// is open; the marker is the hook's to consume.
async function clearAndContinue($: EngineInterface) {
  await $.command.run({ command: 'clear', args: '' })
}
