# ABOUTME: Status line enable/disable and terminal light/dark theme + background detection.
# ABOUTME: Backs 'cs -statusline' and 'cs -detect-theme'.

_strip_statusline_registration() {
    local settings_file="$1"
    [ -f "$settings_file" ] || return 1
    jq -e '.statusLine.command // "" | endswith("/cs-statusline")' "$settings_file" >/dev/null 2>&1 || return 1
    local _tmp
    _tmp=$(mktemp)
    if jq 'del(.statusLine)' "$settings_file" > "$_tmp" 2>/dev/null; then
        mv "$_tmp" "$settings_file"
        return 0
    fi
    rm -f "$_tmp"
    return 2
}

# endswith("/cs-subagent-statusline") never matches "/cs-statusline", so this
# stripper and _strip_statusline_registration cannot cross-fire on each other's
# registration. Returns 0 stripped, 1 foreign-or-absent, 2 write failure.
_strip_subagent_statusline_registration() {
    local settings_file="$1"
    [ -f "$settings_file" ] || return 1
    jq -e '.subagentStatusLine.command // "" | endswith("/cs-subagent-statusline")' \
        "$settings_file" >/dev/null 2>&1 || return 1
    local _tmp
    _tmp=$(mktemp)
    if jq 'del(.subagentStatusLine)' "$settings_file" > "$_tmp" 2>/dev/null; then
        mv "$_tmp" "$settings_file"
        return 0
    fi
    rm -f "$_tmp"
    return 2
}

# disable strips only a cs-statusline registration, never a foreign one.
run_statusline_cmd() {
    local action="${1:-}"
    local settings="${CS_CLAUDE_DIR:-$HOME/.claude}/settings.json"
    local bin="$HOME/.local/bin/cs-statusline"
    local subbin="$HOME/.local/bin/cs-subagent-statusline"
    command -v jq >/dev/null 2>&1 || error "jq is required for cs -statusline"
    case "$action" in
        enable)
            [ -x "$bin" ] || warn "cs-statusline binary not found at $bin (run install.sh first)"
            [ -x "$subbin" ] || warn "cs-subagent-statusline binary not found at $subbin (run install.sh first)"
            mkdir -p "$(dirname "$settings")"
            [ -f "$settings" ] || echo '{}' > "$settings"
            local _tmp
            _tmp=$(mktemp)
            # refreshInterval keeps the bar repainting once a second while
            # idle; the logo's attention pulse animates on that timer.
            if jq --arg cmd "$bin" --arg subcmd "$subbin" \
                '.statusLine = {type: "command", command: $cmd, refreshInterval: 1}
                 | .subagentStatusLine = {type: "command", command: $subcmd}' \
                "$settings" > "$_tmp" 2>/dev/null; then
                mv "$_tmp" "$settings"
                info "Registered cs-statusline as the Claude Code status line"
                info "Registered cs-subagent-statusline for the agent panel rows"
                info "Claude Code reads both at startup: restart it to see them."
            else
                rm -f "$_tmp"
                error "Could not update $settings"
            fi
            ;;
        disable)
            [ -f "$settings" ] || { info "No settings.json; nothing to disable."; return 0; }
            # Capture each stripper's exit code with `|| rc=$?`: a bare call
            # returning non-zero (foreign or absent registration) would trip
            # `set -e` before the following case ran, aborting the second strip.
            local slrc=0 subrc=0
            _strip_statusline_registration "$settings" || slrc=$?
            case $slrc in
                0) info "Removed the cs-statusline registration" ;;
                1) info "Status line is not cs-statusline; leaving it untouched." ;;
                *) error "Could not update $settings" ;;
            esac
            _strip_subagent_statusline_registration "$settings" || subrc=$?
            case $subrc in
                0) info "Removed the cs-subagent-statusline registration" ;;
                1) : ;;
                *) error "Could not update $settings" ;;
            esac
            ;;
        *)
            error "Usage: cs -statusline enable|disable"
            ;;
    esac
}

# Classify a COLORFGBG value ("fg;bg" or Konsole's "fg;default;bg") as
# light/dark by its background index; unknown when unparseable.
_theme_from_colorfgbg() {
    local bg="${1##*;}"
    case "$bg" in
        7|9|1[0-5]) echo "light" ;;
        [0-8])      echo "dark" ;;
        *)          echo "unknown" ;;
    esac
}

