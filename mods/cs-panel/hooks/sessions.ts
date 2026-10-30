// ABOUTME: What cs says about its sessions, parsed into the panel's domain: the `cs -list --porcelain` records, a base's readiness records,
// ABOUTME: the keys a row offers and whether a feature may be retired. Pure: no `$`, so the design lab and the tests call it directly.

// A name cs can address. Only sessionName makes one, from visible ASCII, so a
// SessionName is one cell per character with no tab, space or newline inside:
// draw.tsx counts its cells with `.length`. Which names cs addresses is cs's
// rule (its own validators filter the porcelain); this is the cell guarantee.
export type SessionName = string & { readonly __sessionName: unique symbol }

export function sessionName(text: string): SessionName | undefined {
  return /^[!-~]+$/.test(text) ? text as SessionName : undefined
}

// One session as `cs -list --porcelain` describes it. Unknown stays unknown: a
// missing context reading and a mailbox behind a locked vault are `undefined`,
// never 0.
export type Session = {
  name: SessionName
  // Set for a feature session `<base>@<task>`: the base whose lead
  // conversation lands it, and the task /finish takes.
  feature: { base: SessionName; task: string } | undefined
  // cs's display-live rule: the lock pid runs, or the heartbeat is fresh.
  live: boolean
  // 0-100.
  context: number | undefined
  // Unread mails; undefined when the vault is locked, where `cs <name> -msg`
  // refuses too.
  unread: number | undefined
  // A base's git-verified features; 0 for a feature.
  features: number
}

// The first line cs gave that is not a record, for the pane to name.
export type Unreadable = { unreadable: string }

// Five tab fields per line, each against its pattern in the porcelain
// contract, or the whole answer is refused with the first bad line: skew
// shows as a refusal, never as shifted columns. An empty answer is no
// sessions.
export function parseList(stdout: string): Session[] | Unreadable {
  const sessions: Session[] = []
  for (const line of stdout.split('\n')) {
    if (line === '') continue
    const session = recordOf(line.split('\t'))
    if (session === undefined) return { unreadable: line }
    sessions.push(session)
  }
  return sessions
}

function recordOf(fields: string[]): Session | undefined {
  const [field, live, context, unread, features] = fields
  if (fields.length !== 5 || field === undefined || live === undefined || context === undefined || unread === undefined || features === undefined) return undefined
  const name = sessionName(field)
  if (name === undefined || !/^[01]$/.test(live) || !/^(\d{1,3}|-)$/.test(context) || !/^(\d+|-)$/.test(unread) || !/^\d+$/.test(features)) return undefined
  const percent = context === '-' ? undefined : Number(context)
  if (percent !== undefined && percent > 100) return undefined
  const at = name.indexOf('@')
  let feature: Session['feature']
  if (at !== -1) {
    const base = sessionName(name.slice(0, at))
    const task = name.slice(at + 1)
    if (base === undefined || task === '') return undefined
    feature = { base, task }
  }
  return { name, feature, live: live === '1', context: percent, unread: unread === '-' ? undefined : Number(unread), features: Number(features) }
}

// What a row offers, in strip order. One list: draw.tsx's ACTIONS table is
// keyed by it, and a press is checked against it.
export type Action = 'open' | 'mail' | 'retire'

// The actions a session offers this conversation, `self` being the name cs
// launched it under (CLAUDE_SESSION_NAME, the name cs -msg refuses to mail).
//   open   : not live and not self. Raising a live session is peer control,
//            and cs -spawn refuses a live one anyway.
//   mail   : not self, and the mailbox is reachable.
//   retire : a feature that is not live. A live feature holds its worktree
//            lock, which /finish refuses on either route, so the key waits
//            for that session to close. Which route lands it is the
//            retire's business, not the strip's.
export function actionsOf(s: Session, self: SessionName | undefined): Action[] {
  const isSelf = s.name === self
  const actions: Action[] = []
  if (!s.live && !isSelf) actions.push('open')
  if (!isSelf && s.unread !== undefined) actions.push('mail')
  if (s.feature !== undefined && !s.live) actions.push('retire')
  return actions
}

// What a row waits on after a press. While set, the row offers nothing, so a
// second press cannot start a second run.
export type Pending = 'opening' | 'mailing' | 'checking' | 'retiring'

// One drawn row: a session placed in the list, with what it offers now.
export type Row = {
  session: Session
  // 1: a feature drawn under its base; 0: a base, or a feature whose base is
  // not listed (archived or gone), drawn by its full name.
  depth: 0 | 1
  isSelf: boolean
  pending: Pending | undefined
  // actionsOf, or none while pending.
  actions: readonly Action[]
}

// The list as drawn: bases in the porcelain's order, each followed by its
// features; features whose base is not listed close the list.
export function rowsOf(sessions: readonly Session[], self: SessionName | undefined, pending: ReadonlyMap<SessionName, Pending>): Row[] {
  const row = (session: Session, depth: 0 | 1): Row => {
    const waiting = pending.get(session.name)
    return { session, depth, isSelf: session.name === self, pending: waiting, actions: waiting === undefined ? actionsOf(session, self) : [] }
  }
  const featuresOf = new Map<SessionName, Session[]>()
  for (const s of sessions) {
    if (s.feature === undefined) continue
    const bucket = featuresOf.get(s.feature.base)
    if (bucket === undefined) featuresOf.set(s.feature.base, [s])
    else bucket.push(s)
  }
  const rows: Row[] = []
  for (const s of sessions) {
    if (s.feature !== undefined) continue
    rows.push(row(s, 0))
    for (const f of featuresOf.get(s.name) ?? []) rows.push(row(f, 1))
    featuresOf.delete(s.name)
  }
  for (const orphans of featuresOf.values()) for (const f of orphans) rows.push(row(f, 0))
  return rows
}
