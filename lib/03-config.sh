# ABOUTME: cs's settings files: the allow-list of CS_* keys a file may set, the value checker, the
# ABOUTME: KEY=value reader and the loader that fills unpinned keys. build.sh folds this into bin/cs and delivers it to hooks/cs-config.sh, hooks/cs-shared.sh and bin/cs-statusline.

# The allow-list, one record per key, in the order `cs -config list` prints:
#   KEY|group|label|edit|check|choices|default|when|whenText|describe
# edit is what the panel offers (flag toggles, choice asks with choices, text
# asks for free text, shell is changed from a shell only); flagoff and
# shelloff are flag and shell for a key that turns something off, whose label
# names what it turns off, so the panel shows that on while the key is off.
# check names the arm of _cs_config_check that accepts what the key's readers
# accept; when is now, /clear, launch or now+launch; describe is one sentence
# on what the setting does for you. Walked with parameter expansion only, so
# loading forks nothing.
_CS_CONFIG_SPEC=(
    'CS_STATUSLINE_DISABLE|Status line|Status line|flagoff|flag|-|off|now|applies at the next repaint|Draws the line under the prompt with the session, branch, model, context and usage limits.'
    'CS_STATUSLINE_LAYOUT|Status line|Layout|choice|enum|quiet,band,capsules|quiet|now|applies at the next repaint|How the status line looks: plain text, one full-width band of colour, or capsules.'
    'CS_STATUSLINE_SEGMENTS|Status line|Segments|text|segments|-|logo,session,notes,mail,git,model,ctx,limits|now|applies at the next repaint|Which items the status line shows, in order, as a comma-separated list.'
    'CS_STATUSLINE_BAND|Status line|Band colour|text|band|-|session|now|applies at the next repaint|The colour of the band and the session chip; session gives each session its own colour.'
    'CS_STATUSLINE_COLS|Status line|Width in columns|text|cols|-|measured|now|applies at the next repaint|A fixed width for the status line; unset, it fits the terminal.'
    'CS_STATUSLINE_FRAME|Status line|Frame columns|text|num|-|4|now|applies at the next repaint|Columns the prompt frame takes from the measured width, so the line is not cut short.'
    'CS_STATUSLINE_CTX_WARN|Status line|Context warn %|text|num|-|40|now|applies at the next repaint|Context use at which the gauge turns to its warning colour.'
    'CS_STATUSLINE_CTX_CRIT|Status line|Context critical %|text|num|-|60|now|applies at the next repaint|Context use at which the gauge turns to its critical colour.'
    'CS_USAGE_NO_REFRESH|Status line|Usage refresh|flagoff|flag|-|off|now|applies at the next repaint|Fetches your Fable usage for the status line; off, it shows only what is already cached.'
    'CS_SUBAGENT_STATUSLINE_DISABLE|Status line|Subagent rows|flagoff|flag|-|off|now|applies at the next repaint|Styles the rows Claude Code shows for running subagents to match the status line.'
    'CS_SCOPE_DISABLE|Prompts|Scope grounding|flagoff|flag|-|off|now|applies at your next prompt|Adds a short summary of the relevant code to each prompt that asks for code work.'
    'CS_SCOPE_TRACE_DISABLE|Prompts|Scope trace|flagoff|flag|-|off|now|applies at your next prompt|Logs how long each step cs runs on your prompt takes, to find a slow or stuck one.'
    'CS_SCOPE_BUDGET_MS|Prompts|Scope scan budget (ms)|text|ms|-|1500|now|applies at your next prompt|If the first steps on a prompt take longer than this, cs skips its code scan; 0 always skips it.'
    'CS_OBJECTIVE_CAPTURE_DISABLE|Prompts|Objective capture|flagoff|flag|-|off|now|applies at your next prompt|Records the first real prompt of a session as its objective in .cs/README.md.'
    'CS_DATE_REMINDER_DISABLE|Prompts|Date reminder|flagoff|flag|-|off|now|applies at your next prompt|Tells Claude the new date when a conversation runs past midnight.'
    'CS_CLARIFY_DISABLE|Prompts|Clarifying questions|flagoff|flag|-|off|now|applies at your next prompt|Asks Claude to question an unclear request instead of guessing; a leading ~ skips one prompt.'
    'CS_NARRATIVE_PROMPT_DISABLE|Prompts|Narrative line|flagoff|flag|-|off|now|applies at your next prompt|Asks Claude, on each prompt, to note a finding in its narrative before it answers.'
    'CS_CTX_WARN_CTX|Rotation|Context warning %|text|num|-|40|now|applies when the next turn ends|Context use at which Claude tells you, once, that the conversation is filling up.'
    'CS_ROTATE_BUTTON_CTX|Rotation|Rotate button from %|text|num|-|the warn %|now|applies by your next prompt|Context use from which the band above the prompt shows the rotate key, Ctrl+X 1.'
    'CS_ROTATE_NUDGE_CTX|Rotation|Rotation nudge %|text|num|-|60|now|applies when the next turn ends|Context use at which Claude suggests, once, writing a handoff and going on after /clear.'
    'CS_ROTATE_FORCE_CTX|Rotation|Rotate on its own past %|text|force|-|80|now|applies by your next prompt|Context use past which cs rotates by itself after a 20 second countdown you can stop.'
    'CS_NO_ROTATION_WAKE|Rotation|Wake after /clear|flagoff|flag|-|off|/clear|applies at the next /clear or launch|After /clear on a handoff, the fresh conversation starts its next step without you typing.'
    'CS_ROTATION_KICK_DELAY|Rotation|Wake delay (s)|text|secs|-|2|now|applies at the next rotation|Seconds between tries to wake the fresh conversation after /clear; 0 tries once.'
    'CS_REWRITE_PROVIDER|Rewriter (ctrl+g)|Provider|choice|enum|claude,claude-api,openai,openai-api,gemini,gemini-api,grok,xai|claude|now|applies at the next ctrl+g|Who rewrites your prompt; an -api choice calls the vendor API in place of its CLI.'
    'CS_REWRITE_MODEL|Rewriter (ctrl+g)|Model|text|model|-|per provider|now|applies at the next ctrl+g|The model that rewrites your prompt, by the provider name for it; unset, the provider picks.'
    'CS_REWRITE_TIMEOUT|Rewriter (ctrl+g)|Timeout (s)|text|secs|-|25|now|applies at the next ctrl+g|Seconds to wait for a rewrite before your prompt is left as you typed it.'
    'CS_REWRITE_PROGRESS|Rewriter (ctrl+g)|Progress|choice|enum|screen,native,line,static|screen|now|applies at the next ctrl+g|What the screen shows while ctrl+g waits for the rewrite.'
    'CS_REWRITE_DISABLE|Rewriter (ctrl+g)|Rewrite (ctrl+g)|flagoff|flag|-|off|now+launch|stopping rewrites: the next ctrl+g. Starting them after a launch without them: the next launch, which installs the ctrl+g shim.|Ctrl+g in the prompt rewrites what you typed into a clearer prompt before you send it.'
    'CS_TERM_THEME|Terminal|Theme|choice|enum|light,dark|detected|now|applies at the next repaint|Whether cs draws for a light or a dark terminal; unset, cs detects it at launch.'
    'CS_TERM_BG_RGB|Terminal|Background r;g;b|text|rgb|-|detected|now|applies at the next repaint|Your terminal background colour, which the status line shades its capsules from.'
    'CS_NO_ITERM2|Terminal|iTerm2 features|flagoff|flag|-|off|now+launch|the tab title, the bell bounce and the iTerm reads of the bar: now. The iTerm tmux path of the launch: the next launch.|Uses iTerm2 for the tab title, a dock bounce when a turn ends and the theme of your profile.'
    'CS_NERD_FONTS|Terminal|Nerd Font glyphs|flag|flag|-|off|now|applies at the next cs command|Shows Nerd Font icons in cs banners and session lists; needs a Nerd Font in the terminal.'
    'CS_FILTER_CHAT|Terminal|Filter chat|flag|flag|-|off|now+launch|/filter-chat and the band key: now. A change here or in a shell: the next launch.|Shows only your prompts and the replies from Claude in this session; the band key or /filter-chat flips it.'
    'CS_NO_MAIL_WAKE|Mail|Wake on mail|flagoff|flag|-|off|now|applies when the next turn ends|Unread mail from another session takes a turn, so the exchange goes on without you typing.'
    'CS_MAIL_WAKE_MAX|Mail|Wakes in a row|text|num|-|5|now|applies when the next turn ends|How many turns mail may take in a row before it waits for a prompt from you.'
    'CS_NO_TASK_TOOLS|Launch|Task tools|flagoff|flag|-|off|launch|applies at the next launch|Gives Claude its task list tools on every model, for rotation, the queue and handoffs.'
    'CS_NO_UPDATE_CHECK|Launch|Update check|flagoff|flag|-|off|launch|applies at the next launch|Asks GitHub for a newer cs at most hourly; off, cs makes no network request for it.'
    'CS_NO_FUNCTION_HOOKS|Launch|Mods|shelloff|flag|-|off|launch|applies at the next launch; with mods off, the cs panel does not load either|Lets a launch load mods, the cs band and settings pane among them; off, none loads.'
    'CS_QUEUE_MAX_FAILURES|Queue|Stops after failures|text|num|-|5|now|applies when the next turn ends|A queue run stops once one task has this many failed tool calls.'
    'CS_QUEUE_MAX_CTX|Queue|Stops past context %|text|num|-|85|now|applies when the next turn ends|A queue run stops before its next task once context use reaches this.'
    'CS_QUEUE_MAX_5H|Queue|Stops past 5h limit %|text|num|-|85|now|applies when the next turn ends|A queue run stops before its next task once your 5-hour usage limit reaches this.'
    'CS_NARRATIVE_MAX_BYTES|Narrative|Budget (bytes)|text|bytes|-|131072|now|applies when the next turn ends|Size past which a session narrative is due to move its older sections to the archive.'
    'CS_NARRATIVE_KEEP_BYTES|Narrative|Tail kept (bytes)|text|bytes|-|65536|now|applies when the next turn ends|How much of the newest narrative stays in the live file when it rotates.'
)

