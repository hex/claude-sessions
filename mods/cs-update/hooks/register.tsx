/* @jsxRuntime classic */
/* @jsx h */
/* @jsxFrag Fragment */
// ABOUTME: cs-update mod: when a cs launch found a newer release, one pane per load with its release notes, `1` to install it in place, Esc for later.
// ABOUTME: Reads the launch's verdict from CS_UPDATE_AVAILABLE (a toast, not the pane, when CS_UPDATE_DECLINED names it), the cs path from CS_BIN, and the span cs cached; /cs-update reopens the pane; session.start writes a heartbeat for doctor.
import type { On, EngineInterface, PluginOptions, RenderElement } from 'claude-code'

declare const h: any
declare const Fragment: any

export const PANE = 'cs-update'
// The /config row (`cs-update.showReleaseNotes`): off, the launch pane is
// skipped and /cs-update still opens it.
export const OPTION = 'showReleaseNotes'
// Doctor observes the mod RUNNING, not merely installed (see the cs mod).
export const HEARTBEAT = '.cs/local/cs-update.heartbeat'
// The finished pane's outcome, written on a clean `cs -update` exit and read
// back on the reloaded module's next render: installing the update rewrites
// this mod's own deployed file, Claude Code reloads it and immediately
// re-renders the open pane, and the reload drops the module state the `done`
// pane was drawing from before this file existed. `session.start` fires
// again after the reload (the engine runs it for each fresh load of a
// plugin), but the re-render comes first, so the restore cannot wait for it.
export const DONE = '.cs/local/cs-update.done'
// Where cs writes the id of the conversation it launched; a teammate claude
// in the same directory has its own id and must not pop its own pane.
export const STATE = '.cs/local/state'
// KEEP IN SYNC with check_update_notify in lib/20-update.sh: the file cs
// caches the pending release's changelog span in, keyed by that version.
export const NOTES = (home: string, version: string) => `${home}/.cache/cs/update-notes-full-${version}`
// How long `cs -update` may take: the download, the checksum, the signature.
export const UPDATE_TIMEOUT_MS = 600000
const VET_TIMEOUT_MS = 10000

// Every line the mod hands the engine to draw on a surface of the engine's
// own: its toasts, /cs-update's replies and its slash menu row, so the design
// lab draws each from these words.
export const TOASTS = {
  declined: (version: string) => `cs ${version} is available · run cs -update to install it, or /cs-update for the notes`,
  notRecorded: (err: string) => `could not record the finished update: ${err}`,
} as const

export const REPLIES = {
  notLead: 'The release-notes pane belongs to the conversation cs launched.',
  nothingPending: 'This launch found no newer cs; the check runs again at the next launch.',
  notesOpen: 'Release notes are in the side pane.',
} as const

export const COMMANDS = {
  'cs-update': { name: 'cs-update', description: 'Release notes for the pending cs update, with 1 to install it.' },
} as const

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

