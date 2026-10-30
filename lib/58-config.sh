# ABOUTME: cs [<name>] -config list|get|set|unset: shows the settings readers see and where each comes from, and
# ABOUTME: keeps them in this machine's ~/.config/cs/config or a session's .cs/local/config through one writer.

_CONFIG_USAGE="Usage: cs [<name>] -config list [--porcelain] | get <KEY> | set <KEY> <value> | unset <KEY>"

# A settings file as messages name it: a session's as <name>/.cs/local/config,
# any other with ~ for $HOME. In _CONFIG_LABEL.
_config_label() {  # file, [session name]
    if [ -n "${2:-}" ]; then
        _CONFIG_LABEL="$2/.cs/local/config"
        return 0
    fi
    # shellcheck disable=SC2088  # a ~ for the person to read, never expanded
    case "$1" in
        "$HOME"/*) _CONFIG_LABEL="~/${1#"$HOME"/}" ;;
        *) _CONFIG_LABEL=$1 ;;
    esac
}

# The fields of <key>'s record, in _CF_GROUP, _CF_LABEL, _CF_EDIT, _CF_CHECK,
# _CF_CHOICES, _CF_DEFAULT, _CF_WHEN and _CF_WHENTEXT.
_config_fields() {  # key
    local rec
    for rec in "${_CS_CONFIG_SPEC[@]}"; do
        [ "${rec%%|*}" = "$1" ] || continue
        IFS='|' read -r _ _CF_GROUP _CF_LABEL _CF_EDIT _CF_CHECK _CF_CHOICES _CF_DEFAULT _CF_WHEN _CF_WHENTEXT <<< "$rec"
        return 0
    done
    error "_config_fields: $1 is not in the allow-list"
}

# Refuses, by name, a key the files never hold and a key that is no setting.
_config_known_key() {  # key
    _cs_config_index
    _cs_config_record "$1" && return 0
    if _cs_config_excluded "$1"; then
        error "$1 is not kept in cs's config: $_CS_CONFIG_WHY. Export it in your shell."
    fi
    error "$1 is not a cs setting; cs -config list names every one"
}

# Whether a file's list (_CS_CFG_READ_M, _CS_CFG_BAD_S and their kin) names <key>.
_config_listed() {  # list, key
    case "$1" in *" $2 "*) return 0 ;; esac
    return 1
}

# <file>'s new contents: every line but <key>'s, then "<key>=<value>" when a
# value is given (three args set, two unset). Every other line stays as typed,
# in order, comments, blanks and lines readers skip included. A failed read
# fails the render, so cs_write_atomic keeps the old file.
_config_render() {  # file, key, [value]
    if [ -f "$1" ]; then
        awk -v key="$2" 'index($0, key "=") != 1' "$1" || return 1
    fi
    if [ $# -ge 3 ]; then
        printf '%s=%s\n' "$2" "$3" || return 1
    fi
}

# Writes <key> (or drops it, with no value) in <file>, under the lock beside
# the file, through cs_write_atomic, which refuses a link that leads out of a
# session. The directory is made first: a session's .cs/local through
# cs_mkdir_inside, this machine's ~/.config/cs with mkdir -p, its error shown.
_config_write() {  # file, session dir or "", key, [value]
    local file="$1" sdir="$2" err
    shift 2
    if [ -n "$sdir" ]; then
        cs_mkdir_inside "$sdir/.cs/local" || error "$1 not changed: cs could not make $sdir/.cs/local"
    else
        err=$(mkdir -p -- "${file%/*}" 2>&1) || error "$1 not changed: cs could not make ${file%/*}: $err"
    fi
    _cs_with_state_lock "$file" cs_write_atomic "$file" _config_render "$file" "$@" \
        || error "$1 not changed: $_CONFIG_LABEL could not be written"
}

# What `set` adds on stderr when <key>'s new value is not the one readers
# will see: the environment pins it, or (a machine write from inside a
# session) the session's own file sets it.
_config_shadowed() {  # key, wrote the machine's file (1 or "")
    cs_config_source "$1"
    if [ "$_CS_CFG_SOURCE" = shell ]; then
        printf '%s is also set in your environment (%s), which wins until you unset it there\n' "$1" "${!1//[[:cntrl:]]/?}" >&2
    elif [ -n "$2" ] && _config_listed "$_CS_CFG_READ_S" "$1"; then
        local v="_CS_CFG_S_$1"
        _config_label "" "${CLAUDE_SESSION_NAME:-${CLAUDE_SESSION_DIR##*/}}"
        printf '%s is also set in %s (%s), which wins in that session\n' "$1" "$_CONFIG_LABEL" "${!v}" >&2
    fi
}

# The skipped file value that would otherwise apply to <key>, as the
# porcelain's last field: the session's, else (when the session sets no good
# value) the machine's; - for none.
_config_ignored_field() {  # key
    local v
    if _config_listed "$_CS_CFG_BAD_S" "$1"; then
        v="_CS_CFG_SBAD_$1"
        _CONFIG_IGNORED_FIELD="session ${!v}"
    elif ! _config_listed "$_CS_CFG_READ_S" "$1" && _config_listed "$_CS_CFG_BAD_M" "$1"; then
        v="_CS_CFG_MBAD_$1"
        _CONFIG_IGNORED_FIELD="machine ${!v}"
    else
        _CONFIG_IGNORED_FIELD=-
    fi
}