# Keys a file never sets, each with the reason the writer gives. Each names a
# secret, a program cs runs, a path, where secrets live, or a setting with a
# record of its own: a file a plugin can write must choose none of them.
_CS_CONFIG_EXCLUDED=(
    'CS_SECRETS_PASSWORD|it is a secret, and the file is plain text'
    'CLAUDE_CODE_BIN|it names a program cs runs, which a file a plugin can write must not choose'
    'CS_TMUX_BIN|it names a program cs runs, which a file a plugin can write must not choose'
    'CS_REWRITE_CMD|it names a program cs runs, which a file a plugin can write must not choose'
    'CS_REAL_EDITOR|it names a program cs runs, which a file a plugin can write must not choose'
    'CS_SESSIONS_ROOT|it names where every session lives, and each process keys on it'
    'CS_SECRETS_BACKEND|it moves where cs-secrets looks, and every stored secret would vanish from view until it moved back'
    'CS_PLATFORM_OVERRIDE|it moves where cs-secrets looks, and every stored secret would vanish from view until it moved back'
    'CS_USAGE_DIR|it names a directory the status line writes to'
    'CS_ACTOR|identity has its own per-session file, .cs/local/identity, which outranks a machine-wide name'
    'CS_STATUSLINE_CAPS|it has its own record, which cs -statusline caps on|off|ask writes'
)

