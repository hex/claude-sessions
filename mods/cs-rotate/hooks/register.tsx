/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-rotate mod: one button above the prompt, rotate past the threshold or /clear once a handoff is armed.
// ABOUTME: With CS_ROTATE_FORCE_CTX set a turn ending past it runs /rotate itself; session.start writes a heartbeat for doctor.
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

// KEEP IN SYNC with the truecolor inks in bin/cs-statusline (_sgr: brand,
// amber, crit): the capsule paints the bar's own inks, not the theme's
// nearest keys, so it reads as one more capsule of the bar. The bar pivots
// amber on the measured terminal background when it has one; the mod has only
// the theme cs detected at launch (CS_TERM_THEME), dark when unset, as cs's
// own hooks read it.
export const INK = {
  coral: 'rgb(217,119,87)',
  amber: { light: 'rgb(180,83,9)', dark: 'rgb(253,230,138)' },
  crit: { light: 'rgb(215,0,21)', dark: 'rgb(255,69,58)' },
}
export type Theme = 'light' | 'dark'

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

// The conversation a forced rotation already ran /rotate for, by id. Written
// BEFORE the run is scheduled: a rotation that fails must not be retried at
// the end of every turn. Module state would not do: it survives a /clear
// (measured; a ticker started before one kept firing after it) and is lost
// on a reload of the mod.
export const FORCED = '.cs/local/cs-rotate.forced'

export function register(on: On) {
  on('session.start', async ($, e, next) => {
    // Only a cs session has .cs/local; anywhere else the mod stays silent.
    const local = `${e.cwd}/.cs/local`
    if (await $.fs.exists(local)) {
      await $.fs.write(`${e.cwd}/${HEARTBEAT}`, `${new Date().toISOString()}\n`)
    }
    return next(e)
  })

  // The end of a turn is the one moment a rotation can be started for the
  // person: the answer is in, nothing runs. An aborted or errored turn is no
  // place to start one, and a subagent's turn ends in the same event.
  on('turn.complete', async ($, e, next) => {
    if (e.reason === 'answer' && e.agentId === undefined) await forceRotation($)
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
    const theme = await termTheme($)
    const ink = gaugeColor(percent, bands, theme)
    const { Box, Text, Button } = await $.ui.resolve(e)
    // One capsule in the status bar's idiom: the Claude mark in coral, the
    // button, and the context meter that explains why the capsule is there,
    // in the ink the bar paints that band (amber past warn, red past crit).
    // The keyed box lights coral under the pointer; the engine restyles it
    // without running the hook.
    return (
      <Box flexDirection="column">
        {drawn}
        <Box>
          <Box key="cs-rotate-band" borderStyle="round" borderColor={armed ? INK.coral : ink} paddingX={1}
               hover={{ borderColor: INK.coral }}>
            <Text color={INK.coral} bold>{'\u2733 '}</Text>
            {/* plain draws "1: label", so the hotkey is discoverable */}
            {armed
              ? <Button key="cs-rotate" hotkey="1" plain label="/clear and continue from the handoff"
                        onPress={() => clearAndContinue($)} />
              : <Button key="cs-rotate" hotkey="1" plain label="rotate this conversation"
                        onPress={() => rotate($)} />}
            {percent !== undefined && (
              <Text>
                <Text dimColor>{'  \u00b7  '}</Text>
                <Text color={ink}>{meter(percent)[0]}</Text>
                <Text dimColor>{meter(percent)[1]}</Text>
                <Text color={ink} bold>{` ${percent}%`}</Text>
              </Text>
            )}
          </Box>
        </Box>
      </Box>
    )
  })
}

export type Bands = { warn: number; crit: number }

// Ten cells, one per ten percent, rounded: the filled run and the empty run.
export function meter(percent: number): [string, string] {
  const n = Math.min(10, Math.max(0, Math.round(percent / 10)))
  return ['\u2588'.repeat(n), '\u2591'.repeat(10 - n)]
}

// Below warn the capsule is only ever drawn armed, in the theme's plain ink.
export function gaugeColor(percent: number | undefined, bands: Bands, theme: Theme): string {
  if (percent === undefined) return 'text'
  if (percent >= bands.crit) return INK.crit[theme]
  if (percent >= bands.warn) return INK.amber[theme]
  return 'text'
}

// The theme cs detected at launch; anything but "light" is dark, as cs's hooks read it.
async function termTheme($: EngineInterface): Promise<Theme> {
  return (await $.env.get("CS_TERM_THEME")) === 'light' ? 'light' : 'dark'
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

// Off unless CS_ROTATE_FORCE_CTX names a percentage. `claude plugin validate`
// lists what a module reads, and a name it does not spell is refused.
async function forceThreshold($: EngineInterface): Promise<number | undefined> {
  const raw = await $.env.get("CS_ROTATE_FORCE_CTX")
  return raw !== undefined && /^\d+$/.test(raw.trim()) ? Number(raw.trim()) : undefined
}

// Runs /rotate for the person once a turn ends past the force threshold, once
// per conversation, from a timer: the contract refuses `$.command.run` inside
// a hook the turn is waiting on, and a `clock.after` callback runs once the
// hook has returned (measured: a 0 ms timer scheduled in turn.complete ran the
// command). A rejected run is not retried; the button stays for the person.
async function forceRotation($: EngineInterface) {
  const force = await forceThreshold($)
  if (force === undefined) return
  if (await handoffArmed($)) return
  const { context } = await $.session.usage()
  if (context.percent === undefined || context.percent < force) return
  if (!(await ownsRotation($))) return
  const forced = `${await $.session.cwd()}/${FORCED}`
  const id = await $.session.id()
  if ((await $.fs.exists(forced)) && (await $.fs.read(forced)).trim() === id) return
  await $.fs.write(forced, `${id}\n`)
  $.clock.after(0, () => {
    rotate($).catch(err => $.ui.toast(`cs-rotate: /rotate did not run: ${String(err)}`))
  })
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
