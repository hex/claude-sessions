/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-rotate mod: keys above the prompt: rotate past the threshold, wrap up, or /clear once a handoff is armed.
// ABOUTME: With CS_ROTATE_FORCE_CTX set a turn ending past it runs /rotate itself, then asks before the /clear; session.start writes a heartbeat for doctor.
import type { On, EngineInterface } from 'claude-code'

declare const h: any
declare const Fragment: any

// KEEP IN SYNC with the ctx warn and crit defaults in bin/cs-statusline
// (_seg_ctx): by default the band appears where the status bar turns amber and
// the Stop hook gives its headroom notice. CS_STATUSLINE_CTX_WARN in the
// process environment moves it, as it moves the bar; CS_ROTATE_BUTTON_CTX moves
// the band alone. A value that is not a number is ignored.
export const DEFAULT_PERCENT = 40

// KEEP IN SYNC with _bg_shade and the `surface` arm of _sgr in
// bin/cs-statusline: the band paints the bar's own capsule fill, a shade of the
// terminal background nudged a tenth away from itself (darker on a light
// terminal, lighter on a dark one), so the keys read as one more capsule of the
// bar rather than as a row of the transcript. cs measures the background at
// launch and exports it; without that measurement the band paints no fill, so a
// guess can never leave the engine's own text on a surface it cannot read
// against.
export const SURFACE_SHIFT = 10

export function surfaceColor(bg: string | undefined): string | undefined {
  const parts = (bg ?? '').split(';')
  if (parts.length !== 3) return undefined
  const rgb = parts.map(part => (/^\s*\d{1,3}\s*$/.test(part) ? Number(part) : 256))
  if (rgb.some(v => v > 255)) return undefined
  const [r, g, b] = rgb
  const shade = 2126 * r + 7152 * g + 722 * b >= 1275000
    ? rgb.map(v => Math.floor(v * (100 - SURFACE_SHIFT) / 100))
    : rgb.map(v => v + Math.floor((255 - v) * SURFACE_SHIFT / 100))
  return `rgb(${shade.join(',')})`
}

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
// (measured; a timer started before one kept firing after it) and is lost
// on a reload of the mod.
export const FORCED = '.cs/local/cs-rotate.forced'

// What the mod asks, and the answer that acts. `$.ui.ask` opens the engine's
// own AskUserQuestion dialog and resolves to the label chosen, or to free text
// typed under Other, so the answer is compared exactly; it rejects when the
// dialog is dismissed and in a `-p` run, where there is nobody to ask. Both
// questions are asked from a timer, never awaited inside a hook the turn is
// waiting on: a turn held open until the person answers is a turn that cannot
// draw the dialog.
export const CLEAR_QUESTION = 'The handoff is written. Clear now and continue from it?'
export const CLEAR_YES = 'Clear and continue'
export const WRAP_QUESTION = 'Run /wrap for this session?'
export const WRAP_YES = 'Yes, wrap up'

// Whether this conversation has already been asked to clear. The forced
// rotation asks once and takes no for an answer: a question re-opened at the
// end of every turn is a question nobody can refuse. Module state survives a
// /clear (measured), so the flag is dropped where the conversation changes.
let asked = false

// Which conversation the turns belong to, and whether it is being judged. A
// conversation that begins past the force threshold did not get there by
// working: forcing it would rotate again as soon as its successor woke
// (measured at 1%). Only a conversation born of a /clear seen in this process
// (`clearSeen`, then `birth`) is judged that way, by the context its first
// turn ended with (`startPercent`). Any other new id (a launch, a reload, a
// /resume at 72%) is adopted unjudged, since past the line is exactly where
// the person asked to be rotated. Module state is kept across /clear, which
// is what makes the birth visible.
let adopted: string | undefined
let clearSeen = false
let birth: string | undefined
let startPercent: number | undefined