# Each key's check arm and choices, as "<arm>|<choices>" in _CS_CFG_R_<KEY>,
# so a line's key is looked up without a walk of the table. Built once a
# process, the first time a file or a value is checked: a reader on a machine
# with no settings file never pays for it.
_cs_config_index() {
    local rec key arm
    [ "${_CS_CFG_INDEXED:-}" != "$$" ] || return 0
    for rec in "${_CS_CONFIG_SPEC[@]}"; do
        key=${rec%%|*}
        rec=${rec#*|*|*|*|}
        arm=${rec%%|*}
        rec=${rec#*|}
        printf -v "_CS_CFG_R_$key" '%s|%s' "$arm" "${rec%%|*}"
    done
    _CS_CFG_INDEXED=$$
}

# <key>'s check arm in _CS_CFG_ARM and its choices in _CS_CFG_CHOICES; status
# 1, nothing set, for a key outside the allow-list. Runs after
# _cs_config_index.
_cs_config_record() {  # key
    # Indirect expansion evaluates an array subscript in the name: a key that
    # is not a name is no setting, and never reaches it.
    case "$1" in ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) return 1 ;; esac
    local r="_CS_CFG_R_$1"
    [ -n "${!r-}" ] || return 1
    _CS_CFG_ARM=${!r%%|*}
    _CS_CFG_CHOICES=${!r#*|}
}

# "a, b or c" from "a,b,c", in _CS_CONFIG_WHY.
_cs_config_or_list() {  # csv
    local rest="$1" out=""
    while :; do
        case "$rest" in
            *,*) out="${out:+$out, }${rest%%,*}"; rest=${rest#*,} ;;
            *) out="${out:+$out or }$rest"; break ;;
        esac
    done
    _CS_CONFIG_WHY=$out
}

# Whether <value> is an r;g;b triplet, each part 0 to 255 in one to three
# digits: what the status line's _parse_rgb_triplet takes.
_cs_config_rgb() {  # value
    local v="$1" part n=0
    case "$v" in ''|*[!0-9\;]*) return 1 ;; esac
    while :; do
        part=${v%%;*}
        case "$part" in ''|????*) return 1 ;; esac
        [ "$((10#$part))" -le 255 ] || return 1
        n=$((n + 1))
        case "$v" in *\;*) v=${v#*;} ;; *) break ;; esac
    done
    [ "$n" -eq 3 ]
}

