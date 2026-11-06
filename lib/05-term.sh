# ABOUTME: Terminal helpers: color palette, OSC/tab-title escapes, session-color RGB.
# ABOUTME: Also the error/info/warn output primitives used across cs.

_claude_encode_path() {
    local p="$1"
    p="${p//[^A-Za-z0-9]/-}"
    printf '%s' "$p"
}

CS_RELEASE_SIGNERS='release namespaces="cs-release-*" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFMX5MLo9e2hYyqNVkQzfxbFcIk4/UL9Atz01BsbfGZ8'
# Revoked release keys, one per line. cs -update reads this declaration out
# of a downloaded installer as data: exactly one declaration, single-quoted.
CS_RELEASE_REVOKED=''

# Colors - Claude warm palette (rust → orange → gold). Theme-aware: the dark
# values assume a dark canvas; on a light terminal the muted tones (comment,
# white, dim) would wash out, so light gets darker ink mirroring the TUI palette.
# Re-run setup_palette after CS_TERM_THEME is detected so banners pick up light.
setup_palette() {
    if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
        RED=''; GREEN=''; YELLOW=''; ORANGE=''; GOLD=''; RUST=''
        COMMENT=''; WHITE=''; DIM=''; BOLD=''; NC=''
        AMBER=''; CRIT=''; CRIT_FILL=''
        return
    fi
    BOLD='\033[1m'
    NC='\033[0m'
    if [ "${CS_TERM_THEME:-dark}" = "light" ]; then
        RED='\033[38;2;188;74;66m'        # muted red on paper
        GREEN='\033[38;2;92;140;84m'      # muted green
        YELLOW='\033[38;2;162;122;58m'    # muted amber
        ORANGE='\033[38;2;190;110;74m'    # muted coral
        GOLD='\033[38;2;156;118;56m'      # muted gold
        RUST='\033[38;2;166;86;60m'       # muted terracotta
        COMMENT='\033[38;2;128;116;106m'  # readable taupe on cream
        WHITE='\033[38;2;48;42;36m'       # dark ink (primary text)
        DIM='\033[38;2;120;108;98m'       # darker grey instead of fade-to-bg
    else
        RED='\033[38;2;239;83;80m'        # #ef5350 - warm red
        GREEN='\033[38;2;139;195;74m'     # #8bc34a - vibrant green
        YELLOW='\033[38;2;255;183;77m'    # #ffb74d - warm amber
        ORANGE='\033[38;2;255;138;101m'   # #ff8a65 - coral orange
        GOLD='\033[38;2;255;193;7m'       # #ffc107 - golden
        RUST='\033[38;2;230;74;25m'       # #e64a19 - terracotta
        COMMENT='\033[38;2;161;136;127m'  # #a1887f - warm taupe
        WHITE='\033[38;2;245;230;211m'    # #f5e6d3 - warm cream
        DIM='\033[2m'
    fi
    # The status line's context inks, so the launch card and the resume ask
    # warn in the colours the bar uses: amber, the crit red, and the bar's
    # inverted crit capsule, white on the crit red on either theme. KEEP IN
    # SYNC with the amber), crit) and critink) arms of _sgr in
    # bin/cs-statusline. The bar's amber also follows a measured background;
    # these follow CS_TERM_THEME, like the rest of this palette.
    # shellcheck disable=SC2034  # read by the launch card and the resume ask (lib/75-launch.sh)
    if [ "${CS_TERM_THEME:-dark}" = "light" ]; then
        AMBER='\033[38;2;180;83;9m'
        CRIT='\033[38;2;215;0;21m'
        CRIT_FILL='\033[48;2;215;0;21;38;2;255;255;255m'
    else
        AMBER='\033[38;2;251;191;36m'
        CRIT='\033[38;2;255;69;58m'
        CRIT_FILL='\033[48;2;255;69;58;38;2;255;255;255m'
    fi
}
setup_palette

# Icons - Nerd Font with Unicode fallback
# cs needs a UTF-8 locale. Under an EUC one (ja_JP.eucJP, ko_KR.eucKR,
# zh_CN.eucCN) bash reads the last byte of a glyph that sits directly before a
# quote as the lead byte of a two-byte character and takes the quote with it,
# so these lines, and a few like them elsewhere in cs and its hooks, stop the
# parse with a syntax error. Left as is (Alex 2026-10-11): the output is UTF-8
# in any case, and the README names the requirement. Do not escape the glyphs
# or add a locale check for this.
if [[ "${CS_NERD_FONTS:-}" == "1" ]]; then
    ICON_LOCK='󰌾'      # mdi-lock
    ICON_HOST='󰟀'      # mdi-monitor
    ICON_CTX='󰍛'       # mdi-memory
    ICON_UP='󰚰'        # mdi-update
else
    ICON_LOCK='⚿'      # Unicode lock with key
    ICON_HOST='⌘'      # Unicode command/place of interest
    ICON_CTX='◱'       # Unicode box with quadrant — a partly-filled window
    ICON_UP='↑'        # Unicode upwards arrow
fi
ICON_LOGO='✳'          # U+2733 eight-spoked asterisk (Claude mark); font-independent

# Utility functions
# The message travels through %s, never through the format string. `echo -e`
# consumed escapes in whatever was interpolated: a message carrying \c (common
# in an uncompilable regex the user just typed) truncated itself and swallowed
# its own newline, and \t became a literal tab. The colour variables stay in the
# format, which is where their \033 sequences are meant to be read.
# The message is also kept in _CS_ERROR_MESSAGE, for an EXIT handler that
# records why the run ended (the /finish progress record's refusal reason).
error() {
    # shellcheck disable=SC2034  # read by _finish_progress_exit in lib/30-worktree.sh
    _CS_ERROR_MESSAGE="$1"
    printf "${RED}Error: %s${NC}\n" "$1" >&2
    exit 1
}

