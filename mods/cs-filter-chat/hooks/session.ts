// ABOUTME: cs-filter-chat's per-load switch: the mirror of the setting CS_FILTER_CHAT as cs -vet-session vets it, and its reads and writes.
// ABOUTME: A new Load is made by every register(); the mirror is written by the load's one record read and by event hooks, never by a render.
import type { EngineInterface } from 'claude-code'

import { CONFIG_FILE, CS_LOCAL, FILTER_CHAT_KEY, VET_TIMEOUT_MS, filterChatFlag } from './settings'
import { logs } from './words'

type $ = EngineInterface

export type Load = {
  /**
   * The mirror: the setting says on AND cs trusts this session's control
   * files (`vet`, below), so a session cs refuses reads as off. Undefined
   * until the per-load read settles (filterChatRecord). Written by
   * filterChatRecord (the load's read) and applyFilterChat (every later read);
   * never by a render except through filterChatRecord's one per-load promise.
   */
  on?: boolean
  record?: Promise<boolean>
  /** Writing commands queue here, so each one reads what the one before it wrote. */
  writes?: Promise<void>
  /**
   * cs's answer on this session's control files for the on the mirror last
   * read (§20.22: the writes and the on-read are vetted). Undefined: not
   * asked for the setting's current on, or the setting reads off. Set from
   * vetOnRead's answer (by filterChatRecord at the load's on-read, by
   * applyFilterChat('status') at an outside flip to on), by applyFilterChat to
   * 'passed' when a press's write turned the setting on (cs's pressFilterChat
   * vetted it on the way in), and at a successful write's ticketed read-back.
   * A read that finds the setting off clears it, so the next on that no writer
   * of ours vetted is vetted again. Cached for the load otherwise: a session
   * cs stops trusting after a pass keeps the pass until the setting reads off or
   * the next load (the band labels its key off at cs's next vet).
   */
  vet?: Vetted
  /** The last read-side refusal logged, so each distinct refusal is logged once per load, as cs's band de-duplicates its filter chat complaint. Cleared by a pass. */
  vetLogged?: string
  /** The last settings file read error logged (readFilterChat); a read that finds the same error again does not log it twice in a row. */
  fileLogged?: string
  /**
   * Read tickets for the setting (applyFilterChat): `started` is taken
   * when a read begins, `applied` is the ticket of the read the mirror holds.
   * A read whose ticket is below `applied` is dropped when it resolves, so
   * the latest-started read wins even when two reads resolve out of order (a
   * typed /filter-chat's read-back beside a band press's read). Two quick band
   * presses do not need it: cs's pressFilterChat is single-flight and hands
   * the second press the first one's in-flight promise, so it writes once and
   * both hooks' reads start after that write.
   */
  reads: { started: number; applied: number }
}

export function newLoad(): Load {
  return { reads: { started: 0, applied: 0 } }
}

/**
 * This session's switch, read once per load and mirrored in `load.on`: one
 * per-load promise, started by whichever caller asks first (a render, a
 * command, a press) and awaited by every render, so a render that lands
 * before anything else sees the setting, not a default.
 *
 *   const cwd = await $.session.cwd()
 *   fileOn = readFilterChat(load, $, cwd)                  // no line: off
 *   load.vet = fileOn ? await vetOnRead(load, $, cwd) : undefined   // off: no cs process
 *   on = fileOn && load.vet === 'passed'
 *
 * Vetted once per load when the setting reads on (§20.22: the on-read asks the
 * same cs -vet-session as writeFilterChat): one cs process (0.15-0.44 s,
 * cs's measurement; up to VET_TIMEOUT_MS, then refused, if cs hangs). A
 * refused session reads as off: every hook passes the engine's drawing
 * through, nothing is written, and the refusal is logged once (vetOnRead).
 * cs's band labels the key off there too
 * (`!filterChatVetRefused && readFilterChat`: its last vet refused), so both
 * sides agree and both refuse writes (rationale (e) trace 7).
 *
 * Where it waits: site() awaits this promise before it paints, so the first
 * hooked draw after a load waits for the vet, and so does every hooked
 * evaluation that arrives before the promise settles, the pass-through ones
 * included, since off or on is not known until cs answers (a row passing
 * through on its own isExpanded excepted: site() returns it before the
 * await). The hook's budget does not count the wait (HookBudget: the clock
 * stops while a $ call is in flight). After it settles, the off path costs
 * no op.
 *
 * A mirror, not a per-draw read. The setting can change behind it only through
 * a writer other than cs's band press and /filter-chat (the /cs pane, a shell,
 * a second Claude session in this directory); that is seen at the next press,
 * /filter-chat (/filter-chat status re-reads it first, through applyFilterChat,
 * and vets a flip to on), or load.
 */
