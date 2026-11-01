// ABOUTME: cs-clean-chat's switch: the per-session file .cs/local/clean-chat (cs's band writes it too), what its text means, and the /clean-chat grammar.
// ABOUTME: Pure. Clean chat is on by default: no file reads on, `on\n` on, `off\n` off, and any other text off with its problem named.

/**
 * The per-session truth, shared with cs's band. Relative to
 * `$.session.cwd()`, which both sides read the same way. cs's band reads it
 * with the same rule (mods/cs/hooks/register.tsx readCleanChat) and writes it
 * from its clean chat key (pressCleanChat). A contract between two plugins:
 * KEEP IN SYNC with readCleanChat and pressCleanChat; a test in each mod pins
 * these literals.
 */
export const CLEAN_CHAT_FILE = '.cs/local/clean-chat'
export const ON_LINE = 'on\n'
export const OFF_LINE = 'off\n'
/** The directory whose presence says "this may be a cs session". /clean-chat never creates it ($.fs.write would), and a missing clean chat file reads as on only where it exists. */
export const CS_LOCAL = '.cs/local'
/**
 * How long `cs -vet-session` may take before its answer counts as a refusal.
 * Every /clean-chat write asks it first, as cs's band press does, and so does
 * a read that finds CLEAN_CHAT_FILE on with no answer cached for it (§20.22,
 * session.vetRefusal, session.vetOnRead). KEEP IN SYNC with VET_TIMEOUT_MS
 * in mods/cs/hooks/register.tsx. The env name `CS_BIN` stays a literal at its
 * one read, as cs's is: validate lists the names a module reads.
 */
export const VET_TIMEOUT_MS = 10000
/** The Button cs's band draws for the switch: `ui.press` reaches cs-clean-chat's hook addressed `{ plugin, element }`. KEEP IN SYNC with cs's buildBandEntries key `cs-clean-chat`. */
export const BAND_PLUGIN = 'cs'
export const BAND_ELEMENT = 'cs-clean-chat'

/** Why a CLEAN_CHAT_FILE text reads as off although it is not `off\n`: a write torn before its newline, or any other text. */
export type CleanChatProblem = 'torn' | 'other'

export type CleanChatState =
  | { readonly on: true }
  | { readonly on: false; readonly problem?: CleanChatProblem }

/**
 * What CLEAN_CHAT_FILE's text says. Writes are non-atomic, so only a whole
 * line counts and nothing is trimmed: `undefined` (no file) is on, the
 * default; `on\n` is on; `off\n` is off; anything else is off with its problem.
 */
export function cleanChatState(text: string | undefined): CleanChatState {
  if (text === undefined || text === ON_LINE) return { on: true }
  if (text === OFF_LINE) return { on: false }
  return { on: false, problem: text.endsWith('\n') ? 'other' : 'torn' }
}

/**
 * What a typed /clean-chat asks for. Every change is this session's (this
 * directory's CLEAN_CHAT_FILE). cs's band key does not come through here: it
 * writes CLEAN_CHAT_FILE itself, and cs-clean-chat's ui.press hook reads it
 * after next(e).
 *
 *   /clean-chat          toggle: the file's value flipped, written
 *   /clean-chat on|off   that value, written
 *   /clean-chat status   nothing written; CLEAN_CHAT_FILE read again, the reply `on` or `off` as vetted
 *   anything else        the usage line
 */
export type CleanChatCommand =
  | { readonly kind: 'toggle' }
  | { readonly kind: 'switch'; readonly on: boolean }
  | { readonly kind: 'status' }
  | { readonly kind: 'usage' }

/** Lowercased and split on whitespace; one word at most. */
export function parseCleanChatArgs(args: string): CleanChatCommand {
  const words = args.trim().toLowerCase().split(/\s+/).filter(word => word !== '')
  const [word] = words
  if (word === undefined) return { kind: 'toggle' }
  if (words.length > 1) return { kind: 'usage' }
  if (word === 'on' || word === 'off') return { kind: 'switch', on: word === 'on' }
  if (word === 'status') return { kind: 'status' }
  return { kind: 'usage' }
}