// What the pane shows. Module state survives a /clear (as in the cs mod) and is
// dropped on a reload, which is what "once per load" means. A finished update
// is the one exception: the DONE marker survives the reload the update itself
// causes, and the marker is redrawn from disk, by the Pane render the reload
// triggers immediately and again by the session.start that follows it, each
// a no-op once the other has filled this state.
let version: string | undefined
let sections: Section[] | undefined
let accent: string | undefined
let shown = false
// The update key's life: idle until pressed, running while cs -update is,
// then what happened. `failed` keeps the key, so a transient failure (a
// download) gets another press; `done` retires it, since a second update
// would install the same version again.
export type Phase = 'idle' | 'running' | 'done' | 'failed'
let phase: Phase = 'idle'
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
      await $.command.register(COMMANDS['cs-update'])
    }
    if ((await $.fs.exists(`${e.cwd}/.cs/local`)) && (await mayWriteControlFiles($, e.cwd))) {
      await $.fs.write(`${e.cwd}/${HEARTBEAT}`, `${new Date().toISOString()}\n`)
    }
    // `shown` is this load's: a reload runs register() again and then this
    // hook, so a pending update whose pane was dismissed and never installed
    // gets its pane back; the one an installed update causes finds the DONE
    // marker instead.
    if (!shown && await isLead($, e.cwd)) {
      if (!(await restoreDone($, e.cwd)) && wanted) {
        const pending = await $.env.get('CS_UPDATE_AVAILABLE')
        // The launch's own question was answered no for this version: one
        // line says it is still there, and the pane waits for /cs-update.
        const declined = await $.env.get('CS_UPDATE_DECLINED')
        if (pending && declined === pending) {
          shown = true
          $.ui.toast(TOASTS.declined(pending))
        } else if (pending) { shown = true; await openPane($, e.cwd, pending) }
      }
    }
    return next(e)
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE) return next(e)
    // The engine re-renders the open pane the instant it reloads this
    // module, before the reload's session.start gets a chance to restore
    // it, so a pane asked to draw with no module state
    // tries the marker itself before giving up to the ordinary gate. It asks
    // the lead gate first, as session.start does, so a directory the
    // sessions root does not name gets no pane back.
    if (version === undefined) {
      const cwd = await $.session.cwd()
      if (!(await isLead($, cwd)) || !(await restoreDone($, cwd))) return next(e)
    }
    const el = await $.ui.resolve(e)
    // Every path here has set it: the launch's openPane, or restoreDone's.
    if (version === undefined) throw new Error('cs-update: the pane drew with no pending version')
    return drawPane({ version, sections, accent, phase, outcome }, el, () => runUpdate($))
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
    if (!(await isLead($, cwd))) return { text: REPLIES.notLead }
    const pending = await $.env.get('CS_UPDATE_AVAILABLE')
    if (!pending) return { text: REPLIES.nothingPending }
    // After a reload (which drops the module state) a pane dismissed before
    // the update installed leaves nothing open for the render path to
    // restore, so the command asks the marker itself before it offers an
    // install that already finished.
    if (version === undefined && (await restoreDone($, cwd))) return { text: REPLIES.notesOpen }
    shown = true
    await openPane($, cwd, pending)
    return { text: REPLIES.notesOpen }
  })
}

// What the pane is drawn from: the pending version, its notes, the session
// colour as rgb, and where the update key's life stands.
export type PaneView = { version: string; sections: Section[] | undefined; accent: string | undefined; phase: Phase; outcome: string }

export function drawPane(v: PaneView, el: ReturnType<EngineInterface['ui']['resolve']>, update: () => void | Promise<void>): RenderElement {
  const { Box, Text, Button } = el
  const { version, sections, accent, phase, outcome } = v
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
            {/* a Button is a block: nested in a Text the engine refuses the whole tree (measured in the cs mod), so the keys stand in a Box */}
            <Button key="cs-update-now" hotkey="1" plain label="update now" onPress={update} />
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
}