# Wrap an escape sequence for tmux DCS passthrough so it reaches the OUTER
# terminal instead of being answered by tmux itself: bracket with `\ePtmux;` …
# `\e\\` and double every ESC in the payload. Requires `allow-passthrough on`
# in the user's tmux; without it tmux drops the sequence and the query times out.
# Handles arbitrary multi-ESC payloads (e.g. an ST-terminated OSC query);
# _send_escape covers the single-ESC, BEL-terminated tab-color case separately.
_tmux_passthrough() {
    local seq="$1"
    local escaped=${seq//$'\033'/$'\033\033'}
    printf '\033Ptmux;%s\033\\' "$escaped"
}

# Classify an OSC 11 reply body (e.g. "rgb:fafa/f8f8/f2f2") by BT.709
# luminance and report the parsed 8-bit RGB alongside it. Pure string logic,
# no tty I/O, so it is unit-testable independent of a real terminal — unlike
# the query itself, which can't be exercised without a pty. Echoes
# "<light|dark> <r>;<g>;<b>" on success, "unknown" if the reply doesn't parse.
_parse_osc11_reply() {
    local reply="$1" rgb r4 g4 b4 r g b lum
    rgb="${reply#*rgb:}"
    if [ "$rgb" = "$reply" ]; then
        echo "unknown"
        return
    fi
    IFS=/ read -r r4 g4 b4 <<< "$rgb"
    r4="${r4:0:2}"; g4="${g4:0:2}"; b4="${b4:0:2}"
    case "$r4$g4$b4" in
        *[!0-9a-fA-F]*|"") echo "unknown"; return ;;
    esac
    r=$((16#$r4)); g=$((16#$g4)); b=$((16#$b4))
    # BT.709 luminance scaled by 10000; threshold is 0.5 * 255 * 10000.
    lum=$((2126 * r + 7152 * g + 722 * b))
    if [ "$lum" -ge 1275000 ]; then
        echo "light $r;$g;$b"
    else
        echo "dark $r;$g;$b"
    fi
}

# Query the terminal background via OSC 11. Safe only while cs owns the tty
# (before claude takes over stdin). With a "tmux" argument the query is
# wrapped for DCS passthrough so it reaches the real outer terminal from
# inside a tmux pane. Echoes _parse_osc11_reply's result.
_theme_from_osc11() {
    local via_tmux="${1:-}"
    # All I/O below is on /dev/tty, and every caller captures this function's
    # stdout via $(...), which makes fd 1 a pipe. So gate on stdin — a tty in an
    # interactive launch, and command substitution leaves it untouched — and on
    # /dev/tty being present, never on stdout.
    if [ ! -t 0 ] || [ ! -e /dev/tty ]; then
        echo "unknown"
        return
    fi
    local saved reply="" query
    query=$'\033]11;?\033\\'
    [ "$via_tmux" = "tmux" ] && query=$(_tmux_passthrough "$query")
    saved=$(stty -g < /dev/tty 2>/dev/null) || { echo "unknown"; return; }
    stty raw -echo < /dev/tty 2>/dev/null
    printf '%s' "$query" > /dev/tty
    IFS= read -r -t 1 -d '\' reply < /dev/tty 2>/dev/null || true
    stty "$saved" < /dev/tty 2>/dev/null
    _parse_osc11_reply "$reply"
}

# Detect the terminal theme plus, when known, the real background RGB. The
# OSC 11 query comes first because it asks the live terminal; COLORFGBG is
# only a fallback since tmux panes inherit it from the tmux server's
# start-time environment, where it goes stale across theme changes (observed:
# 15;0 under a light terminal). Only the OSC 11 path ever learns the actual
# RGB — the OS-appearance and COLORFGBG fallbacks classify light/dark without
# it. Echoes "<theme>" or "<theme> <r>;<g>;<b>" when the RGB is known.
detect_term_theme_and_bg() {
    local out
    if [ -n "${TMUX:-}" ]; then
        # Under tmux the real background can arrive on either of two OSC 11
        # channels, and which one answers depends on the tmux version. tmux
        # that proxies OSC 11 forwards a plain query to the client terminal, so
        # the plain query returns the true background and a DCS-passthrough
        # response never round-trips back to the pane. tmux that does not proxy
        # answers the plain query with its own default (black) and only the
        # passthrough reaches the real terminal. So try the plain query first
        # and trust any non-black RGB; a pure-black reply is tmux's own default,
        # indistinguishable from a genuine black background, so drop it and try
        # passthrough, then classify by OS appearance (which carries no RGB, so
        # the trailing gradient fails closed rather than fading toward black).
        out=$(_theme_from_osc11)
        [[ "$out" == *" 0;0;0" ]] && out="unknown"
        [ "$out" = "unknown" ] && out=$(_theme_from_osc11 tmux)
        [ "$out" = "unknown" ] && out=$(_theme_from_os_appearance)
    else
        out=$(_theme_from_osc11)
        if [ "$out" = "unknown" ] && [ -n "${COLORFGBG:-}" ]; then
            out=$(_theme_from_colorfgbg "$COLORFGBG")
        fi
    fi
    echo "$out"
}

# Thin wrapper over detect_term_theme_and_bg that keeps the original
# single-word contract (`cs -detect-theme`, and any caller that only needs the
# light/dark/unknown classification, not the RGB).
detect_term_theme() {
    local out
    out=$(detect_term_theme_and_bg)
    echo "${out%% *}"
}

# Detect the terminal theme (and its real background RGB when known) while cs
# still owns the tty, and export both for the statusline, hooks, and the session
# launched next. A no-op when CS_TERM_THEME is already set, so a manual override
# or an earlier detection wins. The OSC query must run here, never from a hook,
# where its reply would race into claude's input stream.
_export_term_theme() {
    [ -n "${CS_TERM_THEME:-}" ] && return 0
    local out theme
    out=$(detect_term_theme_and_bg)
    theme="${out%% *}"
    [ "$theme" = "unknown" ] && return 0
    # Export the detected theme so cs's own UI and the TUI picker (both cs
    # children) render with the right palette. CS_TERM_THEME_AUTO marks that this
    # value came from launch auto-detection, not an explicit user pin: the
    # statusline reads the marker to know it may override the frozen theme with
    # the live OS appearance (macOS auto dark mode), which the launch value can't
    # follow. A user-set CS_TERM_THEME returned above and carries no marker, so
    # it stays a hard override everywhere.
    export CS_TERM_THEME="$theme"
    export CS_TERM_THEME_AUTO="$theme"
    if [[ "$out" == *" "* ]] && [ -z "${CS_TERM_BG_RGB:-}" ]; then
        export CS_TERM_BG_RGB="${out#* }"
    fi
}

# macOS reports dark mode by the presence of the AppleInterfaceStyle key;
# the key is absent in light mode (including auto mode while light).
_theme_from_os_appearance() {
    [[ "$OSTYPE" == darwin* ]] || { echo "unknown"; return; }
    if defaults read -g AppleInterfaceStyle >/dev/null 2>&1; then
        echo "dark"
    else
        echo "light"
    fi
}

