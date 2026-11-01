// ABOUTME: cs-feed's per-load switch: the mirror of .cs/local/feed as cs -vet-session vets it, its reads and writes, and the theme the inks follow.
// ABOUTME: A new Load is made by every register(); the mirror is written by the load's one record read and by event hooks, never by a render.
import type { EngineInterface } from 'claude-code'

import { CS_LOCAL, FEED_FILE, OFF_LINE, ON_LINE, VET_TIMEOUT_MS, feedState } from './settings'
import { logs } from './words'

type $ = EngineInterface

export type Load = {
  /**
   * The mirror: FEED_FILE says on AND cs trusts this session's control files
   * (`vet`, below), so a session cs refuses reads as off. Undefined until the
   * per-load read settles (feedRecord). Written by feedRecord (the load's
   * read) and applyFeed (every later read); never by a render except through
   * feedRecord's one per-load promise.
   */
  on?: boolean
  record?: Promise<boolean>
  /** Writing commands queue here, so each one reads the file the one before it wrote. */
  writes?: Promise<void>
  /**
   * cs's answer on this session's control files for the on the mirror last
   * read (§20.22: the writes and the on-read are vetted). Undefined: not
   * asked for the file's current on, or the file reads off. Set from
   * vetOnRead's answer (by feedRecord at the load's on-read, by
   * applyFeed('status') at an outside flip to on), by applyFeed to 'passed'
   * when a press's write turned the file on (cs's pressFeed vetted it on the
   * way in), and at a successful write's ticketed read-back. A read that
   * finds the file off clears it, so the next on that no writer of ours
   * vetted is vetted again. Cached for the load otherwise: a session cs stops
   * trusting after a pass keeps the pass until the file reads off or the next
   * load (the band labels its key off at cs's next vet).
   */
  vet?: Vetted
  /** The last read-side refusal logged, so each distinct refusal is logged once per load, as cs's band de-duplicates its feed complaint. Cleared by a pass. */
  vetLogged?: string
  /** The last FEED_FILE problem logged (readFeed), so the same unusable text or read error is logged once per load whichever read finds it. */
  feedLogged?: string
  /**
   * Read tickets for FEED_FILE (applyFeed): `started` is taken when a read
   * begins, `applied` is the ticket of the read the mirror holds. A read
   * whose ticket is below `applied` is dropped when it resolves, so the
   * latest-started read wins even when two reads resolve out of order (a
   * typed /feed's read-back beside a band press's read). Two quick band
   * presses do not need it: cs's pressFeed is single-flight and hands the
   * second press the first one's in-flight promise, so it writes once and both
   * hooks' reads start after that write.
   */
  reads: { started: number; applied: number }
  /** Whether the /config theme is a light one, read once per load by feedRecord; the inks follow it. A theme changed mid-load is followed at the next load. */
  light: boolean
}

export function newLoad(): Load {
  return { reads: { started: 0, applied: 0 }, light: false }
}

/**
 * This session's switch, read once per load and mirrored in `load.on`: one
 * per-load promise, started by whichever caller asks first (a render, a
 * command, a press) and awaited by every render, so a render that lands
 * before anything else sees the file, not a default.
 *
 *   const cwd = await $.session.cwd()
 *   fileOn = readFeed(load, $, cwd)                       // absent in a cs session: on
 *   load.light = the /config theme is a light one
 *   load.vet = fileOn ? await vetOnRead(load, $, cwd) : undefined   // off: no cs process
 *   on = fileOn && load.vet === 'passed'
 *
 * Vetted once per load when the file reads on (§20.22: the on-read asks the
 * same cs -vet-session as writeFeed). The feed is on by default, so a cs
 * session with no file pays the vet too: one cs process (0.15-0.44 s, cs's
 * measurement; up to VET_TIMEOUT_MS, then refused, if cs hangs). A refused
 * session reads as off: every hook passes the engine's drawing through,
 * nothing is written, and the refusal is logged once (vetOnRead). cs's band
 * labels the key off there too (`!feedVetRefused && readFeed`: its last vet
 * refused), so both sides agree and both refuse writes (rationale (e)
 * trace 7).
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
 * A mirror, not a per-draw read. The file can change behind it only through
 * a writer other than cs's band press and /feed (a hand edit, a second Claude
 * session in this directory); that is seen at the next press, /feed (/feed
 * status re-reads it first, through applyFeed, and vets a flip to on), or
 * load.
 */
export function feedRecord(load: Load, $: $): Promise<boolean> {
  return load.record ??= (async () => {
    const cwd = await $.session.cwd()
    const fileOn = await readFeed(load, $, cwd)
    load.light = await themeIsLight($)
    load.vet = fileOn ? await vetOnRead(load, $, cwd) : undefined
    load.on = fileOn && load.vet === 'passed'
    return load.on
  })()
}

/**
 * What FEED_FILE says (settings.feedState), logged where it cannot be used:
 *
 *   absent, and CS_LOCAL exists   on (the default)
 *   absent, no CS_LOCAL           off: this directory is no cs session, so no vet and no log
 *   on\n / off\n                  on / off
 *   any other text                off, logged with the path and its problem
 *   a read error but ENOENT       off, logged with the path and the error
 *
 * Each log line is written once per load, whichever read finds it
 * (Load.feedLogged), as the band's readFeed writes each distinct complaint once.
 */
export async function readFeed(load: Load, $: $, cwd: string): Promise<boolean> {
  const path = `${cwd}/${FEED_FILE}`
  let text: string | undefined
  try {
    text = await $.fs.read(path)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (!/\bENOENT\b/.test(message)) {
      await logFeed(load, $, logs.unread(path, message))
      return false
    }
    if (!(await $.fs.exists(`${cwd}/${CS_LOCAL}`))) return false
  }
  const state = feedState(text)
  if (state.on) return true
  if (state.problem !== undefined && text !== undefined) await logFeed(load, $, logs.unusable(path, state.problem, text))
  return false
}

