/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-rotate mod: draws a rotate button above the prompt once context passes crit.
// ABOUTME: A press fills the composer with /rotate; session.start writes a heartbeat for doctor.
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
    const { context } = await $.session.usage()
    if (context.percent === undefined || context.percent < (await threshold($))) return drawn
    if (!(await ownsRotation($))) return drawn
    const { Box, Button } = await $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        {drawn}
        <Box>
          {/* plain draws "1: label", so the hotkey is discoverable */}
          <Button key="cs-rotate" hotkey="1" plain label="rotate this conversation"
                  onPress={() => rotate($)} />
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

// Only the lead conversation of a cs session may be offered a rotation. The
// rotate skill refuses outside a cs session, .cs/local/disabled opts a
// directory out of cs entirely, and the handoff it writes carries the UUID in
// .cs/local/state, which belongs to the one conversation cs launched: a
// teammate claude in the same directory would arm the lead's marker under the
// lead's identity. The checks run only past the threshold, so an idle band
// costs no stat. The value may be quoted and may carry trailing spaces, as
// cs's own state readers allow.
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
