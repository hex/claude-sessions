// ABOUTME: cs-filter-chat's switch: the cs setting CS_FILTER_CHAT, what a settings file's text says of it, and the /filter-chat grammar; and its one /config row, the you ink.
// ABOUTME: Pure. Filter chat is off by default: no line reads off, the last `1` or `0` line wins.
import type { PluginOptions, ThemeKey } from 'claude-code'

/**
 * The switch is the cs setting CS_FILTER_CHAT, read as cs reads a setting: the
 * environment pins it, else this session's file, else this machine's. Only cs
 * writes those files (`cs <session> -config set`). cs's band reads it by the
 * same rule. KEEP IN SYNC with readFilterChat in mods/cs/hooks/register.tsx and
 * _cs_config_read in lib/03-config.sh.
 */
export const CONFIG_FILE = '.cs/local/config'
export const FILTER_CHAT_KEY = 'CS_FILTER_CHAT'
/** The directory whose presence says "this may be a cs session". /filter-chat never creates it ($.fs.write would). */
export const CS_LOCAL = '.cs/local'
/**
 * How long `cs -vet-session` may take before its answer counts as a refusal.
 * Every /filter-chat write asks it first, as cs's band press does, and so does
 * a read that finds the setting on with no answer cached for it (§20.22,
 * session.vetRefusal, session.vetOnRead). KEEP IN SYNC with VET_TIMEOUT_MS
 * in mods/cs/hooks/register.tsx. The env name `CS_BIN` stays a literal at its
 * one read, as cs's is: validate lists the names a module reads.
 */
export const VET_TIMEOUT_MS = 10000
/** The Button cs's band draws for the switch: `ui.press` reaches cs-filter-chat's hook addressed `{ plugin, element }`. KEEP IN SYNC with cs's buildBandEntries key `cs-filter-chat`. */
export const BAND_PLUGIN = 'cs'
export const BAND_ELEMENT = 'cs-filter-chat'

/**
 * What a settings file's text says of the key: the last line naming it with a
 * value cs accepts, `1` or `0`, undefined with none. The key is the text before
 * the line's first `=`, and nothing is trimmed.
 */
export function filterChatFlag(text: string): boolean | undefined {
  let flag: boolean | undefined
  for (const line of text.split('\n')) {
    const at = line.indexOf('=')
    if (at < 0 || line.slice(0, at) !== FILTER_CHAT_KEY) continue
    const value = line.slice(at + 1)
    if (value === '1' || value === '0') flag = value === '1'
  }
  return flag
}

/**
 * What a typed /filter-chat asks for. Every change is this session's (this
 * directory's file). cs's band key does not come through here: it runs the
 * same cs write itself, and cs-filter-chat's ui.press hook reads the setting
 * after next(e).
 *
 *   /filter-chat          toggle: the setting's value flipped, written
 *   /filter-chat on|off   that value, written
 *   /filter-chat status   nothing written; the setting read again, the reply `on` or `off` as vetted
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
