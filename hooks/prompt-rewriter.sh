#!/usr/bin/env bash
# ABOUTME: $EDITOR shim that rewrites the Claude Code composer buffer in place.
# ABOUTME: ctrl+g round-trips the composer through $EDITOR; this returns a precise prompt.

# No `set -e`: this shim stands between the user and their editor, and every
# error path must leave the buffer exactly as typed rather than lose their text.
set -uo pipefail

target="${1:-}"

# Every exit path leaves a line in a machine-local trace. This shim is invoked
# by a keypress and draws onto a screen that is torn down, so when it does
# nothing there is otherwise no evidence at all of WHICH of its several
# passthrough paths it took — the buffer looks identical for "not a composer
# file", "disabled", "slash command" and "rewriter declined".
_trace() {  # stage
    local dir="${CLAUDE_SESSION_META_DIR:-}"
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    mkdir -p "$dir/local" 2>/dev/null || return 0
    printf '%s %s %s\n' "$$" "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" \
        >> "$dir/local/rewrite.trace" 2>/dev/null || true
}

_trace "start ${CS_REWRITE_PROVIDER:-claude} $(basename "${target:-<none>}")"
[ -n "$target" ] || { _trace 'exit no-target'; exit 0; }

# Claude Code writes the composer buffer to <tmpdir>/claude-prompt-<uuid>.md,
# spawns $EDITOR on it, and replaces the composer with whatever it reads back.
# Every OTHER file handed to us is a genuine edit request — /memory, an opened
# transcript, a git commit message — and belongs to the user's real editor.
case "$(basename "$target")" in
    claude-prompt-*.md) ;;
    *)
        # shellcheck disable=SC2086  # deliberate: an editor may carry flags ("code -w")
        _trace 'exit real-editor'
        exec ${CS_REAL_EDITOR:-vi} "$target"
        ;;
esac

# Separate from CS_CLARIFY_DISABLE on purpose: silencing the clarifying
# questions should not also silence the rewriter, and vice versa.
[ "${CS_REWRITE_DISABLE:-}" = "1" ] && { _trace 'exit disabled'; exit 0; }

prompt=$(cat "$target" 2>/dev/null) || exit 0

