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

# Claude Code spawns this shim with stdio inherited onto a BLANK alternate
# screen and blocks until it exits, so the terminal belongs to us for the whole
# rewrite and everything drawn here is torn down with that screen — nothing
# reaches the scrollback. All of it is gated on a tty, so a piped run draws
# nothing at all.
_spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _b=$'\033[1m'; _d=$'\033[2m'; _r=$'\033[0m'
else
    _b=''; _d=''; _r=''
fi

# claude-haiku-4-5-20251001 -> haiku 4.5
_model_label() {
    printf '%s' "${CS_REWRITE_MODEL:-claude-haiku-4-5-20251001}" \
        | sed -e 's/^claude-//' -e 's/-[0-9]\{8\}$//' \
              -e 's/\([0-9]\)-\([0-9]\)/\1.\2/g' -e 's/-/ /g'
}

# The static part of the screen: drawn once, so the poll loop only ever
# repaints its own last line.
_paint_screen() {
    local cols title label pad
    cols=$(tput cols 2>/dev/null) || cols=80
    [ "$cols" -ge 40 ] 2>/dev/null || cols=80
    title='cs · rewriting your prompt'
    label=$(_model_label)
    pad=$(( cols - 4 - ${#title} - ${#label} ))
    [ "$pad" -ge 1 ] || pad=1
    printf '\n  %s%s%s%*s%s%s%s\n  %s' \
        "$_b" "$title" "$_r" "$pad" '' "$_d" "$label" "$_r" "$_d" >&2
    awk -v n=$(( cols - 4 )) 'BEGIN{while (n-- > 0) printf "─"}' >&2
    printf '%s\n\n' "$_r" >&2
    # awk rather than `head -8`, which exits early and SIGPIPEs fold — under
    # `pipefail` that turns a long prompt into a 141 status. awk drains the
    # whole stream, and says so when it clipped rather than showing a fragment
    # that reads like the whole prompt.
    printf '%s' "$prompt" | fold -s -w $(( cols - 4 )) \
        | awk 'NR<=8 {print "  " $0} END {if (NR>8) print "  … prompt clipped"}' >&2
    printf '\n' >&2
}

# Spins until the rewriter exits. Elapsed comes from SECONDS rather than a
# frame count, so sleep drift never shows up as a wrong clock.
_render_until_done() {  # pid
    local pid="$1" i=0 budget=''
    # A fast CS_REWRITE_CMD should never flash a loader on screen.
    sleep 0.3
    kill -0 "$pid" 2>/dev/null || return 0
    [ -t 2 ] || return 0
    if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
        budget=" / ${CS_REWRITE_TIMEOUT:-25}s"
    fi
    _paint_screen
    SECONDS=0
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s  working…   %ss%s        %s^C keeps your original%s\033[K' \
            "${_spin[$(( i % 10 ))]}" "$SECONDS" "$budget" "$_d" "$_r" >&2
        i=$(( i + 1 ))
        sleep 0.1
    done
    printf '\r\033[K' >&2
}

# The rewriter reads the prompt on stdin and writes the rewrite to stdout.
# Overridable so the tests can exercise the plumbing without a model, and so a
# user can supply their own. It runs in the background rather than in a command
# substitution because a blocking substitution leaves nothing able to draw.
out="$target.cs-out"

# ctrl+c means "keep what I typed". Without this the signal is swallowed: bash
# defers it until the child returns, so the rewrite runs to completion and
# lands anyway. pkill -P first, because killing the subshell alone orphans the
# model call it is waiting on.
#
# Armed BEFORE the rewriter is forked, and tolerant of an empty _rw, so that a
# signal landing in the gap between fork and trap is caught rather than killing
# the shim outright. On a loaded machine that gap is wide enough to hit.
_rw=''
# shellcheck disable=SC2329  # invoked by the trap below, not by name
_keep_original() {
    if [ -n "$_rw" ]; then
        # The whole group, not just the forked process. The rewriter is a
        # script that starts the model call and waits on it, so killing only
        # what we forked leaves that call running, detached and still billed.
        kill -TERM "-$_rw" 2>/dev/null || kill -TERM "$_rw" 2>/dev/null
    fi
    rm -f "$out" "$target.cs-tmp" 2>/dev/null
    [ -t 2 ] && printf '\r\033[K' >&2
    exit 0
}
trap _keep_original INT TERM

# Job control for the fork alone, so the rewriter and everything it starts land
# in one process group that the trap above can address as a unit.
set -m
( printf '%s' "$prompt" | ${CS_REWRITE_CMD:-"$(dirname "$0")/prompt-rewriter-model.sh"} > "$out" 2>/dev/null ) &
_rw=$!
set +m

_render_until_done "$_rw"
wait "$_rw" || { rm -f "$out" 2>/dev/null; exit 0; }
rewritten=$(cat "$out" 2>/dev/null) || { rm -f "$out" 2>/dev/null; exit 0; }
rm -f "$out" 2>/dev/null

# An empty or whitespace-only rewrite means the rewriter failed in a way that
# did not set a status. Writing it would silently erase what the user typed.
[ -n "${rewritten//[[:space:]]/}" ] || exit 0

# tmp+rename so a crash mid-write cannot leave a truncated buffer.
printf '%s' "$rewritten" > "$target.cs-tmp" 2>/dev/null || exit 0
mv "$target.cs-tmp" "$target" 2>/dev/null || rm -f "$target.cs-tmp" 2>/dev/null
exit 0