export function filterChatRecord(load: Load, $: $): Promise<boolean> {
  return load.record ??= (async () => {
    const cwd = await $.session.cwd()
    const fileOn = await readFilterChat(load, $, cwd)
    load.vet = fileOn ? await vetOnRead(load, $, cwd) : undefined
    load.on = fileOn && load.vet === 'passed'
    return load.on
  })()
}

/**
 * What the setting says, as cs resolves it, and off outside a cs session:
 *
 *   CS_FILTER_CHAT in the environment   it pins the value: on only at 1
 *   else this session's file            settings.filterChatFlag
 *   else this machine's file            settings.filterChatFlag
 *   neither says                        off (the default): no vet and no log
 *   a read error but ENOENT             that file says nothing, logged with the path and the error
 *
 * A log line that repeats the last one written (Load.fileLogged) is not
 * written again, whichever read finds it; a different line is, and so is a
 * line that returns after another.
 */
export async function readFilterChat(load: Load, $: $, cwd: string): Promise<boolean> {
  const pin = await $.env.get('CS_FILTER_CHAT')
  const on = pin ? pin === '1' : await flagAt(load, $, `${cwd}/${CONFIG_FILE}`) ?? await machineFlag(load, $) ?? false
  return on && await $.fs.exists(`${cwd}/${CS_LOCAL}`)
}

async function machineFlag(load: Load, $: $): Promise<boolean | undefined> {
  const xdg = await $.env.get('XDG_CONFIG_HOME')
  const home = await $.env.get('HOME')
  if (xdg) return flagAt(load, $, `${xdg}/cs/config`)
  return home ? flagAt(load, $, `${home}/.config/cs/config`) : undefined
}

async function flagAt(load: Load, $: $, path: string): Promise<boolean | undefined> {
  try {
    return filterChatFlag(await $.fs.read(path))
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (!/\bENOENT\b/.test(message)) await logFileProblem(load, $, logs.unread(path, message))
    return undefined
  }
}

async function logFileProblem(load: Load, $: $, line: string): Promise<void> {
  if (line === load.fileLogged) return
  load.fileLogged = line
  await $.ui.log(line)
}

/**
 * Which read applyFilterChat makes, and so whether cs already vetted the setting
 * it reads. `press`: after cs's pressFilterChat, which vets before it writes.
 * `write`: writeFilterChat's read-back, after its own vet passed. `status`:
 * /filter-chat status's re-read, after no writer of ours: a flip to on found
 * there arrived from outside both writers (a hand edit, a second Claude
 * process in this directory, a pull), so it is vetted before it turns chat
 * only on.
 */
export type FilterChatRead = 'press' | 'write' | 'status'

