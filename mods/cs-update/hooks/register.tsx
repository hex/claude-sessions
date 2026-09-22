/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-update mod: when a cs launch found a newer release, one pane per load with its release notes, `1` to install it in place, Esc for later.
// ABOUTME: Reads the launch's verdict from CS_UPDATE_AVAILABLE / CS_UPDATE_BIN and the span cs cached; /cs-update reopens the pane; session.start writes a heartbeat for doctor.
import type { On, EngineInterface, PluginOptions } from 'claude-code'

declare const h: any
declare const Fragment: any

export const PANE = 'cs-update'
// The /config row (`cs-update.showReleaseNotes`): off, the launch pane is
// skipped and /cs-update still opens it.
export const OPTION = 'showReleaseNotes'
// Doctor observes the mod RUNNING, not merely installed (see cs-rotate).
export const HEARTBEAT = '.cs/local/cs-update.heartbeat'
// The finished pane's outcome, written on a clean `cs -update` exit and read
// back by session.start: installing the update rewrites this mod's own
// deployed file, Claude Code reloads it, and the reload drops the module
// state the `done` pane was drawing from before this file existed.
export const DONE = '.cs/local/cs-update.done'
// Where cs writes the id of the conversation it launched; a teammate claude
// in the same directory has its own id and must not pop its own pane.
export const STATE = '.cs/local/state'
// KEEP IN SYNC with check_update_notify in lib/20-update.sh: the file cs
// caches the pending release's changelog span in, keyed by that version.
export const NOTES = (home: string, version: string) => `${home}/.cache/cs/update-notes-full-${version}`
// How long `cs -update` may take: the download, the checksum, the signature.
export const UPDATE_TIMEOUT_MS = 600000

export type Section = { version: string; lines: string[] }

// Links, bold and inline code, as _md_strip_inline strips them in bash: the
// link text survives a replace, but every `**` and every backtick is removed
// outright, paired or not, so the pane never shows raw markup.
export function stripInline(s: string): string {
  return s
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\*\*/g, '')
    .replace(/`/g, '')
}

// The span as check_update_notify caches it: `## X.Y.Z` opens a section; its
// prose and bullets are kept in order with the marks stripped; `###` labels,
// comments and blank lines are dropped. A continuation line keeps its indent.
export function parseSpan(text: string): Section[] {
  const sections: Section[] = []
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\s+$/, '')
    if (line.startsWith('## ')) { sections.push({ version: line.slice(3).trim(), lines: [] }); continue }
    if (sections.length === 0) continue
    if (line === '' || line.startsWith('#') || line.startsWith('<!--')) continue
    sections[sections.length - 1].lines.push(stripInline(line))
  }
  return sections
}

// What the pane shows. Module state survives a /clear (as in cs-rotate) and is
// dropped on a reload, which is what "once per load" means. A finished update
// is the one exception: the DONE marker survives the reload the update itself
// causes, and session.start redraws it from disk before this state would
// otherwise sit empty.
let version: string | undefined
let sections: Section[] | undefined
let accent: string | undefined
let shown = false
// The update key's life: idle until pressed, running while cs -update is,
// then what happened. `failed` keeps the key, so a transient failure (a
// download) gets another press; `done` retires it, since a second update
// would install the same version again.
let phase: 'idle' | 'running' | 'done' | 'failed' = 'idle'
let outcome = ''
let registered = false