# Whether <value> passes check arm <arm> (choices for enum), 0 or 1; on a
# refusal, what the arm accepts in _CS_CONFIG_WHY, phrased to follow "is" or
# "not". Each arm takes what its readers take today; none takes an empty value
# or a control character. A value that passes sets nothing: the readers check
# every line of a file on every repaint.
_cs_config_check() {  # arm, choices, value
    case "$1" in
        flag) case "$3" in 0|1) return 0 ;; esac ;;
        enum) case "$3" in ''|*,*) ;; *) case ",$2," in *",$3,"*) return 0 ;; esac ;; esac ;;
        num) case "$3" in ''|*[!0-9]*|????*) ;; *) return 0 ;; esac ;;
        ms|secs) case "$3" in ''|*[!0-9]*|????????*) ;; *) return 0 ;; esac ;;
        cols) case "$3" in ''|0*|*[!0-9]*|?????*) ;; *) return 0 ;; esac ;;
        bytes)
            case "$3" in
                ''|*[!0-9]*|????????????????*) ;;
                *) [ "$((10#$3))" -eq 0 ] || return 0 ;;
            esac
            ;;
        force)
            case "$3" in
                [oO][fF][fF]) return 0 ;;
                ''|*[!0-9]*|????*) ;;
                *) [ "$((10#$3))" -gt 100 ] || return 0 ;;
            esac
            ;;
        band)
            case "$3" in red|blue|green|yellow|purple|orange|pink|cyan|brand|periwinkle|session|none) return 0 ;; esac
            ! _cs_config_rgb "$3" || return 0
            ;;
        rgb) ! _cs_config_rgb "$3" || return 0 ;;
        segments) ! _cs_config_segments "$3" || return 0 ;;
        model)
            case "$3" in
                [A-Za-z0-9]*) case "$3" in *[!A-Za-z0-9._:/-]*) ;; *) [ "${#3}" -gt 128 ] || return 0 ;; esac ;;
            esac
            ;;
    esac
    _cs_config_why "$1" "$2"
    return 1
}

