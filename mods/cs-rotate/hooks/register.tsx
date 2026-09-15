/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-rotate mod: one button above the prompt, rotate past the threshold or /clear once a handoff is armed.
// ABOUTME: The rotate press fills the composer; the armed press runs /clear; session.start writes a heartbeat for doctor.
import type { On, EngineInterface } from 'claude-code'

declare const h: any
declare const Fragment: any

// KEEP IN SYNC with the ctx warn default in bin/cs-statusline (_seg_ctx): by
// default the band appears where the status bar turns amber and the Stop hook
// gives its headroom notice. CS_ROTATE_BUTTON_CTX in the process environment
// moves it; this value applies when the variable is unset or not a number.
export const DEFAULT_PERCENT = 40

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
    if (!armed) {
      const { context } = await $.session.usage()
      if (context.percent === undefined || context.percent < (await threshold($))) return drawn
    }
    if (!(await ownsRotation($))) return drawn
    const { Box, Button } = await $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        {drawn}
        <Box>
          {/* plain draws "1: label", so the hotkey is discoverable */}
          {armed
            ? <Button key="cs-rotate" hotkey="1" plain label="/clear and continue from the handoff"
                      onPress={() => clearAndContinue($)} />
            : <Button key="cs-rotate" hotkey="1" plain label="rotate this conversation"
                      onPress={() => rotate($)} />}
        </Box>
      </Box>
    )
  })
}

// The variable's name is a literal: `claude plugin validate` lists what a
// module reads, and a name it does not spell is refused.
async function threshold($: EngineInterface): Promise<number> {
  const raw = await $.env.get("CS_ROTATE_BUTTON_CTX")
  return raw !== undefined && /^\d+$/.test(raw.trim()) ? Number(raw.trim()) : DEFAULT_PERCENT
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

// Fill, never submit: the rotate skill asks for a purpose line, so the person
// finishes the command and sends it themselves.
async function rotate($: EngineInterface) {
  await $.prompt.fill({ text: '/rotate ' })
}

// The one command the mod runs itself: /clear ends this conversation, and cs's
// SessionStart hook then starts the armed handoff's next step in the new one.
// Measured: the run resolves once the screen has cleared and a new transcript
// is open; the marker is the hook's to consume.
async function clearAndContinue($: EngineInterface) {
  await $.command.run({ command: 'clear', args: '' })
}