export function register(on: On, options: PluginOptions) {
  version = undefined; sections = undefined; accent = undefined; shown = false
  phase = 'idle'; outcome = ''
  registered = false
  const wanted = options[OPTION] !== false

  on('session.start', async ($, e, next) => {
    if (!registered) {
      registered = true
      await $.command.register({ name: 'cs-update', description: 'Release notes for the pending cs update, with 1 to install it.' })
    }
    if (await $.fs.exists(`${e.cwd}/.cs/local`)) {
      await $.fs.write(`${e.cwd}/${HEARTBEAT}`, `${new Date().toISOString()}\n`)
    }
    if (!shown && await isLead($, e.cwd)) {
      if (!(await restoreDone($, e.cwd)) && wanted) {
        const pending = await $.env.get('CS_UPDATE_AVAILABLE')
        if (pending) { shown = true; await openPane($, e.cwd, pending) }
      }
    }
    return next(e)
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE || version === undefined) return next(e)
    const { Box, Text, Button } = await $.ui.resolve(e)
    // A lone pane draws no title of its own (the tab shows only with two or
    // more), so the body opens with it. The pane does not scroll (measured
    // live 2026-09-22 on Claude Code 2.1.278), and a long changelog span
    // pushes anything below it off the bottom, so the keys sit right under
    // the title, above the notes, where a long span can never hide them.
    // Version headings take the session colour cs recorded, as the status
    // bar's name does; a continuation line hangs under its bullet on the
    // changelog's own indent, which parseSpan keeps in the line (as a bullet
    // keeps its `- `), so the text is drawn verbatim and no margin doubles it.
    return (
      <Box flexDirection="column" paddingX={1}>
        <Text bold>{`cs ${version} is available`}</Text>
        <Box marginTop={1} flexDirection="column">
          {phase === 'running' && <Text dimColor>{`updating… running cs -update ${version}`}</Text>}
          {(phase === 'done' || phase === 'failed') && <Text>{outcome}</Text>}
          {(phase === 'idle' || phase === 'failed') && (
            <Box>
              {/* a Button is a block: nested in a Text the engine refuses the whole tree (measured in cs-rotate), so the keys stand in a Box */}
              <Button key="cs-update-now" hotkey="1" plain label="update now" onPress={() => runUpdate($)} />
              <Text dimColor>{'   Esc: later'}</Text>
            </Box>
          )}
          {phase === 'idle' && <Text dimColor>{'Installs in place; the new files take effect on your next launch.'}</Text>}
          {phase === 'done' && <Text dimColor>{'Esc: close'}</Text>}
        </Box>
        {sections === undefined || sections.length === 0
          ? <Box marginTop={1}><Text>{`Release notes could not be fetched at launch; the update is ${version}.`}</Text></Box>
          : sections.map(s => (
              <Box key={`v-${s.version}`} flexDirection="column" marginTop={1}>
                <Text bold color={accent}>{s.version}</Text>
                {s.lines.map((line, j) => (
                  <Box key={`l-${s.version}-${j}`}>
                    <Text>{line}</Text>
                  </Box>
                ))}
              </Box>
            ))}
      </Box>
    )
  })

  // On demand: the same pane, whether or not the launch opened it (the
  // option off, or dismissed). A registered command is answered with
  // `{ text }` (the contract; an unanswered run prints "no hook answered"),
  // so the pane carries the notes and the text just points at it. A launch
  // that found nothing pending has nothing to show, and says so instead; a
  // teammate (which inherits the exports) is refused as the launch pane
  // refuses it.
  on('command.run', { command: 'cs-update' }, async ($, e) => {
    const cwd = await $.session.cwd()
    if (!(await isLead($, cwd))) return { text: 'The release-notes pane belongs to the conversation cs launched.' }
    const pending = await $.env.get('CS_UPDATE_AVAILABLE')
    if (!pending) return { text: 'This launch found no newer cs; the check runs again at the next launch.' }
    shown = true
    await openPane($, cwd, pending)
    return { text: 'Release notes are in the side pane.' }
  })
}

