# ABOUTME: cs -tag: read, write, and validate session tags stored as the
# ABOUTME: inline-array tags line in .cs/README.md YAML frontmatter.

# Print one tag per line from the README's frontmatter tags line. Tolerates
# arbitrary spacing and double-quoted entries; block-style lists and files
# without frontmatter read as empty. Never errors.
_tags_read() {
    local readme="$1"
    [ -f "$readme" ] || return 0
    awk '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        /^tags:[[:space:]]*\[/ {
            line = $0
            sub(/^tags:[[:space:]]*\[/, "", line)
            sub(/\][[:space:]]*$/, "", line)
            n = split(line, parts, ",")
            for (i = 1; i <= n; i++) {
                t = parts[i]
                gsub(/^[[:space:]\"]+/, "", t)
                gsub(/[\"[:space:]]+$/, "", t)
                if (t != "") print t
            }
            exit
        }
    ' "$readme" 2>/dev/null
}

# True when line 1 is exactly the opening frontmatter fence "---". A
# frontmatter-less file (no fence at all) or a CRLF fence ("---\r", which is
# not the exact string "---") both fail this check — either would otherwise
# make _tags_write's insert branch silently pass the file through unchanged.
_tags_has_frontmatter() {
    local readme="$1"
    [ -f "$readme" ] || return 1
    awk 'NR==1 && $0=="---" {exit 0} NR==1 {exit 1}' "$readme"
}

# True when the frontmatter carries a bare "tags:" line (block-style list) —
# a structure we refuse to rewrite rather than guess at.
_tags_has_block_style() {
    local readme="$1"
    [ -f "$readme" ] || return 1
    awk '
        NR == 1 && $0 != "---" { exit 1 }
        NR > 1 && $0 == "---" { exit 1 }
        /^tags:[[:space:]]*$/ { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$readme" 2>/dev/null
}

# Rewrite (or insert) the frontmatter tags line as the canonical inline
# array. Every other line passes through untouched. Atomic tmp+mv.
# Args: readme, space-separated tags (may be empty -> "tags: []").
_tags_write() {
    local readme="$1" tags="$2"
    local formatted="" t
    for t in $tags; do
        formatted="${formatted:+$formatted, }$t"
    done
    local newline="tags: [$formatted]"
    local tmp="$readme.tmp"
    if _tags_read_line_exists "$readme"; then
        awk -v repl="$newline" '
            NR == 1 && $0 == "---" { fm = 1; print; next }
            fm == 1 && $0 == "---" { fm = 2; print; next }
            fm == 1 && /^tags:[[:space:]]*\[/ && !done { print repl; done = 1; next }
            { print }
        ' "$readme" > "$tmp" && mv "$tmp" "$readme"
    else
        awk -v repl="$newline" '
            NR == 1 && $0 == "---" { fm = 1; print; next }
            fm == 1 && /^status:/ && !done { print; print repl; done = 1; next }
            fm == 1 && $0 == "---" && !done { print repl; done = 1; fm = 2; print; next }
            fm == 1 && $0 == "---" { fm = 2; print; next }
            { print }
        ' "$readme" > "$tmp" && mv "$tmp" "$readme"
    fi
}

# True when an inline tags line exists in the frontmatter. The "found" branch
# sets a flag and falls through to END rather than calling `exit 0` directly:
# once an END block is present, POSIX awk lets END's own exit override any
# exit code set earlier in the main body, so a hardcoded `exit 0` here would
# always be clobbered by END's default. Routing through the flag keeps the
# real answer in the one place that has the last word.
_tags_read_line_exists() {
    local readme="$1"
    awk '
        NR == 1 && $0 != "---" { exit 1 }
        NR > 1 && $0 == "---" { exit 1 }
        /^tags:[[:space:]]*\[/ { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$readme" 2>/dev/null
}

# Valid tag: [a-z0-9._-]+, at most 32 chars. Caller lowercases first.
_tag_validate() {
    local tag="$1"
    [ ${#tag} -le 32 ] || return 1
    case "$tag" in
        ''|*[!a-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Resolve the README path for the ambient session, erroring outside one.
_tag_target_readme() {
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "In-session only; use 'cs <name> -tag ...' from outside a session"
    fi
    printf '%s/README.md' "$CLAUDE_SESSION_META_DIR"
}

_tag_mutate() {
    local op="$1"
    shift
    [ $# -gt 0 ] || error "Usage: cs -tag $op <tag>..."
    local readme
    readme=$(_tag_target_readme)
    [ -f "$readme" ] || error "No README frontmatter for this session: $readme"
    _tags_has_frontmatter "$readme" || error "Cannot edit $readme: no YAML frontmatter fence found (CRLF line endings also defeat it); cs edits only the inline 'tags: [...]' form"
    if _tags_has_block_style "$readme"; then
        error "Cannot edit $readme: its tags are a block-style YAML list; cs writes only the inline form 'tags: [a, b]'"
    fi
    local current
    current=$(_tags_read "$readme")
    local tag lower result=""
    if [ "$op" = "add" ]; then
        result="$current"
        for tag in "$@"; do
            lower=$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')
            _tag_validate "$lower" || error "Invalid tag '$tag': allowed a-z0-9._- (max 32 chars)"
            case "
$result
" in
                *"
$lower
"*) ;;  # already present — dedup
                *) result="${result:+$result
}$lower" ;;
            esac
        done
    else
        result="$current"
        for tag in "$@"; do
            lower=$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')
            result=$(printf '%s\n' "$result" | awk -v t="$lower" '$0 != t')
        done
    fi
    _tags_write "$readme" "$(printf '%s\n' "$result" | tr '\n' ' ')"
}

_tag_list_session() {
    local name="$1"
    local dir="$SESSIONS_ROOT/$name"
    [ -d "$dir" ] || [ -L "$dir" ] || error "No such session: $name"
    _tags_read "$dir/.cs/README.md"
}

run_tag() {
    local cmd="${1:-}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        add|rm) _tag_mutate "$cmd" "$@" ;;
        list|ls)
            if [ -n "${1:-}" ]; then
                _tag_list_session "$1"
            else
                _tag_list_all
            fi
            ;;
        *) error "Usage: cs -tag <add|rm|list> [args]. Run 'cs -help' for details." ;;
    esac
}

# Distinct tags across all sessions with usage counts (Task 2 wires -list --tag).
_tag_list_all() {
    [ -d "$SESSIONS_ROOT" ] || return 0
    local dir
    while IFS= read -r -d '' dir; do
        is_session_dir "$dir" || continue
        _tags_read "$dir/.cs/README.md"
    done < <(find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 2>/dev/null) \
        | sort | uniq -c | sort -rn | awk '{printf "%s (%s)\n", $2, $1}'
}
