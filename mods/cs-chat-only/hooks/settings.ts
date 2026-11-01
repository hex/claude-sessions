// ABOUTME: cs-chat-only's switch: the per-session file .cs/local/chat-only (cs's band writes it too), what its text means, and the /chat-only grammar.
// ABOUTME: Pure. Chat only is on by default: no file reads on, `on\n` on, `off\n` off, and any other text off with its problem named.

/**
 * The per-session truth, shared with cs's band. Relative to
 * `$.session.cwd()`, which both sides read the same way. cs's band reads it
 * with the same rule (mods/cs/hooks/register.tsx readChatOnly) and writes it
 * from its chat only key (pressChatOnly). A contract between two plugins:
 * KEEP IN SYNC with readChatOnly and pressChatOnly; a test in each mod pins
 * these literals.
 */
export const CHAT_ONLY_FILE = '.cs/local/chat-only'
export const ON_LINE = 'on\n'
export const OFF_LINE = 'off\n'
/** The directory whose presence says "this may be a cs session". /chat-only never creates it ($.fs.write would), and a missing chat only file reads as on only where it exists. */
export const CS_LOCAL = '.cs/local'
/**
 * How long `cs -vet-session` may take before its answer counts as a refusal.
 * Every /chat-only write asks it first, as cs's band press does, and so does
 * a read that finds CHAT_ONLY_FILE on with no answer cached for it (§20.22,
 * session.vetRefusal, session.vetOnRead). KEEP IN SYNC with VET_TIMEOUT_MS
 * in mods/cs/hooks/register.tsx. The env name `CS_BIN` stays a literal at its
 * one read, as cs's is: validate lists the names a module reads.
 */
export const VET_TIMEOUT_MS = 10000
/** The Button cs's band draws for the switch: `ui.press` reaches cs-chat-only's hook addressed `{ plugin, element }`. KEEP IN SYNC with cs's buildBandEntries key `cs-chat-only`. */
export const BAND_PLUGIN = 'cs'
export const BAND_ELEMENT = 'cs-chat-only'

/** Why a CHAT_ONLY_FILE text reads as off although it is not `off\n`: a write torn before its newline, or any other text. */
export type ChatOnlyProblem = 'torn' | 'other'

export type ChatOnlyState =
  | { readonly on: true }
  | { readonly on: false; readonly problem?: ChatOnlyProblem }

/**
 * What CHAT_ONLY_FILE's text says. Writes are non-atomic, so only a whole
 * line counts and nothing is trimmed: `undefined` (no file) is on, the
 * default; `on\n` is on; `off\n` is off; anything else is off with its problem.
 */
export function chatOnlyState(text: string | undefined): ChatOnlyState {
  if (text === undefined || text === ON_LINE) return { on: true }
  if (text === OFF_LINE) return { on: false }
  return { on: false, problem: text.endsWith('\n') ? 'other' : 'torn' }
}

/**
 * What a typed /chat-only asks for. Every change is this session's (this
 * directory's CHAT_ONLY_FILE). cs's band key does not come through here: it
 * writes CHAT_ONLY_FILE itself, and cs-chat-only's ui.press hook reads it
 * after next(e).
 *
 *   /chat-only          toggle: the file's value flipped, written
 *   /chat-only on|off   that value, written
 *   /chat-only status   nothing written; CHAT_ONLY_FILE read again, the reply `on` or `off` as vetted
 *   anything else        the usage line
 */
export type ChatOnlyCommand =
  | { readonly kind: 'toggle' }
  | { readonly kind: 'switch'; readonly on: boolean }
  | { readonly kind: 'status' }
  | { readonly kind: 'usage' }

/** Lowercased and split on whitespace; one word at most. */
export function parseChatOnlyArgs(args: string): ChatOnlyCommand {
  const words = args.trim().toLowerCase().split(/\s+/).filter(word => word !== '')
  const [word] = words
  if (word === undefined) return { kind: 'toggle' }
  if (words.length > 1) return { kind: 'usage' }
  if (word === 'on' || word === 'off') return { kind: 'switch', on: word === 'on' }
  if (word === 'status') return { kind: 'status' }
  return { kind: 'usage' }
}
