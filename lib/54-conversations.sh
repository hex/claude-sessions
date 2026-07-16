# ABOUTME: cs -conversations: the session's conversation chain from timeline.jsonl.
# ABOUTME: Renders started/rotated events with lineage arrows in local time.

run_conversations() {
    [ $# -eq 0 ] || error "Usage: cs -conversations"
    if [ -z "${CLAUDE_SESSION_META_DIR:-}" ]; then
        error "cs -conversations must be run inside a cs session, or as: cs <session> -conversations"
    fi
    local timeline="$CLAUDE_SESSION_META_DIR/timeline.jsonl"
    if [ ! -s "$timeline" ]; then
        echo "No conversation history recorded."
        return 0
    fi
    local current
    current=$(_read_local_state "$CLAUDE_SESSION_META_DIR/local/state" claude_session_id)
    # One line per conversation's first started event (later starteds fold
    # into a resumed-count suffix); one line per rotated event. Torn or
    # foreign lines are skipped by the tolerant per-line parse.
    jq -rRs --arg current "$current" '
        [split("\n")[] | select(length > 0) | (fromjson? // empty)
         | select(.event == "started" or .event == "rotated")] as $ev |
        (reduce $ev[] as $e ({};
            if $e.event == "started"
            then .[$e.session_id] = (.[$e.session_id] // 0) + 1
            else . end)) as $n |
        (reduce $ev[] as $e ({seen: {}, out: []};
            if $e.event == "started" then
                if .seen[$e.session_id] then . else
                    .seen[$e.session_id] = true |
                    .out += [{ts: $e.ts,
                        txt: ($e.session_id[0:8] + "  started (" + ($e.source // "?")
                            + (if ($n[$e.session_id] // 1) > 1
                               then ", resumed " + (($n[$e.session_id] - 1) | tostring) + "x"
                               else "" end)
                            + ")"
                            + (if $current != "" and $e.session_id == $current
                               then "  [current]" else "" end))}]
                end
            else
                .out += [{ts: $e.ts,
                    txt: ((if ($e.from // "") == "" then "?" else $e.from[0:8] end)
                        + " > " + ($e.to[0:8]) + "  rotated (" + ($e.reason // "?")
                        + (if ($e.handoff // "") != "" then ": " + $e.handoff else "" end)
                        + ")")}]
            end)).out[] |
        ((try (.ts | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M")) catch .ts))
            + "  " + .txt
    ' "$timeline"
}
