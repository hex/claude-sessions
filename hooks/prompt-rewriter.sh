#!/usr/bin/env bash
# ABOUTME: $EDITOR shim that rewrites the Claude Code composer buffer in place.
# ABOUTME: ctrl+g round-trips the composer through $EDITOR; this returns a precise prompt.

# No `set -e`: this shim stands between the user and their editor, and every
# error path must leave the buffer exactly as typed rather than lose their text.
set -uo pipefail

target="${1:-}"
[ -n "$target" ] || exit 0

# Claude Code writes the composer buffer to <tmpdir>/claude-prompt-<uuid>.md,
# spawns $EDITOR on it, and replaces the composer with whatever it reads back.
# Every OTHER file handed to us is a genuine edit request — /memory, an opened
# transcript, a git commit message — and belongs to the user's real editor.
case "$(basename "$target")" in
    claude-prompt-*.md) ;;
    *)
        # shellcheck disable=SC2086  # deliberate: an editor may carry flags ("code -w")
        exec ${CS_REAL_EDITOR:-vi} "$target"
        ;;
esac

# Separate from CS_CLARIFY_DISABLE on purpose: silencing the clarifying
# questions should not also silence the rewriter, and vice versa.
[ "${CS_REWRITE_DISABLE:-}" = "1" ] && exit 0

prompt=$(cat "$target" 2>/dev/null) || exit 0

# Strip leading whitespace for the classification only; the rewriter still
# receives the buffer as typed.
lead=${prompt#"${prompt%%[![:space:]]*}"}

case "$lead" in
    # Nothing to rewrite, and a slash command, shell passthrough or memory entry
    # is already precise — rewriting one would corrupt it into prose.
    ''|/*|'!'*|'#'*) exit 0 ;;
esac

# The composer buffer holds PLACEHOLDERS for pasted text and images, not their
# bodies. Rewriting the placeholder away silently destroys the attachment, so a
# buffer carrying one is passed through untouched.
case "$prompt" in
    *'[Pasted text'*|*'[Image'*) exit 0 ;;
esac

# The rewriter reads the prompt on stdin and writes the rewrite to stdout.
# Overridable so the tests can exercise the plumbing without a model, and so a
# user can supply their own.
rewritten=$(printf '%s' "$prompt" | ${CS_REWRITE_CMD:-"$(dirname "$0")/prompt-rewriter-model.sh"} 2>/dev/null) || exit 0

# An empty or whitespace-only rewrite means the rewriter failed in a way that
# did not set a status. Writing it would silently erase what the user typed.
[ -n "${rewritten//[[:space:]]/}" ] || exit 0

# tmp+rename so a crash mid-write cannot leave a truncated buffer.
printf '%s' "$rewritten" > "$target.cs-tmp" 2>/dev/null || exit 0
mv "$target.cs-tmp" "$target" 2>/dev/null || rm -f "$target.cs-tmp" 2>/dev/null
exit 0