info() {
    _CS_NOTICE_HEADED=""
    printf "${GREEN}%s${NC}\n" "$1"
}

# A row naming a file cs changed for the user: the file in a column, then the
# change, and under it, when given, what the user must do about it. The first
# row of a run prints the header the rows sit under; an info or warn line
# between rows ends the block, so the next row prints the header again. Each
# row prints as it is made, so an exit part way keeps every row for a write
# that happened. Whether the header is out lives in this shell, and a row from
# a subshell would print it again, so a subshell call is refused.
notice() {  # file, change, [action]
    [ "$BASH_SUBSHELL" -eq 0 ] || error "notice for $1 called in a subshell, which would repeat the header"
    if [ -z "${_CS_NOTICE_HEADED:-}" ]; then
        printf "${RUST}%s${NC} ${BOLD}%s${NC}\n" "$ICON_LOGO" "cs updated these files"
        _CS_NOTICE_HEADED=1
    fi
    printf "  ${DIM}%-15s${NC}  %s\n" "$1" "$2"
    [ -z "${3:-}" ] || printf "  %-15s  ${ORANGE}→ %s${NC}\n" "" "$3"
}

# Strip leading and trailing whitespace from a string; prints the result.
_trim() {  # text
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Map a claude_session_color name to its RGB (comma form, for the session pill).
# These are Claude Code's own /color palette (the shared dark/light theme
# `*_FOR_SUBAGENTS_ONLY` tokens): the pill and Claude Code's own session
# accent share the statusline's eight-color palette. KEEP IN SYNC with the
# session palette in _sgr (bin/cs-statusline).
_session_color_rgb() {
    case "$1" in
        red)    echo "220,38,38" ;;
        blue)   echo "106,155,204" ;;
        green)  echo "22,163,74" ;;
        yellow) echo "202,138,4" ;;
        purple) echo "130,125,189" ;;
        orange) echo "217,119,87" ;;
        pink)   echo "196,102,134" ;;
        cyan)   echo "8,145,178" ;;
        *)      echo "" ;;
    esac
}

# Render a session-color pill: the Claude mark on Claude-coral, then the session
# name on its /color background, matching the statusline's logo + session
# segments. Falls back to the bold name when colors are off or the color name is
# unknown. Truecolor bg is safe here: cs already emits 24-bit fg escapes when
# colors are enabled.
_session_pill() {
    local name="$1" color="$2" rgb
    rgb=$(_session_color_rgb "$color")
    if [ -z "$NC" ] || [ -z "$rgb" ]; then
        printf '%b%s%b' "${BOLD}${WHITE}" "$name" "$NC"
        return
    fi
    rgb="${rgb//,/;}"   # comma form -> semicolon for SGR
    # The pill owns its two colors: Claude-coral (217;119;87) and 240;242;255,
    # which reads on both the coral and the session-color bg.
    # KEEP IN SYNC with the session palette in _sgr (bin/cs-statusline).
    printf '\033[48;2;217;119;87;38;2;240;242;255m %s \033[48;2;%s;38;2;240;242;255m %s \033[0m' \
        "$ICON_LOGO" "$rgb" "$name"
}

# Set terminal tab title.
# Uses standard xterm escape sequences (works in iTerm2, Terminal.app, Ghostty, Alacritty, WezTerm, etc.)
# Also sets tmux window name when running inside tmux.
set_tab_title() {
    # Skip when stdout is not a TTY (tests, piped output) — otherwise the OSC 0
    # escape sequence still reaches the parent terminal but cs's `exec` into claude
    # bypasses the EXIT trap that would normally call reset_tab_title, leaving the
    # title stuck (e.g., "cs: test-session" after running the test suite).
    [ -t 1 ] || return 0

    local title="$1"
    local session="${2:-}"  # optional: the cs session, to share a tmux window's name with its other panes

    # Standard xterm OSC 0: set window and tab title (also sets tmux pane title)
    printf '\033]0;%s\007' "$title"

    # tmux: set window name and pane title, then lock both so Claude Code can't overwrite
    if [ -n "${TMUX:-}" ]; then
        if [ -n "$session" ] && [ -n "${TMUX_PANE:-}" ]; then
            cs_tmux_title_window "$TMUX_PANE" "$session"
        else
            tmux rename-window "$title" 2>/dev/null || true
        fi
        # Aimed at this pane: untargeted, tmux picks the attached client's
        # active pane, which need not be the one cs runs in.
        tmux select-pane ${TMUX_PANE:+-t "$TMUX_PANE"} -T "$title" 2>/dev/null || true
        tmux set-window-option ${TMUX_PANE:+-t "$TMUX_PANE"} allow-rename off 2>/dev/null || true
        tmux set-window-option ${TMUX_PANE:+-t "$TMUX_PANE"} allow-set-title off 2>/dev/null || true
    fi

}

# Reset terminal tab title to its default
reset_tab_title() {
    # Symmetric with set_tab_title: skip when not on a TTY
    [ -t 1 ] || return 0

    # Reset title (empty = let shell/prompt set its own)
    printf '\033]0;\007'

    # tmux: release the pane this launch claimed. The window stays named, and
    # locked, after any cs session still running in its other panes, and names
    # itself again once none is left. Without a pane to release, the window's
    # own naming comes back as before.
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
        cs_tmux_title_window "$TMUX_PANE" ""
    elif [ -n "${TMUX:-}" ]; then
        tmux set-window-option automatic-rename on 2>/dev/null || true
        tmux set-window-option allow-rename on 2>/dev/null || true
        tmux set-window-option allow-set-title on 2>/dev/null || true
    fi

}

