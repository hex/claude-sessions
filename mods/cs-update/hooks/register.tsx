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
// Where cs writes the id of the conversation it launched; a teammate claude
// in the same directory has its own id and must not pop its own pane.
export const STATE = '.cs/local/state'
// KEEP IN SYNC with check_update_notify in lib/20-update.sh: the file cs
// caches the pending release's changelog span in, keyed by that version.
export const NOTES = (home: string, version: string) => `${home}/.cache/cs/update-notes-full-${version}`
// How long `cs -update` may take: the download, the checksum, the signature.
export const UPDATE_TIMEOUT_MS = 600000

export type Section = { version: string; lines: string[] }

// Links, bold and inline code, as changelog_summaries strips them in bash
// (_md_strip_inline): the pane shows the words, never the markup.
export function stripInline(s: string): string {
  return s
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\*\*([^*]*)\*\*/g, '$1')
    .replace(/`([^`]*)`/g, '$1')
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
// dropped on a reload, which is what "once per load" means.
let version: string | undefined
let sections: Section[] | undefined
let accent: string | undefined
let shown = false

export function register(on: On, options: PluginOptions) {
  version = undefined; sections = undefined; accent = undefined; shown = false
  const wanted = options[OPTION] !== false

  on('session.start', async ($, e, next) => {
    if (await $.fs.exists(`${e.cwd}/.cs/local`)) {
      await $.fs.write(`${e.cwd}/${HEARTBEAT}`, `${new Date().toISOString()}\n`)
    }
    if (wanted && !shown && await isLead($, e.cwd)) {
      const pending = await $.env.get('CS_UPDATE_AVAILABLE')
      if (pending) { shown = true; await openPane($, e.cwd, pending) }
    }
    return next(e)
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    if (e.requestId !== PANE || version === undefined) return next(e)
    const { Box, Text, Button } = await $.ui.resolve(e)
    // A lone pane draws no title of its own (the tab shows only with two or
    // more), so the body opens with it. Version headings take the session
    // colour cs recorded, as the status bar's name does; a continuation line
    // hangs under its bullet on the changelog's own indent, which parseSpan
    // keeps in the line (as a bullet keeps its `- `), so the text is drawn
    // verbatim and no margin doubles it.
    return (
      <Box flexDirection="column" paddingX={1}>
        <Text bold>{`cs ${version} is available`}</Text>
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
        <Box marginTop={1}>
          {/* a Button is a block: nested in a Text the engine refuses the whole tree (measured in cs-rotate), so the keys stand in a Box */}
          <Button key="cs-update-now" hotkey="1" plain label="update now" onPress={() => runUpdate($)} />
          <Text dimColor>{'   Esc: later'}</Text>
        </Box>
      </Box>
    )
  })
}

// The conversation cs launched is the one whose id cs recorded before the
// launch; a teammate in the same directory reads the same file and does not
// match. A directory without the file is not a cs session: no pane. The id
// may be quoted (KEEP IN SYNC with ownsRotation in mods/cs-rotate).
async function isLead($: EngineInterface, cwd: string): Promise<boolean> {
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

async function runUpdate(_$: EngineInterface) {
  // Task 4 fills this in.
}