async function logFeed(load: Load, $: $, line: string): Promise<void> {
  if (line === load.feedLogged) return
  load.feedLogged = line
  await $.ui.log(line)
}

/** The /config theme row as $.config.list() returns it; a list that cannot be read is logged and leaves the dark-theme inks. */
async function themeIsLight($: $): Promise<boolean> {
  try {
    const theme = (await $.config.list()).find(row => row.key === 'theme')?.value
    return typeof theme === 'string' && theme.startsWith('light')
  } catch (error) {
    await $.ui.log(logs.themeUnread(error instanceof Error ? error.message : String(error)))
    return false
  }
}

/**
 * Which read applyFeed makes, and so whether cs already vetted the file it
 * reads. `press`: after cs's pressFeed, which vets before it writes. `write`:
 * writeFeed's read-back, after its own vet passed. `status`: /feed status's
 * re-read, after no writer of ours: a flip to on found there arrived from
 * outside both writers (a hand edit, a second Claude process in this
 * directory, a pull), so it is vetted before it turns the feed on.
 */
export type FeedRead = 'press' | 'write' | 'status'

/**
 * Reads FEED_FILE and applies it to the mirror (ticketed, see Load.reads).
 * Called after `await next(e)` in the ui.press hook on cs's `cs-feed` Button
 * ('press'), after cs-feed's own write (writeFeed, 'write'), and by perform()
 * for /feed status ('status'), so status reports the file as vetted (off
 * where cs refuses), not a mirror a hand edit or a second Claude process in
 * this directory left stale.
 *
 *   await feedRecord(load, $)                 // the load's read first: a press during the load's vet neither finds load.on unset nor outranks its ticket
 *   const ticket = ++load.reads.started
 *   const fileOn = await readFeed(...)
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
 * The press path trusts the file it reads after next(e): cs's refusal is cs's
 * module memory, so an outside on that lands after cs-feed's last read and
 * before a press cs refuses reads as the press's write and turns on.
 * Accepted (ruling §20.22: a press's read is not vetted again); the band
 * labels the key off there, and the next load's vet reads it off.
 *
 * The invalidate is cs-feed's own and comes after the mirror changed (spike3
 * M15: an evaluation in flight is drawn again at once with the new value,
 * never blank). It is also what redraws cs's band after a typed /feed:
 * cs-feed hooks the rows, and cs's band redraws on its own next evaluation
 * (the label follows then: inferred, not measured for this pair). Never
 * called from a render.
 */
export async function applyFeed(load: Load, $: $, after: FeedRead): Promise<void> {
  await feedRecord(load, $)
  const ticket = ++load.reads.started
  const cwd = await $.session.cwd()
  const fileOn = await readFeed(load, $, cwd)
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
  if (was === undefined) throw new Error('feed record did not settle')
  const on = fileOn && vet === 'passed'
  load.on = on
  if (asked && vet !== undefined) await reportVet(load, $, vet)
  if (was !== on) await $.ui.invalidate('ui.render')
}

/** What a /feed write did: written, nothing (no .cs/local), or nothing because cs refused this session's control files (the reason, for the reply). */
export type WriteOutcome = 'written' | 'no-session' | { readonly refused: string }

/**
 * Writes this session's switch, from a typed /feed only, and only where cs
 * trusts this session's control files, as cs's band press does (§20.22):
 *
 *   if (!(await $.fs.exists(`${cwd}/${CS_LOCAL}`))) return 'no-session'   // never create .cs/local; no vet spawned
 *   const refusal = await vetRefusal($, cwd)
 *   if (refusal !== undefined) return { refused: refusal }                   // nothing written, the mirror and load.vet untouched
 *   await $.fs.write(`${cwd}/${FEED_FILE}`, on ? ON_LINE : OFF_LINE)
 *   await applyFeed(load, $, 'write')                                       // read back and commit this write's pass with its ticket; no second vet
 *
 * The vet comes after the directory test, so a directory with no .cs/local
 * spawns no cs process, and before the write, so a refused session gets
 * nothing. Its cost is one cs process per writing /feed (0.15-0.44 s,
 * measured by cs), awaited inside the immediate command, mid-turn included.
 * Non-atomic, as the band's: a write torn by a crash leaves a file that reads
 * as off on both sides.
 */
export async function writeFeed(load: Load, $: $, on: boolean): Promise<WriteOutcome> {
  const cwd = await $.session.cwd()
  if (!(await $.fs.exists(`${cwd}/${CS_LOCAL}`))) return 'no-session'
  const refused = await vetRefusal($, cwd)
  if (refused !== undefined) return { refused }
  await $.fs.write(`${cwd}/${FEED_FILE}`, on ? ON_LINE : OFF_LINE)
  await applyFeed(load, $, 'write')
  return 'written'
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
 * says the refusal its own way. writeFeed's caller (perform) puts it in the
 * command's reply, once, to the person who typed it; vetOnRead logs it once
 * per distinct text. cs's band asks again at its next acting step, so the
 * two answer the same rule, not the same call.
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
 * The read-side vet (§20.22: a file that reads on is vetted before the feed
 * turns on). Asked by feedRecord at the load's read when FEED_FILE reads on;
 * applyFeed('status') asks vetRefusal itself for a flip to on no writer of
 * ours vetted, and reports through reportVet. A refusal is logged once per
 * distinct text, as cs's readFeed does with its feed complaint.
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
    await $.ui.log(logs.feedOff(vet.refused))
  }
}