// The conversation cs launched is the one whose id cs recorded before the
// launch; a teammate in the same directory reads the same file and does not
// match. A directory the sessions root does not name, or one without the
// file, is not a cs session: no pane. The id may be quoted (KEEP IN SYNC with
// ownsRotation in mods/cs).
async function isLead($: EngineInterface, cwd: string): Promise<boolean> {
  if (await $.fs.exists(`${cwd}/.cs/local/disabled`)) return false
  if (!(await isCsSession($, cwd))) return false
  let state: string
  try { state = await $.fs.read(`${cwd}/${STATE}`) } catch { return false }
  const lead = state.match(/^claude_session_id: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
  return lead !== undefined && lead === (await $.session.id())
}

// The /color palette as rgb, since the engine paints rgb(), #hex, ansi256(),
// ansi: and theme keys but draws a bare name like `red` in the default ink. KEEP IN SYNC with _sgr in
// bin/cs-statusline (tests/test_mod_rotate.sh pins every value here against it).
const SESSION_PALETTE: Record<string, string> = {
  red: '220,38,38', blue: '106,155,204', green: '22,163,74', yellow: '202,138,4',
  purple: '130,125,189', orange: '217,119,87', pink: '196,102,134', cyan: '8,145,178',
}

// The session colour cs recorded, for the version headings; none, or a name
// outside the palette, draws them in the default ink.
async function sessionColor($: EngineInterface, cwd: string): Promise<string | undefined> {
  try {
    const state = await $.fs.read(`${cwd}/${STATE}`)
    const name = state.match(/^claude_session_color: *"?([^"\s]+)"?[ \t]*$/m)?.[1]
    return name !== undefined && Object.hasOwn(SESSION_PALETTE, name) ? `rgb(${SESSION_PALETTE[name]})` : undefined
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
// it restored anything: false leaves the caller to its own fallback (the
// launch-pane gate in session.start, or the ordinary render in ui.render). A
// marker naming a version that is no longer CS_UPDATE_AVAILABLE is stale (a
// later launch, nothing pending, or something newer) and is cleared rather
// than redrawn; `$.fs` has no delete, so an empty write is the tombstone and
// empty text reads as absent.
async function restoreDone($: EngineInterface, cwd: string): Promise<boolean> {
  let text: string
  try { text = await $.fs.read(`${cwd}/${DONE}`) } catch { return false }
  const [doneVersion, line] = text.split('\n')
  if (!doneVersion || line === undefined) return false
  const pending = await $.env.get('CS_UPDATE_AVAILABLE')
  if (pending !== doneVersion) {
    if (await mayWriteControlFiles($, cwd)) await $.fs.write(`${cwd}/${DONE}`, '')
    return false
  }
  shown = true; phase = 'done'; outcome = line
  await openPane($, cwd, doneVersion)
  return true
}

// Every write this mod makes into .cs/local asks this first: the sessions root
// names the directory, and cs trusts its control files.
async function mayWriteControlFiles($: EngineInterface, cwd: string): Promise<boolean> {
  return (await isCsSession($, cwd)) && (await sessionVetted($, cwd))
}

// KEEP IN SYNC with isCsSession and resolvedPath in mods/cs (the two mods
// deploy as separate plugins and share no module).
// Whether directory `cwd` is a cs session. Nothing inside a directory can
// prove it: a cloned repository may carry any file under .cs/, .cs/local
// included. The sessions root ($CS_SESSIONS_ROOT, else ~/.claude-sessions) is
// what a clone cannot carry: the directory is a session when the root's entry
// under its own name, or under the session_name an adopted session's state
// records, lands on the directory itself. The recorded name is only a
// candidate, so it may not reach outside the root. Identity is by resolved
// path, as the hooks compare by inode: a link at the root and a home reached
// through a symlink each spell the same directory another way.
async function isCsSession($: EngineInterface, cwd: string): Promise<boolean> {
  const home = await $.env.get('HOME')
  const root = (await $.env.get('CS_SESSIONS_ROOT')) || (home ? `${home}/.claude-sessions` : undefined)
  if (root === undefined) return false
  const here = await resolvedPath($, cwd)
  if (here === undefined) return false
  const dir = cwd.replace(/\/+$/, '')
  const names = [dir.slice(dir.lastIndexOf('/') + 1)]
  let state = ''
  try {
    state = await $.fs.read(`${cwd}/.cs/local/state`)
  } catch {
    // no state: only the directory's own name is a candidate
  }
  const recorded = state.match(/^session_name: *"?([^"\s/]+)"?[ \t]*$/m)?.[1]
  if (recorded !== undefined && recorded !== '.' && recorded !== '..') names.push(recorded)
  for (const name of names) {
    if ((await resolvedPath($, `${root}/${name}`)) === here) return true
  }
  return false
}

// Where `path` lands once every link is followed; undefined when it leads
// nowhere or cannot be read, which proves nothing about a session.
async function resolvedPath($: EngineInterface, path: string): Promise<string | undefined> {
  try {
    return (await $.fs.stat(path, { resolve: true })).realPath
  } catch {
    return undefined
  }
}

// Whether cs trusts this session's control files, by the rule the cs mod and
// the hooks ask (cs -vet-session): while git tracks a file in .cs/local or
// .cs/private, this mod writes nothing there. An answer cs cannot give is a
// no. Nothing is said here: the cs mod toasts the same refusal once.
async function sessionVetted($: EngineInterface, cwd: string): Promise<boolean> {
  const bin = await $.env.get('CS_BIN')
  if (!bin) return false
  try {
    const { exitCode } = await $.process.run([bin, '-vet-session', cwd], { timeoutMs: VET_TIMEOUT_MS })
    return exitCode === 0
  } catch {
    // A spawn that fails is a refusal: the write it guards is skipped.
    return false
  }
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
    const bin = await $.env.get('CS_BIN')
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
        if (await mayWriteControlFiles($, cwd)) await $.fs.write(`${cwd}/${DONE}`, `${version}\n${outcome}\n`)
      } catch (err) {
        $.ui.toast(TOASTS.notRecorded(String(err instanceof Error ? err.message : err)))
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
