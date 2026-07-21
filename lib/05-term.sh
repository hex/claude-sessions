# ABOUTME: Terminal helpers: color palette, OSC/tab-title escapes, session-color RGB.
# ABOUTME: Also the error/info/warn output primitives used across cs.

_claude_encode_path() {
    local p="$1"
    p="${p//\//-}"
    p="${p//./-}"
    printf '%s' "$p"
}

# Minisign public key for verifying signed releases
CS_SIGN_PUBKEY="RWQvs3IVdvrS8PJs0V0gwdJGPw/x5waQ6z6iqPQm90JfpxfcsSy9b9Vo"
# Colors - Claude warm palette (rust → orange → gold). Theme-aware: the dark
# values assume a dark canvas; on a light terminal the muted tones (comment,
# white, dim) would wash out, so light gets darker ink mirroring the TUI palette.
# Re-run setup_palette after CS_TERM_THEME is detected so banners pick up light.
setup_palette() {
    if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
        RED=''; GREEN=''; YELLOW=''; ORANGE=''; GOLD=''; RUST=''
        COMMENT=''; WHITE=''; DIM=''; BOLD=''; NC=''
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
}
setup_palette

# Icons - Nerd Font with Unicode fallback
if [[ "${CS_NERD_FONTS:-}" == "1" ]]; then
    ICON_LOCK='󰌾'      # mdi-lock
    ICON_HOST='󰟀'      # mdi-monitor
else
    ICON_LOCK='⚿'      # Unicode lock with key
    ICON_HOST='⌘'      # Unicode command/place of interest
fi
ICON_LOGO='✳'          # U+2733 eight-spoked asterisk (Claude mark); font-independent

# Utility functions
error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}$1${NC}"
}

