// ABOUTME: cs-filter-chat's switch: the per-session file .cs/local/filter-chat (cs's band writes it too), what its text means, and the /filter-chat grammar; and its one /config row, the you ink.
// ABOUTME: Pure. Filter chat is on by default: no file reads on, `on\n` on, `off\n` off, and any other text off with its problem named.
import type { PluginOptions, ThemeKey } from 'claude-code'

/**
 * The per-session truth, shared with cs's band. Relative to
 * `$.session.cwd()`, which both sides read the same way. cs's band reads it
 * with the same rule (mods/cs/hooks/register.tsx readFilterChat) and writes it
 * from its filter chat key (pressFilterChat). A contract between two plugins:
 * KEEP IN SYNC with readFilterChat and pressFilterChat; a test in each mod pins
 * these literals.
 */
export const FILTER_CHAT_FILE = '.cs/local/filter-chat'
export const ON_LINE = 'on\n'
export const OFF_LINE = 'off\n'
/** The directory whose presence says "this may be a cs session". /filter-chat never creates it ($.fs.write would), and a missing filter chat file reads as on only where it exists. */
export const CS_LOCAL = '.cs/local'
/**
 * How long `cs -vet-session` may take before its answer counts as a refusal.
 * Every /filter-chat write asks it first, as cs's band press does, and so does
 * a read that finds FILTER_CHAT_FILE on with no answer cached for it (§20.22,
 * session.vetRefusal, session.vetOnRead). KEEP IN SYNC with VET_TIMEOUT_MS
 * in mods/cs/hooks/register.tsx. The env name `CS_BIN` stays a literal at its
 * one read, as cs's is: validate lists the names a module reads.
 */
export const VET_TIMEOUT_MS = 10000
/** The Button cs's band draws for the switch: `ui.press` reaches cs-filter-chat's hook addressed `{ plugin, element }`. KEEP IN SYNC with cs's buildBandEntries key `cs-filter-chat`. */
export const BAND_PLUGIN = 'cs'
export const BAND_ELEMENT = 'cs-filter-chat'

/** Why a FILTER_CHAT_FILE text reads as off although it is not `off\n`: a write torn before its newline, or any other text. */
export type FilterChatProblem = 'torn' | 'other'

export type FilterChatState =
  | { readonly on: true }
  | { readonly on: false; readonly problem?: FilterChatProblem }

/**
 * What FILTER_CHAT_FILE's text says. Writes are non-atomic, so only a whole
 * line counts and nothing is trimmed: `undefined` (no file) is on, the
 * default; `on\n` is on; `off\n` is off; anything else is off with its problem.
 */
export function filterChatState(text: string | undefined): FilterChatState {
  if (text === undefined || text === ON_LINE) return { on: true }
  if (text === OFF_LINE) return { on: false }
  return { on: false, problem: text.endsWith('\n') ? 'other' : 'torn' }
}

/**
 * What a typed /filter-chat asks for. Every change is this session's (this
 * directory's FILTER_CHAT_FILE). cs's band key does not come through here: it
 * writes FILTER_CHAT_FILE itself, and cs-filter-chat's ui.press hook reads it
 * after next(e).
 *
 *   /filter-chat          toggle: the file's value flipped, written
 *   /filter-chat on|off   that value, written
 *   /filter-chat status   nothing written; FILTER_CHAT_FILE read again, the reply `on` or `off` as vetted
 *   anything else        the usage line
 */
export type FilterChatCommand =
  | { readonly kind: 'toggle' }
  | { readonly kind: 'switch'; readonly on: boolean }
  | { readonly kind: 'status' }
  | { readonly kind: 'usage' }

/** Lowercased and split on whitespace; one word at most. */
export function parseFilterChatArgs(args: string): FilterChatCommand {
  const words = args.trim().toLowerCase().split(/\s+/).filter(word => word !== '')
  const [word] = words
  if (word === undefined) return { kind: 'toggle' }
  if (words.length > 1) return { kind: 'usage' }
  if (word === 'on' || word === 'off') return { kind: 'switch', on: word === 'on' }
  if (word === 'status') return { kind: 'status' }
  return { kind: 'usage' }
}

/**
 * The /config row `cs-filter-chat.youInk`, the manifest's one userConfig field:
 * the theme key your lines draw in, remember by default. Each key passes 4.5:1
 * on the light and dark themes' backgrounds. KEEP IN SYNC with the manifest's
 * `options`; tests/test_mod_filter_chat.sh compares the two.
 */
export const YOU_INK_OPTION = 'youInk'
export const YOU_INKS = ['remember', 'planMode', 'success', 'merged', 'error', 'text'] as const satisfies readonly ThemeKey[]
export type YouInk = typeof YOU_INKS[number]

/**
 * The you ink register's options name. Claude Code holds a stored value to
 * the manifest's options before the mod loads (one outside them reads as the
 * default, and Claude Code says so), so a value YOU_INKS lacks means the
 * manifest and YOU_INKS differ: it throws, naming the value.
 */
export function youInkOf(options: PluginOptions): YouInk {
  const value = options[YOU_INK_OPTION]
  const ink = YOU_INKS.find(key => key === value)
  if (ink === undefined) throw new Error(`cs-filter-chat option ${YOU_INK_OPTION} is ${JSON.stringify(value)}, not one of ${YOU_INKS.join(', ')}: the manifest's options and settings.YOU_INKS differ`)
  return ink
}