# Whether <value> is a comma-separated list of status line segments, each at
# most once: the names bin/cs-statusline draws.
_cs_config_segments() {  # value
    local rest="$1" item seen=","
    while :; do
        item=${rest%%,*}
        case "$item" in
            logo|session|notes|mail|pane|git|model|ctx|limits|fable|cost) ;;
            *) return 1 ;;
        esac
        case "$seen" in *",$item,"*) return 1 ;; esac
        seen="$seen$item,"
        case "$rest" in *,*) rest=${rest#*,} ;; *) return 0 ;; esac
    done
}

# What check arm <arm> accepts, in _CS_CONFIG_WHY.
_cs_config_why() {  # arm, choices
    case "$1" in
        flag) _CS_CONFIG_WHY="1 (on) or 0 (off)" ;;
        enum) _cs_config_or_list "$2" ;;
        num) _CS_CONFIG_WHY="a whole number of 1 to 3 digits" ;;
        ms) _CS_CONFIG_WHY="a whole number of milliseconds of 1 to 7 digits (0 skips the scan)" ;;
        secs) _CS_CONFIG_WHY="a whole number of seconds of 1 to 7 digits" ;;
        cols) _CS_CONFIG_WHY="a column count from 1 to 9999" ;;
        bytes) _CS_CONFIG_WHY="a byte count above 0 of at most 15 digits" ;;
        force) _CS_CONFIG_WHY="off, 0 or a percentage from 1 to 100" ;;
        band) _CS_CONFIG_WHY="a palette name, brand, periwinkle, session, none or r;g;b" ;;
        rgb) _CS_CONFIG_WHY="r;g;b, each 0 to 255" ;;
        segments) _CS_CONFIG_WHY="a comma-separated list of logo, session, notes, mail, pane, git, model, ctx, limits, fable and cost, each at most once" ;;
        model) _CS_CONFIG_WHY="a model name of letters, digits and . _ : / -, starting with a letter or digit, at most 128 characters" ;;
        *)
            _CS_CONFIG_WHY="a value of check arm '$1', which cs does not have"
            echo "cs: _cs_config_check has no arm named '$1'" >&2
            ;;
    esac
}

# Whether <value> is one an allowed <key> takes; what it takes in
# _CS_CONFIG_WHY. The key must be in the allow-list: an unknown one is a
# caller's bug, said on stderr, status 2.
cs_config_valid() {  # key, value
    _cs_config_index
    if ! _cs_config_record "$1"; then
        echo "cs: cs_config_valid: $1 is not in the allow-list" >&2
        return 2
    fi
    _cs_config_check "$_CS_CFG_ARM" "$_CS_CFG_CHOICES" "$2"
}