# Strip leading whitespace for the classification only; the rewriter still
# receives the buffer as typed.
lead=${prompt#"${prompt%%[![:space:]]*}"}

case "$lead" in
    # Nothing to rewrite, and a slash command, shell passthrough or memory entry
    # is already precise — rewriting one would corrupt it into prose.
    ''|/*|'!'*|'#'*) _trace 'exit passthrough-prefix'; exit 0 ;;
esac

# The composer buffer holds PLACEHOLDERS for pasted text and images, not their
# bodies. Rewriting the placeholder away silently destroys the attachment, so a
# buffer carrying one is passed through untouched.
case "$prompt" in
    *'[Pasted text'*|*'[Image'*) _trace 'exit passthrough-placeholder'; exit 0 ;;
esac

# Claude Code spawns this shim with stdio inherited onto a BLANK alternate
# screen and blocks until it exits, so the terminal belongs to us for the whole
# rewrite and everything drawn here is torn down with that screen — nothing
# reaches the scrollback. All of it is gated on a tty, so a piped run draws
# nothing at all.
_spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
# The cs palette, mirroring lib/05-term.sh. A deployed hook cannot source that
# file, so the values are inlined here and keyed on CS_TERM_THEME, which cs
# exports after detecting the terminal background. Light is not dark dimmed: on
# cream the muted tones wash out, so light gets darker ink instead.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _b=$'\033[1m'; _r=$'\033[0m'
    # The raw triples ride alongside the escapes: the margin rule breathes by
    # interpolating between muted and accent, and a two-colour blink would read
    # as an alert rather than a breath.
    if [ "${CS_TERM_THEME:-dark}" = "light" ]; then
        _accent_rgb='166 86 60'          # terracotta
        _ink=$'\033[38;2;48;42;36m'       # primary text
        _mute_rgb='128 116 106'          # taupe
        _d=$'\033[38;2;120;108;98m'
    else
        _accent_rgb='230 74 25'
        _ink=$'\033[38;2;245;230;211m'
        _mute_rgb='161 136 127'
        _d=$'\033[2m'
    fi
    # A function, so splitting the triple happens in ITS positionals. `set --`
    # here would overwrite the script's own, and $1 is the composer file.
    _esc_rgb() { printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"; }
    # shellcheck disable=SC2086  # deliberate: each triple is three fields
    _accent=$(_esc_rgb $_accent_rgb)
    # shellcheck disable=SC2086
    _mute=$(_esc_rgb $_mute_rgb)
else
    _b=''; _d=''; _r=''; _accent=''; _ink=''; _mute=''
    _accent_rgb=''; _mute_rgb=''
fi

# Terminal geometry, with a plausible fallback rather than a failure: this is
# decoration, and no arithmetic here may cost the user their prompt.
_geometry() {  # lines|cols -> a count
    local n
    n=$(tput "$1" 2>/dev/null) || n=0
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -lt 10 ]; then
        [ "$1" = lines ] && n=24 || n=80
    fi
    printf '%s' "$n"
}

# claude-haiku-4-5-20251001 -> haiku 4.5
#
# A vendor provider names the engine that answers and the model it runs, and
# both come from the vendor rewriter's own `--label`. Repeating the CLI-or-API
# test here would be a second copy of it, free to drift into a header that says
# `api` while `agy` is answering. The provider name is the fallback, so a label
# that cannot be resolved costs the user a detail rather than the whole header.
_model_label() {
    local vendor
    case "${CS_REWRITE_PROVIDER:-}" in
        openai|gemini|openai-api|gemini-api|claude-api)
            vendor=$("$(dirname "$0")/prompt-rewriter-vendor.sh" --label </dev/null 2>/dev/null)
            printf '%s' "${vendor:-$CS_REWRITE_PROVIDER}"
            return ;;
    esac
    printf '%s' "${CS_REWRITE_MODEL:-claude-haiku-4-5-20251001}" \
        | sed -e 's/^claude-//' -e 's/-[0-9]\{8\}$//' \
              -e 's/\([0-9]\)-\([0-9]\)/\1.\2/g' -e 's/-/ /g'
}

# The margin rule that holds the prompt, breathing between muted and accent.
# Two endpoints interpolated over a slow triangle wave: a hard blink between
# them would read as an alert, and this screen is a held breath, not a warning.
# Falls back to the plain accent where truecolor is off, so NO_COLOR and a dumb
# terminal still get a rule rather than nothing.
_margin_color() {  # step
    local t r g b
    [ -n "$_accent_rgb" ] || { printf '%s' "$_accent"; return; }
    # 0..23 up, 24..47 down — about 4.8s a cycle at the 100ms tick, which is
    # roughly a resting breath and slow enough not to pull the eye.
    t=$(( $1 % 48 ))
    [ "$t" -ge 24 ] && t=$(( 48 - t ))
    # shellcheck disable=SC2086  # deliberate: each triple is three fields
    set -- $_mute_rgb
    local m1=$1 m2=$2 m3=$3
    # shellcheck disable=SC2086
    set -- $_accent_rgb
    r=$(( m1 + ($1 - m1) * t / 24 ))
    g=$(( m2 + ($2 - m2) * t / 24 ))
    b=$(( m3 + ($3 - m3) * t / 24 ))
    printf '\033[38;2;%s;%s;%sm' "$r" "$g" "$b"
}

# Repeats a character. awk rather than a bash loop: printf'ing per cell at ten
# frames a second is visible work for no reason.
_repeat() {  # char, count
    [ "$2" -gt 0 ] || return 0
    awk -v c="$1" -v n="$2" 'BEGIN{while (n-- > 0) printf "%s", c}'
}

# The whole screen, redrawn from cursor-home each tick. A full repaint rather
# than a patched last line because the margin runs the height of the block, and
# `\033[K` per line means no clear-screen and so no flicker. We own the
# alternate screen, so home is ours to take.
_paint_frame() {  # step, remaining-seconds
    local step="$1" left="$2" cols line indent label bar_w filled
    cols=$(_geometry cols)
    local rule; rule="$(_margin_color "$step")▏$_r"

    printf '\033[H' >&2
    printf '\033[K\n' >&2
    # The prompt is the subject of this screen, so it leads — folded to the
    # margin, capped at eight lines, and told when it was cut rather than shown
    # a fragment that reads like the whole thing.
    # `%s\n`, not `%s`: command substitution strips the trailing newline, and a
    # `read` loop discards a final unterminated line — which for a one-line
    # prompt is the whole prompt.
    printf '%s\n' "$_prompt_block" | while IFS= read -r line; do
        printf '  %s  %s%s%s\033[K\n' "$rule" "$_ink" "$line" "$_r" >&2
    done
    printf '  %s\033[K\n' "$rule" >&2

    # Chrome: what is happening, and which engine has the words. Both muted —
    # neither is the subject.
    label=$(_model_label)
    indent=$(( cols - 4 - 9 - ${#label} ))
    [ "$indent" -ge 1 ] || indent=1
    printf '  %s  %srewriting%*s%s%s\033[K\n' "$rule" "$_d" "$indent" '' "$label" "$_r" >&2

    # Remaining, not elapsed. Nothing here can be cancelled, so the elapsed
    # count is a number the reader cannot act on; what is left against the
    # budget is the one fact that answers "should I wait".
    if [ -n "$_budget" ]; then
        bar_w=$(( cols - 4 - 12 ))
        [ "$bar_w" -ge 8 ] || bar_w=8
        filled=$(( bar_w * left / _budget ))
        [ "$filled" -ge 0 ] || filled=0
        [ "$filled" -le "$bar_w" ] || filled=$bar_w
        printf '  %s  %s%s%s%s%s  %ss left%s\033[K\n' "$rule" \
            "$_accent" "$(_repeat '━' "$filled")" "$_d" \
            "$(_repeat '━' $(( bar_w - filled )))" "$_r" "$left" "$_r" >&2
    else
        printf '  %s  %s%ss%s\033[K\n' "$rule" "$_d" "$SECONDS" "$_r" >&2
    fi
    printf '\033[K' >&2
}

# Drops the cursor to the vertical middle for the modes that show one line on
# an otherwise empty screen.
_center_vertically() {
    local blanks
    blanks=$(( $(_geometry lines) / 2 - 1 ))
    [ "$blanks" -ge 0 ] || blanks=0
    awk -v n="$blanks" 'BEGIN{while (n-- > 0) printf "\n"}' >&2
}

# Horizontal offset that puts a line of roughly `width` in the middle.
_center_indent() {  # width
    local indent
    indent=$(( ($(_geometry cols) - $1) / 2 ))
    [ "$indent" -ge 0 ] || indent=0
    printf '%s' "$indent"
}

# Spins until the rewriter exits. Elapsed comes from SECONDS rather than a
# frame count, so sleep drift never shows up as a wrong clock.
_render_until_done() {  # pid
    local pid="$1" i=0 budget='' indent shown='' text
    # Paint on every arm, including the ~1s API ones. A threshold high enough to
    # skip them entirely means ctrl+g acknowledges nothing at all until the
    # buffer silently changes, and the user cannot tell their keypress
    # registered — worse than the brief showing it was meant to avoid. The flash
    # No delay before painting. The rewriter is already forked and running, so
    # drawing costs the user no wall time at all — and any wait here only means
    # LESS screen, never a faster rewrite. The screen appears the instant the
    # key is pressed, which is the acknowledgement ctrl+g owes the user.
    #
    # The one case this gives up is a rewriter that fails almost immediately —
    # a missing binary, a rejected key at ~350ms — which now paints briefly
    # before it declines. That is a fair trade for every successful rewrite
    # acknowledging itself at once.
    kill -0 "$pid" 2>/dev/null || return 0
    [ -t 2 ] || return 0
    if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
        budget=" / ${CS_REWRITE_TIMEOUT:-25}s"
    fi
    # A countdown may only be shown when something actually enforces it. The
    # vendor rewriter bounds itself with perl's alarm, which is always there;
    # the default rewriter needs timeout(1), which stock macOS does not ship.
    _budget=''
    case "${CS_REWRITE_PROVIDER:-}" in
        openai|gemini|openai-api|gemini-api|claude-api)
            command -v perl >/dev/null 2>&1 && _budget="${CS_REWRITE_TIMEOUT:-25}" ;;
        *) [ -n "$budget" ] && _budget="${CS_REWRITE_TIMEOUT:-25}" ;;
    esac

    # Hidden for the whole display, restored below and in the trap. A cursor
    # parked at the end of the line reads as unfinished output.
    printf '\033[?25l' >&2

    # No interrupt is offered in any mode. The terminal delivers SIGINT to the
    # whole foreground process group, Claude Code included, so ctrl+c here ends
    # the session rather than the rewrite — nothing a spawned shim does can
    # change that. The timeout is the only bound, which is why it is on screen.
    # An unrecognised value lands on the default arm rather than drawing
    # nothing: a typo in a shell profile must not silently restore the blank
    # screen this exists to remove.
    case "${CS_REWRITE_PROGRESS:-screen}" in
        static)
            # No animation and no repaint: one line, then wait. Nothing on
            # screen distinguishes a working rewrite from a wedged one, which
            # is the whole cost of the mode.
            _center_vertically
            indent=$(_center_indent 40)
            printf '%*s%sRewriting your prompt…  up to %ss%s\n' \
                "$indent" '' "$_d" "${CS_REWRITE_TIMEOUT:-25}" "$_r" >&2
            while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
            ;;
        native)
            # Claude Code's own idiom: a sentence-case gerund, and the elapsed
            # only once it has run long enough to be worth reading
            # (`m = f >= 5 ? ${d} (${f}s) : d`). A counter ticking 1s, 2s on a
            # rewrite that always takes about ten is noise it leaves out.
            # Anchored where the composer was rather than centred: one short
            # line in the middle of an empty screen advertises the emptiness.
            printf '\n' >&2
            SECONDS=0
            while kill -0 "$pid" 2>/dev/null; do
                if [ "$SECONDS" -ge 5 ]; then
                    text="Rewriting your prompt… (${SECONDS}s)"
                else
                    text='Rewriting your prompt…'
                fi
                # Repaint only on change, as Claude Code does; without a
                # spinner there is nothing to animate between ticks.
                if [ "$text" != "$shown" ]; then
                    printf '\r  %s%s%s\033[K' "$_d" "$text" "$_r" >&2
                    shown="$text"
                fi
                sleep 0.25
            done
            ;;
        line)
            _center_vertically
            # 34 is the settled width at two-digit seconds. A column out on a
            # short count is invisible; recomputing per frame would make the
            # line jitter as the seconds roll over.
            indent=$(_center_indent 34)
            SECONDS=0
            while kill -0 "$pid" 2>/dev/null; do
                printf '\r%*s%s%s  Rewriting your prompt…  %ss%s%s\033[K' \
                    "$indent" '' "$_d" "${_spin[$(( i % 10 ))]}" "$SECONDS" "$budget" "$_r" >&2
                i=$(( i + 1 ))
                sleep 0.1
            done
            ;;
        *)
            # Folded once, not per frame: the text does not change and re-running
            # fold and awk ten times a second would be work for nothing. awk
            # rather than `head -8`, which exits early and SIGPIPEs fold — under
            # `pipefail` that turns a long prompt into a 141 status.
            _prompt_block=$(printf '%s' "$prompt" | fold -s -w $(( $(_geometry cols) - 7 )) \
                | awk 'NR<=8 {print} END {if (NR>8) print "… prompt clipped"}')
            SECONDS=0
            while kill -0 "$pid" 2>/dev/null; do
                if [ -n "$_budget" ]; then
                    text=$(( _budget - SECONDS ))
                    [ "$text" -ge 0 ] || text=0
                else
                    text=$SECONDS
                fi
                _paint_frame "$i" "$text"
                i=$(( i + 1 ))
                sleep 0.1
            done
            ;;
    esac

    printf '\r\033[K\033[?25h' >&2
}

# The rewriter reads the prompt on stdin and writes the rewrite to stdout.
# Overridable so the tests can exercise the plumbing without a model, and so a
# user can supply their own. It runs in the background rather than in a command
# substitution because a blocking substitution leaves nothing able to draw.
out="$target.cs-out"

# Which shipped rewriter runs. CS_REWRITE_CMD is the older and wider contract —
# any executable at all — so a user who set it has already said what they want
# run, and the provider knob must not second-guess it. An unrecognised provider
# lands on the default rather than failing: a typo in a shell profile should cost
# the user their choice of model, never their prompt.
# The `-api` names reach a vendor's API past an installed CLI. Bare `claude` is
# absent on purpose: it IS the default rewriter, and only `claude-api` routes
# elsewhere.
case "${CS_REWRITE_PROVIDER:-}" in
    openai|gemini|openai-api|gemini-api|claude-api)
        _rewriter="$(dirname "$0")/prompt-rewriter-vendor.sh" ;;
    *)  _rewriter="$(dirname "$0")/prompt-rewriter-model.sh" ;;
esac

# This reaps; it does not cancel. ctrl+c cannot reach the shim alone — the
# terminal sends it to the whole foreground process group, Claude Code with it,
# so the session ends either way. What the handler prevents is the wreckage: a
# shim dying alongside its session would leave the model call it started running
# detached and billed. Signalling the group takes the call down with it.
#
# Armed BEFORE the rewriter is forked, and tolerant of an empty _rw, so a signal
# landing in the gap between fork and trap is handled rather than killing the
# shim outright. On a loaded machine that gap is wide enough to hit.
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
    [ -t 2 ] && printf '\r\033[K\033[?25h' >&2
    exit 0
}
trap _keep_original INT TERM

# Job control for the fork alone, so the rewriter and everything it starts land
# in one process group that the trap above can address as a unit.
set -m
( printf '%s' "$prompt" | ${CS_REWRITE_CMD:-"$_rewriter"} > "$out" 2>/dev/null ) &
_rw=$!
set +m

_trace 'rewriter-forked'
_render_until_done "$_rw"
wait "$_rw" || { _trace 'exit rewriter-failed'; rm -f "$out" 2>/dev/null; exit 0; }
rewritten=$(cat "$out" 2>/dev/null) || { rm -f "$out" 2>/dev/null; exit 0; }
rm -f "$out" 2>/dev/null

# An empty or whitespace-only rewrite means the rewriter failed in a way that
# did not set a status. Writing it would silently erase what the user typed.
[ -n "${rewritten//[[:space:]]/}" ] || { _trace 'exit empty-rewrite'; exit 0; }

# tmp+rename so a crash mid-write cannot leave a truncated buffer.
printf '%s' "$rewritten" > "$target.cs-tmp" 2>/dev/null || exit 0
mv "$target.cs-tmp" "$target" 2>/dev/null || rm -f "$target.cs-tmp" 2>/dev/null
_trace 'exit rewritten'
exit 0