export function register(on: On) {
  // A (re)load has met no conversation yet, and has asked nobody anything.
  adopted = undefined; clearSeen = false; birth = undefined; startPercent = undefined; asked = false
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

  // A /clear from anywhere else (typed, another plugin) ends the conversation
  // the count belongs to, so the timer must not outlive it, and makes the
  // next conversation a birth; a run the engine refuses makes nothing.
  on('command.run', { command: 'clear' }, async ($, e, next) => {
    clearSeen = true
    try {
      return await next(e)
    } catch (err) {
      clearSeen = false
      throw err
    }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const drawn = await next(e)
    // The band draws in a new conversation before any of its turns end, so
    // the birth is settled here: a later /resume is not mistaken for it.
    noteConversation(await $.session.id())
    // A survey owns the band; a running turn cannot be rotated out of.
    if (e.props.hasSurvey || e.props.isWorking) return drawn
    const armed = await handoffArmed($)
    const { context } = await $.session.usage()
    const percent = context.percent
    if (!armed && (percent === undefined || percent < (await threshold($)))) return drawn
    if (!(await ownsRotation($))) return drawn
    const fill = surfaceColor(await $.env.get("CS_TERM_BG_RGB"))
    const { Box, Text, Button } = await $.ui.resolve(e)
    // One capsule in the status bar's idiom: the keys on the bar's own fill,
    // a blank line above them so the band reads apart from the transcript.
    // The context percentage is the bar's to carry; the band does not repeat
    // it. The keyed box lights coral under the pointer; the engine restyles it
    // without running the hook.
    return (
      <Box flexDirection="column">
        {drawn}
        <Box marginTop={1}>
          <Box key="cs-rotate-band" paddingX={1} backgroundColor={fill}>
            {/* The engine draws a plain button as "1: label", and it draws
                that prefix whether or not the label is empty (measured live:
                a hand-drawn digit beside an empty-label button prints the
                hotkey twice), so the label stays on the button. */}
            {armed
              ? <Button key="cs-rotate" hotkey="1" plain label="/clear and continue from the handoff"
                        onPress={() => clearAndContinue($)} />
              : <Button key="cs-rotate" hotkey="1" plain label="rotate this conversation"
                        onPress={() => rotate($)} />}
            {/* a Button is a block: nested in a Text the engine refuses the whole tree (measured), so the separator stands beside it */}
            {!armed && <Text dimColor>{'  \u00b7  '}</Text>}
            {!armed && <Button key="cs-wrap" hotkey="2" plain label="wrap up this session" onPress={() => askToWrap($)} />}
          </Box>
        </Box>
      </Box>
    )
  })
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

// A conversation id the mod has not met yet is the current one from here on,
// and the call says so. It is a birth, to be judged by its first turn's end,
// only when a /clear was seen since the last id; a /resume, a launch or a
// reload adopt unjudged, and an earlier judgment of the same id is dropped
// with them.
function noteConversation(id: string): boolean {
  if (id === adopted) return false
  adopted = id
  asked = false
  startPercent = undefined
  birth = clearSeen ? id : undefined
  clearSeen = false
  return true
}

// Runs /rotate for the person once a turn ends past the force threshold, once
// per conversation, from a timer: the contract refuses `$.command.run` inside
// a hook the turn is waiting on, and a `clock.after` callback runs once the
// hook has returned (measured: a 0 ms timer scheduled in turn.complete ran the
// command). A rejected run is not retried; the button stays for the person.
async function forceRotation($: EngineInterface) {
  const force = await forceThreshold($)
  if (force === undefined) return
  if (!(await ownsRotation($))) return
  const id = await $.session.id()
  const { context } = await $.session.usage()
  noteConversation(id)
  if (birth === id) {
    birth = undefined
    startPercent = context.percent
    if (startPercent !== undefined && startPercent >= force) {
      $.ui.toast(`cs-rotate: CS_ROTATE_FORCE_CTX=${force} is below this conversation's starting context (${startPercent}%); not forcing a rotation`)
    }
  }
  if (await handoffArmed($)) {
    // Asked once per conversation, and the flag is set BEFORE the dialog is
    // scheduled: a question the person leaves unanswered must not be re-asked
    // at the end of every turn that follows.
    if (asked) return
    asked = true
    // The callback returns its promise so the clock's caller can await the
    // whole question, not merely its scheduling.
    $.clock.after(0, () => askToClear($))
    return
  }
  if (startPercent !== undefined && startPercent >= force) return
  if (context.percent === undefined || context.percent < force) return
  const forced = `${await $.session.cwd()}/${FORCED}`
  if ((await $.fs.exists(forced)) && (await $.fs.read(forced)).trim() === id) return
  await $.fs.write(forced, `${id}\n`)
  $.clock.after(0, () => {
    rotate($).catch(err => $.ui.toast(`cs-rotate: /rotate did not run: ${String(err)}`))
  })
}

// The forced rotation's question. The dialog can stand open for as long as
// the person likes, so the three conditions the band draws its key under are
// read again before the /clear: a handoff consumed meanwhile, or a session
// handed on, must not be cleared out from under.
async function askToClear($: EngineInterface) {
  let answer: string
  try {
    answer = await $.ui.ask(CLEAR_QUESTION, { header: 'Rotate', options: [CLEAR_YES, 'Not yet'] })
  } catch {
    return // dismissed, or a `-p` run with nobody to ask: the band's key stays
  }
  if (answer !== CLEAR_YES) return
  if (!(await handoffArmed($)) || !(await ownsRotation($))) return
  try {
    await clearAndContinue($)
  } catch (err) {
    $.ui.toast(`cs-rotate: /clear did not run: ${String(err)}`)
  }
}

// The band's own threshold; without one it is the bar's warn band, read the way
// the bar reads it. Each variable's name is a literal: `claude plugin validate`
// lists what a module reads, and a name it does not spell is refused.
async function threshold($: EngineInterface): Promise<number> {
  return numberOr(
    await $.env.get("CS_ROTATE_BUTTON_CTX"),
    numberOr(await $.env.get("CS_STATUSLINE_CTX_WARN"), DEFAULT_PERCENT),
  )
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

// The hook's own rule (_handoff_is_unconsumed in hooks/session-start.sh): a
// frontmatter block opened by `---` on the first line and CLOSED by the next
// `---`, carrying `status: unconsumed` between them. A file the closing line
// never reaches (a truncated write) is not armed: the hook would refuse it,
// and a /clear on it would land in a conversation with nothing to continue.
export function isUnconsumed(text: string): boolean {
  const lines = text.split('\n')
  if (lines[0] !== '---') return false
  let matched = false
  for (const line of lines.slice(1)) {
    if (line === '---') return matched
    if (line === 'status: unconsumed') matched = true
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

// `2` asks before running /wrap: it replaces .cs/summary.md and runs two Opus
// passes before the narrative rotation, so a key that may have been meant for
// the composer opens the engine's own dialog rather than acting on the press.
async function askToWrap($: EngineInterface) {
  let answer: string
  try {
    answer = await $.ui.ask(WRAP_QUESTION, { header: 'Wrap', options: [WRAP_YES, 'Not now'] })
  } catch {
    return // dismissed, or a `-p` run with nobody to ask
  }
  if (answer !== WRAP_YES) return
  try {
    await $.command.run({ command: 'wrap', args: '' })
  } catch (err) {
    $.ui.toast(`cs-rotate: /wrap did not run: ${String(err)}`)
  }
}

// /clear ends this conversation, and cs's SessionStart hook then starts the
// armed handoff's next step in the new one.
// Measured: the run resolves once the screen has cleared and a new transcript
// is open; the marker is the hook's to consume.
async function clearAndContinue($: EngineInterface) {
  clearSeen = true
  try {
    await $.command.run({ command: 'clear', args: '' })
  } catch (err) {
    clearSeen = false
    throw err
  }
}