# One record per allowed key, in table order, eleven tab-separated fields:
# key group label edit choices default when whenText value source ignored,
# - for none. The cs-panel and cs mods parse it; tests/fixtures/
# config-porcelain.txt pins it.
_config_list_porcelain() {
    local rec key value
    for rec in "${_CS_CONFIG_SPEC[@]}"; do
        key=${rec%%|*}
        _config_fields "$key"
        value=${!key-}
        value=${value//[[:cntrl:]]/?}
        cs_config_source "$key"
        _config_ignored_field "$key"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$_CF_GROUP" "$_CF_LABEL" "$_CF_EDIT" \
            "$_CF_CHOICES" "$_CF_DEFAULT" "$_CF_WHEN" "$_CF_WHENTEXT" "${value:--}" "$_CS_CFG_SOURCE" "$_CONFIG_IGNORED_FIELD"
    done
}

# Every setting under its group: value (the default when none is set), where
# it comes from, when a change applies, and a note where the environment
# hides a file's value; then each file's skipped lines.
_config_list_human() {  # session name or ""
    local rec key value last="" line v scope n text why prev="" mlabel slabel
    _config_label "$_CS_CONFIG_MACHINE"
    mlabel=$_CONFIG_LABEL
    _config_label "" "$1"
    slabel=$_CONFIG_LABEL
    for rec in "${_CS_CONFIG_SPEC[@]}"; do
        key=${rec%%|*}
        _config_fields "$key"
        if [ "$_CF_GROUP" != "$last" ]; then
            printf '%s\n' "$_CF_GROUP"
            last=$_CF_GROUP
        fi
        value=${!key-}
        value=${value//[[:cntrl:]]/?}
        cs_config_source "$key"
        printf -v line '  %-31s %-13s %-8s %-10s' "$key" "${value:-$_CF_DEFAULT}" "$_CS_CFG_SOURCE" "$_CF_WHEN"
        line=${line%"${line##*[! ]}"}
        if [ "$_CS_CFG_SOURCE" = shell ]; then
            if _config_listed "$_CS_CFG_READ_S" "$key"; then
                v="_CS_CFG_S_$key"
                printf -v line '%-67s (%s has %s; your environment wins)' "$line" "$slabel" "${!v}"
            elif _config_listed "$_CS_CFG_READ_M" "$key"; then
                v="_CS_CFG_M_$key"
                printf -v line '%-67s (%s has %s; your environment wins)' "$line" "$mlabel" "${!v}"
            fi
        fi
        printf '%s\n' "$line"
    done
    while IFS=$'\t' read -r scope n text why; do
        [ -n "$scope" ] || continue
        if [ "$scope" != "$prev" ]; then
            if [ "$scope" = M ]; then printf 'Ignored in %s\n' "$mlabel"; else printf 'Ignored in %s\n' "$slabel"; fi
            prev=$scope
        fi
        printf '  line %s: %s: %s\n' "$n" "$text" "$why"
    done <<< "$_CS_CONFIG_IGNORED"
}

cmd_config() {  # session name or "", action, args...
    local name="$1" sdir="" file action
    shift
    if [ -n "$name" ]; then
        sdir="$SESSIONS_ROOT/$name"
        is_session_dir "$sdir" || error "No such session: $name"
        cs_config_load "$sdir"
        file="$sdir/.cs/local/config"
    else
        file=$_CS_CONFIG_MACHINE
    fi
    _config_label "$file" "$name"
    action="${1:-}"
    [ $# -eq 0 ] || shift
    case "$action" in
        list)
            case "$#:${1:-}" in
                0:) _config_list_human "${name:-${CLAUDE_SESSION_NAME:-${CLAUDE_SESSION_DIR##*/}}}" ;;
                1:--porcelain) _config_list_porcelain ;;
                *) error "$_CONFIG_USAGE" ;;
            esac
            ;;
        get)
            [ $# -eq 1 ] || error "$_CONFIG_USAGE"
            _config_known_key "$1"
            [ -z "${!1-}" ] || printf '%s\n' "${!1}"
            ;;
        set)
            [ $# -eq 2 ] || error "$_CONFIG_USAGE"
            _config_known_key "$1"
            [ -n "$2" ] || error "$1 takes a value; cs -config unset $1 removes it"
            cs_config_valid "$1" "$2" || error "$1 is $_CS_CONFIG_WHY; got ${2//[[:cntrl:]]/?}"
            [ -z "$sdir" ] || _vet_named_session "$sdir"
            _config_write "$file" "$sdir" "$1" "$2"
            _config_fields "$1"
            printf '%s=%s in %s: %s\n' "$1" "$2" "$_CONFIG_LABEL" "$_CF_WHENTEXT"
            if [ -n "$sdir" ]; then _config_shadowed "$1" ""; else _config_shadowed "$1" 1; fi
            ;;
        unset)
            [ $# -eq 1 ] || error "$_CONFIG_USAGE"
            _config_known_key "$1"
            [ -z "$sdir" ] || _vet_named_session "$sdir"
            if [ ! -f "$file" ] || ! grep -q "^$1=" "$file"; then
                printf '%s is not in %s; nothing changed\n' "$1" "$_CONFIG_LABEL"
                return 0
            fi
            _config_write "$file" "$sdir" "$1"
            printf '%s removed from %s\n' "$1" "$_CONFIG_LABEL"
            ;;
        *)
            error "$_CONFIG_USAGE"
            ;;
    esac
}
