# ABOUTME: cs -usage: per-session token attribution over the 5-hour and weekly
# ABOUTME: rate-limit windows, computed on demand from Claude Code transcripts.

# Epoch seconds -> ISO-8601 UTC without timezone suffix, so it lexicographically
# lower-bounds transcript timestamps like 2026-07-14T12:42:40.123Z within the
# same second. BSD date first, GNU fallback.
_usage_epoch_to_iso() {
    date -u -r "$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
        || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null
}

# Humanize a token count: 999 -> 999, 1500 -> 1.5K, 2036303 -> 2.0M.
_usage_fmt() {
    awk -v n="${1:-0}" 'BEGIN {
        if (n >= 1000000) printf "%.1fM", n/1000000
        else if (n >= 1000) printf "%.1fK", n/1000
        else printf "%d", n
    }'
}

# Scan transcript files: dedup usage lines by requestId (streamed responses
# repeat message.usage once per content block), then sum token components per
# window. Windows are [boundary, now]; an empty boundary skips that window.
# Args: five_start_iso week_start_iso file...
# Output: "in5 cc5 out5 inW ccW outW inL ccL outL model" (model: last seen, or -)
_usage_scan() {
    local w5="$1" wk="$2"
    shift 2
    [ $# -gt 0 ] || { echo "0 0 0 0 0 0 0 0 0 -"; return 0; }
    jq -r 'select(.type == "assistant" and (.message.usage? != null)) |
        [ (.timestamp // ""),
          (.requestId // .message.id // .uuid // ""),
          (.message.usage.input_tokens // 0),
          (.message.usage.cache_creation_input_tokens // 0),
          (.message.usage.output_tokens // 0),
          (.message.model // "") ] | @tsv' "$@" 2>/dev/null \
    | awk -F'\t' -v w5="$w5" -v wk="$wk" '
        seen[$2]++ { next }
        {
            if ($6 != "") model = $6
            inL += $3; ccL += $4; outL += $5
            if (w5 != "" && $1 >= w5) { in5 += $3; cc5 += $4; out5 += $5 }
            if (wk != "" && $1 >= wk) { inW += $3; ccW += $4; outW += $5 }
        }
        END {
            if (model == "") model = "-"
            printf "%d %d %d %d %d %d %d %d %d %s\n", \
                in5, cc5, out5, inW, ccW, outW, inL, ccL, outL, model
        }'
}

# List transcript files for a session dir worth parsing for the window table:
# top-level conversations plus per-conversation subagent transcripts, skipping
# files untouched for 8+ days (they cannot contribute to either window).
# One path per line on stdout.
_usage_window_files() {
    local proj="$1"
    [ -d "$proj" ] || return 0
    find "$proj" -maxdepth 2 -name '*.jsonl' -mtime -8 2>/dev/null
}

# Render "IN / OUT" with humanized numbers, or "-" when both are zero.
_usage_cell() {
    local in_sum="$1" out_sum="$2"
    if [ "$in_sum" -eq 0 ] && [ "$out_sum" -eq 0 ]; then
        printf -- '-'
    else
        printf '%s / %s' "$(_usage_fmt "$in_sum")" "$(_usage_fmt "$out_sum")"
    fi
}

# Newest rate-limit stamp across all sessions (account limits are global, so
# the freshest statusline render wins). Sets globals rather than printing:
# callers need multiple values and command substitution runs in a subshell.
_usage_read_limits() {
    U_5H_PCT=""; U_5H_RESET=""; U_WK_PCT=""; U_WK_RESET=""; U_STAMP=0
    local f stamp
    for f in "$SESSIONS_ROOT"/*/.cs/local/limits; do
        [ -f "$f" ] || continue
        stamp=$(_read_local_state "$f" stamped_at)
        case "$stamp" in ''|*[!0-9]*) continue ;; esac
        if [ "$stamp" -gt "$U_STAMP" ]; then
            U_STAMP=$stamp
            U_5H_PCT=$(_read_local_state "$f" five_hour_used_pct)
            U_5H_RESET=$(_read_local_state "$f" five_hour_resets_at)
            U_WK_PCT=$(_read_local_state "$f" seven_day_used_pct)
            U_WK_RESET=$(_read_local_state "$f" seven_day_resets_at)
        fi
    done
}

# Epoch -> local HH:MM for the header's reset display.
_usage_epoch_to_hhmm() {
    date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null
}

run_usage() {
    local now start5 startw w5_iso wk_iso
    now=$(date +%s)
    _usage_read_limits
    start5=$((now - 18000))
    startw=$((now - 604800))
    local header="Rate limits: unknown (statusline not running); windows are rolling"
    if [ "$U_STAMP" -gt 0 ]; then
        case "$U_5H_RESET" in *[!0-9]*|'') ;; *) start5=$((U_5H_RESET - 18000)) ;; esac
        case "$U_WK_RESET" in *[!0-9]*|'') ;; *) startw=$((U_WK_RESET - 604800)) ;; esac
        header="Rate limits: 5h ${U_5H_PCT:-?}%"
        case "$U_5H_RESET" in *[!0-9]*|'') ;; *) header="$header (resets $(_usage_epoch_to_hhmm "$U_5H_RESET"))" ;; esac
        header="$header · week ${U_WK_PCT:-?}%"
    fi
    w5_iso=$(_usage_epoch_to_iso "$start5")
    wk_iso=$(_usage_epoch_to_iso "$startw")

    echo "$header"
    echo ""

    local shown=0 dir name proj sums
    local in5 cc5 out5 inW ccW outW rest
    printf '%-24s  %-15s  %-15s  %s\n' "SESSION" "5H IN/OUT" "WEEK IN/OUT" "LAST ACTIVE"
    while IFS= read -r -d '' dir; do
        is_session_dir "$dir" || continue
        name=$(basename "$dir")
        proj=$(_claude_project_dir "$dir")
        local files
        files=$(_usage_window_files "$proj")
        [ -n "$files" ] || continue
        local old_ifs="$IFS"
        IFS=$'\n'
        # shellcheck disable=SC2086
        set -- $files
        IFS="$old_ifs"
        sums=$(_usage_scan "$w5_iso" "$wk_iso" "$@")
        read -r in5 cc5 out5 inW ccW outW rest <<EOF
$sums
EOF
        [ $((in5 + cc5 + out5 + inW + ccW + outW)) -gt 0 ] || continue
        shown=$((shown + 1))
        printf '%-24s  %-15s  %-15s  %s\n' \
            "$name" \
            "$(_usage_cell $((in5 + cc5)) "$out5")" \
            "$(_usage_cell $((inW + ccW)) "$outW")" \
            "-"
    done < <(find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 2>/dev/null | sort -z)

    if [ "$shown" -eq 0 ]; then
        echo "No usage in the current windows."
    fi
}
