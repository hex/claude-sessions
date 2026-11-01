// ABOUTME: cs-clean-chat's $.state names: `typing`, a counter the typing clock bumps while a turn runs; the working line reads it, so each bump redraws that line alone.
// ABOUTME: Declared once here so the ref is typed; KEEP IN SYNC with TYPING in session.ts.
declare module 'claude-code' {
  interface PluginState {
    'cs-clean-chat': { typing: number }
  }
}