# Strip leading and trailing whitespace from a string; prints the result.
_trim() {  # text
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Detect the outer terminal, even when running inside tmux.
# tmux overrides TERM_PROGRAM, so we check LC_TERMINAL and ITERM_SESSION_ID as fallbacks.
_detect_terminal() {
    local term="${TERM_PROGRAM:-}"
    if [ "$term" = "tmux" ] || [ -n "${TMUX:-}" ]; then
        # Inside tmux: check env vars that survive from the outer terminal
        if [ "${LC_TERMINAL:-}" = "iTerm2" ] || [ -n "${ITERM_SESSION_ID:-}" ]; then
            echo "iTerm.app"
        elif [ "${LC_TERMINAL:-}" = "WezTerm" ]; then
            echo "WezTerm"
        else
            echo "tmux"
        fi
    else
        echo "$term"
    fi
}

# Send an escape sequence, using tmux DCS passthrough when inside tmux.
# tmux intercepts proprietary escape sequences (like iTerm2 tab color) unless
# wrapped in: ESC P tmux ; ESC ESC <payload> ESC backslash
# (ESC must be doubled inside the DCS payload per tmux protocol)
_send_escape() {
    if [ -n "${TMUX:-}" ]; then
        printf '\033Ptmux;\033\033%b\033\\' "$1"
    else
        printf '\033%b' "$1"
    fi
}

# Pick a tab color deterministically from a string (e.g., session name).
# Same name always produces the same color for visual consistency across launches.
_color_from_name() {
    local name="$1"
    local colors=(
        "255,82,82"     # red
        "255,152,0"     # orange
        "255,193,7"     # amber
        "198,255,0"     # chartreuse
        "76,175,80"     # green
        "0,150,136"     # teal
        "0,188,212"     # cyan
        "3,169,244"     # sky blue
        "92,107,192"    # indigo
        "149,117,205"   # purple
        "236,64,122"    # pink
        "255,138,101"   # coral
    )
    local hash
    hash=$(printf '%s' "$name" | shasum | cut -d' ' -f1)
    local index=$(( 16#${hash:0:8} % ${#colors[@]} ))
    echo "${colors[$index]}"
}

# Map a claude_session_color name to its RGB (comma form for set_tab_title), so
# the terminal tab color matches the statusline session block exactly.
# These are Claude Code's own /color palette (the shared dark/light theme
# `*_FOR_SUBAGENTS_ONLY` tokens) so the tab, the session pill, and Claude Code's
# own session accent all agree. KEEP IN SYNC with cs-statusline's truecolor
# session palette.
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
    # Claude-coral (217;119;87) and chiptext (240;242;255) match cs-statusline's
    # brand/chiptext SGR; chiptext reads on both the coral and session-color bg.
    # KEEP IN SYNC with cs-statusline's _seg_logo/_seg_session colors.
    printf '\033[48;2;217;119;87;38;2;240;242;255m %s \033[48;2;%s;38;2;240;242;255m %s \033[0m' \
        "$ICON_LOGO" "$rgb" "$name"
}

# Set terminal tab title and optional tab color.
# Uses standard xterm escape sequences (works in iTerm2, Terminal.app, Ghostty, Alacritty, WezTerm, etc.)
# Also sets tmux window name when running inside tmux.
set_tab_title() {
    # Skip when stdout is not a TTY (tests, piped output) — otherwise the OSC 0
    # escape sequence still reaches the parent terminal but cs's `exec` into claude
    # bypasses the EXIT trap that would normally call reset_tab_title, leaving the
    # title stuck (e.g., "cs: test-session" after running the test suite).
    [ -t 1 ] || return 0

    local title="$1"
    local color="${2:-}"  # optional: "blue", r,g,b values, or "auto:name" to hash from name
    local outer_term
    outer_term=$(_detect_terminal)

    # Standard xterm OSC 0: set window and tab title (also sets tmux pane title)
    printf '\033]0;%s\007' "$title"

    # Git Bash has no tmux, and neither iTerm2 nor WezTerm run as the outer
    # terminal there; the plain title above is all msys gets.
    [ "$(cs_platform)" = "msys" ] && return 0

    # tmux: set window name and pane title, then lock both so Claude Code can't overwrite
    if [ -n "${TMUX:-}" ]; then
        tmux rename-window "$title" 2>/dev/null || true
        tmux select-pane -T "$title" 2>/dev/null || true
        tmux set-window-option allow-rename off 2>/dev/null || true
        tmux set-window-option allow-set-title off 2>/dev/null || true
    fi

    # Tab color via iTerm2 escape sequences (also supported by WezTerm)
    if [ -n "$color" ]; then
        case "$outer_term" in
            iTerm.app|WezTerm)
                local r g b
                case "$color" in
                    auto:*)
                        # Derive color from name hash
                        IFS=',' read -r r g b <<< "$(_color_from_name "${color#auto:}")"
                        ;;
                    blue) r=66  g=133 b=244 ;;
                    *)
                        # Accept r,g,b format
                        IFS=',' read -r r g b <<< "$color"
                        ;;
                esac
                if [ -n "${r:-}" ] && [ -n "${g:-}" ] && [ -n "${b:-}" ]; then
                    _send_escape "]6;1;bg;red;brightness;${r}\a"
                    _send_escape "]6;1;bg;green;brightness;${g}\a"
                    _send_escape "]6;1;bg;blue;brightness;${b}\a"
                fi
                ;;
        esac
    fi
}

# Reset terminal tab title and color to defaults
reset_tab_title() {
    # Symmetric with set_tab_title: skip when not on a TTY
    [ -t 1 ] || return 0

    # Reset title (empty = let shell/prompt set its own)
    printf '\033]0;\007'

    # tmux: re-enable automatic window/title naming
    if [ -n "${TMUX:-}" ]; then
        tmux set-window-option automatic-rename on 2>/dev/null || true
        tmux set-window-option allow-rename on 2>/dev/null || true
        tmux set-window-option allow-set-title on 2>/dev/null || true
    fi

    # Reset tab color (iTerm2/WezTerm)
    local outer_term
    outer_term=$(_detect_terminal)
    case "$outer_term" in
        iTerm.app|WezTerm)
            _send_escape ']6;1;bg;*;default\a'
            ;;
    esac
}