/**
 * Reads the setting and applies it to the mirror (ticketed, see
 * Load.reads). Called after `await next(e)` in the ui.press hook on cs's
 * `cs-filter-chat` Button ('press'), after cs-filter-chat's own write
 * (writeFilterChat, 'write'), and by perform() for /filter-chat status
 * ('status'), so status reports the setting as vetted (off where cs refuses),
 * not a mirror a hand edit or a second Claude process in this directory left
 * stale.
 *
 *   await filterChatRecord(load, $)            // the load's read first: a press during the load's vet neither finds load.on unset nor outranks its ticket
 *   const ticket = ++load.reads.started
 *   const fileOn = await readFilterChat(...)
 *   let vet = load.vet
 *   if (!fileOn) vet = undefined                                       // the next on is vetted again unless a writer of ours vetted it
 *   else if (after === 'write') vet = 'passed'                         // this writer's fresh answer, committed with its read ticket
 *   else if (vet === undefined && after !== 'status') vet = 'passed'   // the press vetted it on the way in: no cs process
 *   else if (vet === undefined) vet = await vetRefusal(...)            // an outside flip to on: one cs process
 *   if (ticket < load.reads.applied) return                            // a read started earlier that resolves later changes nothing
 *   load.reads.applied = ticket; load.vet = vet
 *   load.on = fileOn && vet === 'passed'                               // a cached refusal keeps a refused press's unchanged on, off
 *   if (load.on changed) $.ui.invalidate('ui.render')                 // every hooked instance reads the mirror again
 *
 * The press path trusts the setting it reads after next(e): cs's refusal is cs's
 * module memory, so an outside on that lands after cs-filter-chat's last read
 * and before a press cs refuses reads as the press's write and turns on.
 * Accepted (ruling §20.22: a press's read is not vetted again); the band
 * labels the key off there, and the next load's vet reads it off.
 *
 * The invalidate is cs-filter-chat's own and comes after the mirror changed
 * (spike3 M15: an evaluation in flight is drawn again at once with the new
 * value, never blank). It is also what redraws cs's band after a typed
 * /filter-chat: cs-filter-chat hooks the rows, and cs's band redraws on its own
 * next evaluation (the label follows then: inferred, not measured for this
 * pair). Never called from a render.
 */
export async function applyFilterChat(load: Load, $: $, after: FilterChatRead): Promise<void> {
  await filterChatRecord(load, $)
  const ticket = ++load.reads.started
  const cwd = await $.session.cwd()
  const fileOn = await readFilterChat(load, $, cwd)
  if (ticket < load.reads.applied) return
  let vet = load.vet
  let asked = false
  if (!fileOn) vet = undefined
  else if (after === 'write') vet = 'passed'
  else if (vet === undefined && after === 'status') {
    const refused = await vetRefusal($, cwd)
    vet = refused === undefined ? 'passed' : { refused }
    asked = true
  } else if (vet === undefined) vet = 'passed'
  if (ticket < load.reads.applied) return
  load.reads.applied = ticket
  load.vet = vet
  if (vet === 'passed') load.vetLogged = undefined
  const was = load.on
  if (was === undefined) throw new Error('filter chat record did not settle')
  const on = fileOn && vet === 'passed'
  load.on = on
  if (asked && vet !== undefined) await reportVet(load, $, vet)
  if (was !== on) await $.ui.invalidate('ui.render')
}

/** What a /filter-chat write did: written, nothing (no .cs/local), or nothing because cs refused this session's control files (the reason, for the reply). */
export type WriteOutcome = 'written' | 'no-session' | { readonly refused: string }

/**
 * Writes this session's switch, from a typed /filter-chat only, and only
 * where cs trusts this session's control files, as cs's band press does
 * (§20.22):
 *
 *   if (!(await $.fs.exists(`${cwd}/${CS_LOCAL}`))) return 'no-session'   // never create .cs/local; no vet spawned
 *   const refusal = await vetRefusal($, cwd)
 *   if (refusal !== undefined) return { refused: refusal }                   // nothing written, the mirror and load.vet untouched
 *   cs <session> -config set CS_FILTER_CHAT 1|0                              // a failure is a refusal, in cs's words
 *   await applyFilterChat(load, $, 'write')                                  // read back and commit this write's pass with its ticket; no second vet
 *
 * The vet comes after the directory test, so a directory with no .cs/local
 * spawns no cs process, and before the write, so a refused session gets
 * nothing. Its cost is two cs processes per writing /filter-chat (the vet at
 * 0.15-0.44 s, measured by cs), awaited inside the immediate command, mid-turn
 * included. Off writes 0, as the /cs pane does, so it outranks a machine's 1.
 */
export async function writeFilterChat(load: Load, $: $, on: boolean): Promise<WriteOutcome> {
  const cwd = await $.session.cwd()
  if (!(await $.fs.exists(`${cwd}/${CS_LOCAL}`))) return 'no-session'
  const refused = await vetRefusal($, cwd) ?? await configSet($, on)
  if (refused !== undefined) return { refused }
  await applyFilterChat(load, $, 'write')
  return 'written'
}