# Whether <key> is one a file never sets; the reason in _CS_CONFIG_WHY.
_cs_config_excluded() {  # key
    local rec
    for rec in "${_CS_CONFIG_EXCLUDED[@]}"; do
        if [ "${rec%%|*}" = "$1" ]; then
            _CS_CONFIG_WHY=${rec#*|}
            return 0
        fi
    done
    return 1
}

# One skipped line, appended to _CS_CONFIG_IGNORED as
# "<scope>\t<line no>\t<line>\t<why>\n", its control characters shown as ?.
_cs_config_skip() {  # scope, line no, line, why
    _CS_CONFIG_IGNORED+="$1"$'\t'"$2"$'\t'"${3//[[:cntrl:]]/?}"$'\t'"$4"$'\n'
}

# Reads one settings file, scope M (this machine's) or S (the session's),
# line by line with read -r: never sourced, nothing expanded. A good line
# sets _CS_CFG_<scope>_<KEY> and names the key in _CS_CFG_READ_<scope>
# (" KEY KEY "); any other is skipped and named in _CS_CONFIG_IGNORED. A
# value its key refuses is also kept in _CS_CFG_<scope>BAD_<KEY> as
# "line <n>: <line>: <why>", the key named in _CS_CFG_BAD_<scope>, the value
# that would otherwise apply, until a later good line of the key in the same
# file replaces it. A per-key variable counts only while its list names the
# key, so one the environment carried in is never read as a file's. A missing file, a
# directory at the path or an unreadable file reads as empty, status 0, so a
# reader under set -e goes on with the environment alone. The loop body is
# written out rather than called per line: the status line reads every line
# on every repaint.
_cs_config_read() {  # file, scope
    local line n=0 key value list
    [ -f "$1" ] && [ -r "$1" ] || return 0
    {
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n + 1))
            case "$line" in *[![:space:]]*) ;; *) continue ;; esac
            case "$line" in
                '#'*) continue ;;
                *=*) key=${line%%=*}; value=${line#*=} ;;
                *) _cs_config_skip "$2" "$n" "$line" "not KEY=value"; continue ;;
            esac
            case "$key" in
                ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) _cs_config_skip "$2" "$n" "$line" "not KEY=value"; continue ;;
            esac
            list="_CS_CFG_R_$key"
            list=${!list-}
            if [ -z "$list" ]; then
                if _cs_config_excluded "$key"; then
                    # One such key is a secret: the listing and doctor name
                    # the key, never the value.
                    _cs_config_skip "$2" "$n" "$key=(hidden)" "not kept in cs's config"
                else
                    _cs_config_skip "$2" "$n" "$line" "not a cs setting"
                fi
                continue
            fi
            if ! _cs_config_check "${list%%|*}" "${list#*|}" "$value"; then
                _cs_config_skip "$2" "$n" "$line" "not $_CS_CONFIG_WHY"
                printf -v "_CS_CFG_${2}BAD_$key" '%s' "line $n: ${line//[[:cntrl:]]/?}: not $_CS_CONFIG_WHY"
                list="_CS_CFG_BAD_$2"
                case "${!list}" in *" $key "*) ;; *) printf -v "$list" '%s' "${!list}$key " ;; esac
                continue
            fi
            printf -v "_CS_CFG_${2}_$key" '%s' "$value"
            list="_CS_CFG_READ_$2"
            case "${!list}" in
                *" $key "*) ;;
                *)
                    printf -v "$list" '%s' "${!list}$key "
                    if [ "$2" = M ]; then
                        _CS_CONFIG_COUNT_M=$((_CS_CONFIG_COUNT_M + 1))
                    else
                        _CS_CONFIG_COUNT_S=$((_CS_CONFIG_COUNT_S + 1))
                    fi
                    ;;
            esac
            list="_CS_CFG_BAD_$2"
            if [ "${!list}" != " " ]; then
                value=${!list}
                printf -v "$list" '%s' "${value/ $key / }"
            fi
        done < "$1"
    } 2>/dev/null || true
    return 0
}

# Where <key>'s value comes from, in _CS_CFG_SOURCE: shell (the environment
# pins it), launch (the launch measured it: CS_TERM_THEME beside
# CS_TERM_THEME_AUTO, and CS_TERM_BG_RGB under that marker without
# CS_TERM_BG_RGB_PINNED, the rule the status line's _sl_bg_pinned states),
# session, machine or default. A key the loader has not looked at in this
# process holds what the process started with, so its value answers.
cs_config_source() {  # key
    local src="_CS_CFG_SRC_$1"
    case "${_CS_CFG_SEEN-}" in
        *" $1 "*) _CS_CFG_SOURCE=${!src}; return 0 ;;
    esac
    if [ -z "${!1-}" ]; then
        _CS_CFG_SOURCE=default
    elif [ -z "${CS_TERM_THEME_AUTO:-}" ]; then
        _CS_CFG_SOURCE=shell
    else
        case "$1" in
            CS_TERM_THEME) _CS_CFG_SOURCE=launch ;;
            CS_TERM_BG_RGB) if [ -n "${CS_TERM_BG_RGB_PINNED:-}" ]; then _CS_CFG_SOURCE=shell; else _CS_CFG_SOURCE=launch; fi ;;
            *) _CS_CFG_SOURCE=shell ;;
        esac
    fi
}