// The conversation cs launched is the one whose id cs recorded before the
// launch; a teammate in the same directory reads the same file and does not
// match. A directory without the file is not a cs session: no pane. The id
// may be quoted (KEEP IN SYNC with ownsRotation in mods/cs-rotate).
async function isLead($: EngineInterface, cwd: string): Promise<boolean> {
  if (await $.fs.exists(`${cwd}/.cs/local/disabled`)) return false
  let state: string
  try { state = await $.fs.read(`${cwd}/${STATE}`) } catch { return false }
  const lead = state.match(/^claude_session_id: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
  return lead !== undefined && lead === (await $.session.id())
}

// The session colour cs recorded, for the version headings; none is fine.
async function sessionColor($: EngineInterface, cwd: string): Promise<string | undefined> {
  try {
    const state = await $.fs.read(`${cwd}/${STATE}`)
    return state.match(/^claude_session_color: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
  } catch { return undefined }
}

async function openPane($: EngineInterface, cwd: string, pending: string) {
  version = pending
  accent = await sessionColor($, cwd)
  const home = await $.env.get('HOME')
  let text = ''
  try { text = home ? await $.fs.read(NOTES(home, pending)) : '' } catch { text = '' }
  sections = parseSpan(text)
  // focus is a request the surface grants only over an idle, empty composer;
  // without it the keys stay with the prompt and `1` does nothing.
  await $.ui.open({ id: PANE, title: `cs ${pending} is available`, focus: true, closeOnEscape: true })
}

// Restores the finished pane from the DONE marker on a reload, since the
// reload itself drops the module state the pane was showing. Answers whether
// it restored anything: false leaves the caller free to fall through to the
// ordinary launch-pane gate. A marker naming a version that is no longer
// CS_UPDATE_AVAILABLE is stale (a later launch, nothing pending, or something
// newer) and is cleared rather than redrawn; `$.fs` has no delete, so an empty
// write is the tombstone and empty text reads as absent.
async function restoreDone($: EngineInterface, cwd: string): Promise<boolean> {
  let text: string
  try { text = await $.fs.read(`${cwd}/${DONE}`) } catch { return false }
  const [doneVersion, line] = text.split('\n')
  if (!doneVersion || line === undefined) return false
  const pending = await $.env.get('CS_UPDATE_AVAILABLE')
  if (pending !== doneVersion) {
    await $.fs.write(`${cwd}/${DONE}`, '')
    return false
  }
  shown = true; phase = 'done'; outcome = line
  await openPane($, cwd, doneVersion)
  return true
}

// Runs the update cs would run from the shell, by the path launch exported
// (no shell: `$.process.run` takes an argv, and the claude process's PATH is
// not the launching shell's). The pane keeps the outcome until dismissed, so
// it is read rather than flashed. The new files take effect on the next
// launch for the rest of this claude, but Claude Code reloads this mod's own
// file as soon as the update installs it, which is why a clean exit also
// writes the DONE marker restoreDone reads back.
async function runUpdate($: EngineInterface) {
  // Claimed before the first await: two presses in one tick must not both
  // pass the guard and start two installers.
  if (phase === 'running' || phase === 'done') return
  phase = 'running'; outcome = ''
  $.ui.invalidate('ui.render')
  try {
    const bin = await $.env.get('CS_UPDATE_BIN')
    if (!bin) {
      phase = 'failed'; outcome = 'The launch did not say where cs is; run `cs -update` from a shell.'
      $.ui.invalidate('ui.render'); return
    }
    const { exitCode, stderr } = await $.process.run([bin, '-update'], { timeoutMs: UPDATE_TIMEOUT_MS })
    if (exitCode === 0) {
      // Version-neutral: cs -update resolves the latest release when it runs,
      // which may be newer than the one this launch saw.
      phase = 'done'; outcome = 'Update finished. Takes effect on your next launch.'
      try {
        const cwd = await $.session.cwd()
        await $.fs.write(`${cwd}/${DONE}`, `${version}\n${outcome}\n`)
      } catch (err) {
        $.ui.toast(`cs-update: could not record the finished update: ${String(err instanceof Error ? err.message : err)}`)
      }
    } else {
      const tail = stderr.split('\n').filter(l => l.trim() !== '').slice(-5).join('\n')
      phase = 'failed'; outcome = `cs -update exited ${exitCode}.\n${tail}`
    }
  } catch (err) {
    phase = 'failed'; outcome = `cs -update did not run: ${String(err instanceof Error ? err.message : err)}`
  }
  $.ui.invalidate('ui.render')
}