// The launch's session name, as the /cs pane reads it. A name cs could not have given is no name.
const SESSION_NAME = /^[A-Za-z0-9_][A-Za-z0-9._-]*(@[A-Za-z0-9._-]+)?$/

async function configSet($: $, on: boolean): Promise<string | undefined> {
  const bin = await $.env.get('CS_BIN')
  const name = await $.env.get('CLAUDE_SESSION_NAME')
  if (!bin) return 'the launch did not say where cs is (CS_BIN)'
  if (!name || !SESSION_NAME.test(name)) return 'the launch did not name this session (CLAUDE_SESSION_NAME)'
  try {
    const result = await $.process.run([bin, name, '-config', 'set', FILTER_CHAT_KEY, on ? '1' : '0'], { timeoutMs: VET_TIMEOUT_MS })
    if (result.exitCode === 0) return undefined
    return result.stderr.split(/\r?\n/).filter(line => line.trim() !== '').at(-1) ?? `cs -config set exited ${result.exitCode}`
  } catch (error) {
    return `cs -config set did not run: ${error instanceof Error ? error.message : String(error)}`
  }
}

/**
 * cs's answer on this session's control files, by cs's own rule, asked the
 * way cs's band asks it (mods/cs/hooks/register.tsx sessionVetted):
 *
 *   const bin = await $.env.get("CS_BIN")                        // a literal: validate lists the env names a module reads
 *   no bin                -> 'the launch did not say where cs is (CS_BIN)'
 *   await $.process.run([bin, '-vet-session', cwd], { timeoutMs: VET_TIMEOUT_MS })
 *     exit 0              -> undefined (trusted)
 *     exit != 0           -> the last non-empty stderr line, else `cs -vet-session exited ${code}`
 *   throws (a timeout too) -> `cs -vet-session did not run: ${message}`
 *
 * Returns the refusal or undefined. It reports nothing itself: each caller
 * says the refusal its own way. writeFilterChat's caller (perform) puts it in
 * the command's reply, once, to the person who typed it; vetOnRead logs it
 * once per distinct text. cs's band asks again at its next acting step, so
 * the two answer the same rule, not the same call.
 */
export async function vetRefusal($: $, cwd: string): Promise<string | undefined> {
  const bin = await $.env.get('CS_BIN')
  if (!bin) return 'the launch did not say where cs is (CS_BIN)'
  try {
    const result = await $.process.run([bin, '-vet-session', cwd], { timeoutMs: VET_TIMEOUT_MS })
    if (result.exitCode === 0) return undefined
    return result.stderr.split(/\r?\n/).filter(line => line.trim() !== '').at(-1) ?? `cs -vet-session exited ${result.exitCode}`
  } catch (error) {
    return `cs -vet-session did not run: ${error instanceof Error ? error.message : String(error)}`
  }
}

/** cs's answer on this session's control files: trusted, or refused with cs's own text (vetRefusal's). */
export type Vetted = 'passed' | { readonly refused: string }

/**
 * The read-side vet (§20.22: a setting that reads on is vetted before chat
 * only turns on). Asked by filterChatRecord at the load's read when
 * the setting reads on; applyFilterChat('status') asks vetRefusal itself
 * for a flip to on no writer of ours vetted, and reports through reportVet.
 * A refusal is logged once per distinct text, as cs's readFilterChat does
 * with its filter chat complaint.
 */
export async function vetOnRead(load: Load, $: $, cwd: string): Promise<Vetted> {
  const refused = await vetRefusal($, cwd)
  const vet = refused === undefined ? 'passed' : { refused }
  await reportVet(load, $, vet)
  return vet
}

async function reportVet(load: Load, $: $, vet: Vetted): Promise<void> {
  if (vet === 'passed') {
    load.vetLogged = undefined
    return
  }
  if (vet.refused !== load.vetLogged) {
    load.vetLogged = vet.refused
    await $.ui.log(logs.filterChatOff(vet.refused))
  }
}