# Decides, once a process, where <key>'s value comes from (cs_config_source),
# in _CS_CFG_SRC_<KEY>, and lists the key in _CS_CFG_SEEN.
_cs_config_see() {  # key
    case "${_CS_CFG_SEEN-}" in *" $1 "*) return 0 ;; esac
    cs_config_source "$1"
    printf -v "_CS_CFG_SRC_$1" '%s' "$_CS_CFG_SOURCE"
    _CS_CFG_SEEN="${_CS_CFG_SEEN-}$1 "
}

# Fills each allowed key the environment does not pin from the session's file
# (<session_dir>/.cs/local/config), else this machine's
# (${XDG_CONFIG_HOME:-$HOME/.config}/cs/config), in this shell only: every
# fill is unexported, so a child reads the files itself and an edit reaches
# the next repaint and the next hook, and nothing a launch hands claude can
# pose as a pin. A flag's 0 fills as unset, so readers testing = "1" and
# readers testing -n both see off. A key no file sets is unset only when an
# earlier call filled it; a value the environment supplied is never touched.
#
# Whether the environment pins a key is decided the first time a file names
# it in this process, before its first fill, so the value it has then is the
# one the process started with (_CS_CFG_SEEN lists the keys decided, and
# _CS_CFG_SRC_<KEY> says where each value came from). Keyed on $$, which a
# subshell shares and a child does not: a copy sourced again in the same
# process keeps those answers, and a child takes its own. Only the keys a file
# names, or an earlier call filled, are walked: a status line repaint with a
# short file pays for its lines, not for the table. Skipped lines:
# _CS_CONFIG_IGNORED.
cs_config_load() {  # [session_dir]
    local rec key arm src have from cand
    # No XDG_CONFIG_HOME and no HOME (a hook Claude Code runs with a bare
    # environment) names no machine file at all, rather than /.config.
    _CS_CONFIG_MACHINE=""
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
        _CS_CONFIG_MACHINE="$XDG_CONFIG_HOME/cs/config"
    elif [ -n "${HOME:-}" ]; then
        _CS_CONFIG_MACHINE="$HOME/.config/cs/config"
    fi
    _CS_CONFIG_SESSION=""
    [ -z "${1:-}" ] || _CS_CONFIG_SESSION="$1/.cs/local/config"
    _CS_CONFIG_IGNORED=""
    _CS_CONFIG_COUNT_M=0
    _CS_CONFIG_COUNT_S=0
    _CS_CFG_READ_M=" "
    _CS_CFG_READ_S=" "
    _CS_CFG_BAD_M=" "
    _CS_CFG_BAD_S=" "
    if [ "${_CS_CFG_PID:-}" != "$$" ]; then
        _CS_CFG_PID=$$
        _CS_CFG_SEEN=" "
        _CS_CFG_FILLED=""
        _CS_CFG_MEASURED_THEME=""
        _CS_CFG_BG_PINNED_BY_FILE=""
    fi
    # No file to read and nothing an earlier call filled: the environment
    # stands as it is, at the cost of two tests, every reader's lot on a
    # machine with no settings file.
    if [ -z "${_CS_CFG_FILLED-}" ] && { [ -z "$_CS_CONFIG_MACHINE" ] || [ ! -f "$_CS_CONFIG_MACHINE" ]; } \
        && { [ -z "$_CS_CONFIG_SESSION" ] || [ ! -f "$_CS_CONFIG_SESSION" ]; }; then
        return 0
    fi
    _cs_config_index
    # The theme and the background are judged together, before any fill: a
    # theme from a file drops the marker that makes the background a
    # measurement rather than a pin. The theme the launch measured is kept
    # across calls: a fill replaces the value, and the background's fate
    # below compares against it.
    _cs_config_see CS_TERM_THEME
    _cs_config_see CS_TERM_BG_RGB
    if [ "$_CS_CFG_SRC_CS_TERM_THEME" = launch ]; then
        _CS_CFG_MEASURED_THEME=$CS_TERM_THEME
    fi
    [ -z "$_CS_CONFIG_MACHINE" ] || _cs_config_read "$_CS_CONFIG_MACHINE" M
    [ -z "$_CS_CONFIG_SESSION" ] || _cs_config_read "$_CS_CONFIG_SESSION" S
    cand="$_CS_CFG_READ_S$_CS_CFG_READ_M${_CS_CFG_SEEN-}"
    for rec in "${_CS_CONFIG_SPEC[@]}"; do
        key=${rec%%|*}
        case "$cand" in *" $key "*) ;; *) continue ;; esac
        src="_CS_CFG_SRC_$key"
        _cs_config_see "$key"
        [ "${!src}" != shell ] || continue
        if case "$_CS_CFG_READ_S" in *" $key "*) true ;; *) false ;; esac; then
            have="_CS_CFG_S_$key"
            from=session
        elif case "$_CS_CFG_READ_M" in *" $key "*) true ;; *) false ;; esac; then
            have="_CS_CFG_M_$key"
            from=machine
        else
            case "${!src}" in
                session|machine)
                    unset "$key"
                    printf -v "$src" '%s' default
                    ;;
            esac
            continue
        fi
        arm=${rec#*|*|*|*|}
        if [ "${arm%%|*}" = flag ] && [ "${!have}" = 0 ]; then
            unset "$key"
        else
            printf -v "$key" '%s' "${!have}"
            # shellcheck disable=SC2163  # the variable named by $key, unexported
            export -n "$key"
        fi
        printf -v "$src" '%s' "$from"
        _CS_CFG_FILLED=1
    done
    # A theme from a file that is not the measured one is a pin: the marker
    # that called the variable a measurement goes, and so does the measured
    # background when no file sets one, as the status line would otherwise
    # tint toward a background of the other theme. A file theme equal to the
    # measured one leaves the measurement whole, the theme exported under its
    # marker (put back when an earlier load for another file dropped it), so
    # a child of this process reads the three as the launch's and not as a
    # pin nobody exported. A background from a file is a pin too, which
    # CS_TERM_BG_RGB_PINNED says.
    case "$_CS_CFG_SRC_CS_TERM_THEME" in
        session|machine)
            if [ "${CS_TERM_THEME:-}" != "${_CS_CFG_MEASURED_THEME-}" ]; then
                unset CS_TERM_THEME_AUTO
                if [ "$_CS_CFG_SRC_CS_TERM_BG_RGB" = launch ]; then
                    unset CS_TERM_BG_RGB
                    _CS_CFG_SRC_CS_TERM_BG_RGB=default
                fi
            else
                export CS_TERM_THEME
                CS_TERM_THEME_AUTO=1
                export CS_TERM_THEME_AUTO
            fi
            ;;
    esac
    case "$_CS_CFG_SRC_CS_TERM_BG_RGB" in
        session|machine)
            CS_TERM_BG_RGB_PINNED=1
            export -n CS_TERM_BG_RGB_PINNED
            _CS_CFG_BG_PINNED_BY_FILE=1
            ;;
        *)
            if [ -n "${_CS_CFG_BG_PINNED_BY_FILE-}" ]; then
                unset CS_TERM_BG_RGB_PINNED
                _CS_CFG_BG_PINNED_BY_FILE=""
            fi
            ;;
    esac
    return 0
}

# At source time, so bin/cs's own top-level reads (CS_NERD_FONTS while it
# loads), every hook that sources a delivery and the status line see the
# files before their first read.
cs_config_load "${CLAUDE_SESSION_DIR:-}"
