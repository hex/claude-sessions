#!/usr/bin/env bash
# ABOUTME: Waits for GitHub Actions jobs and reports their completed verdicts.
# ABOUTME: Distinguishes failed commands from pending runs and failed jobs.

set -euo pipefail

_usage() {
    echo 'usage: bash tests/ci_wait.sh <run-id> [--max-reruns N] [--since <rev>]' >&2
    exit 2
}

[ "$#" -ge 1 ] || _usage
run_id="$1"
case "$run_id" in '' | *[!0-9]*) _usage ;; esac
shift
max_reruns=3
while [ "$#" -gt 0 ]; do
    case "$1" in
        --max-reruns)
            [ "$#" -ge 2 ] || _usage
            case "$2" in '' | *[!0-9]* | ??????????*) _usage ;; esac
            max_reruns=$((10#$2))
            shift 2
            ;;
        *) _usage ;;
    esac
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/ci_wait.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

_gh() {
    if ! gh "$@" > "$scratch/response" 2> "$scratch/error"; then
        printf 'ci_wait: gh %s failed: "%s"\n' "$*" "$(cat "$scratch/error")" >&2
        exit 4
    fi
}

_report_skips() {
    _gh run view "$run_id" --log
    jq -Rn '
        reduce inputs as $line ({};
            ($line | capture("^(?<job>[^\\t]+)\\t[^\\t]*\\t[^ ]+ (?<text>.*)$") // null) as $entry |
            if $entry == null then .
            elif $entry.text == "skipped tests:" then
                .[$entry.job] = {job:$entry.job, lines:[], active:true}
            elif .[$entry.job].active then
                if $entry.text == "" then .[$entry.job].active = false
                else .[$entry.job].lines += [$entry.text]
                end
            else .
            end
        ) | [.[] | del(.active)]
    ' "$scratch/response" > "$scratch/skips"
    jq -r '
        if length == 0 then "skipped tests: none"
        else .[] | "skipped tests (\(.job)):", .lines[]
        end
    ' "$scratch/skips"
}

last_wait=''
reruns=0
rerun_attempt=0
while :; do
    _gh run view "$run_id" --json status,attempt,headSha,jobs
    if ! jq -e '
        (.status | type == "string") and
        (.attempt | type == "number") and
        (.headSha | type == "string") and
        (.jobs | type == "array") and
        all(.jobs[];
            (.name | type == "string") and
            (.conclusion | type == "string") and
            (.steps | type == "array"))
    ' "$scratch/response" > /dev/null 2> "$scratch/error"; then
        printf 'ci_wait: invalid run JSON from gh run view %s: "%s"\n' "$run_id" "$(cat "$scratch/error")" >&2
        exit 4
    fi
    status=$(jq -r '.status' "$scratch/response")
    attempt=$(jq -r '.attempt' "$scratch/response")
    if [ "$attempt" -le "$rerun_attempt" ]; then
        sleep "${CI_WAIT_INTERVAL:-30}"
        continue
    fi
    pending=$(jq '[.jobs[] | select(.conclusion == "")] | length' "$scratch/response")
    total=$(jq '.jobs | length' "$scratch/response")
    if [ "$status" != completed ] || [ "$pending" -gt 0 ]; then
        waiting="waiting: $pending of $total jobs pending (attempt $attempt)"
        if [ "$waiting" != "$last_wait" ]; then
            printf '%s\n' "$waiting"
            last_wait="$waiting"
        fi
        sleep "${CI_WAIT_INTERVAL:-30}"
        continue
    fi
    jq -r '.jobs[] | [.conclusion, (.steps | length), .name] | @tsv' "$scratch/response"
    if jq -e '(.jobs | length > 0) and all(.jobs[]; .conclusion == "success")' "$scratch/response" > /dev/null; then
        _report_skips
        exit 0
    fi
    if jq -e '
        any(.jobs[]; .conclusion == "cancelled" and (.steps | length == 0)) and
        all(.jobs[]; .conclusion == "success" or
            ((.conclusion == "cancelled" or .conclusion == "skipped") and (.steps | length == 0)))
    ' "$scratch/response" > /dev/null; then
        [ "$reruns" -lt "$max_reruns" ] || exit 3
        reruns=$((reruns + 1))
        rerun_attempt="$attempt"
        printf 'infrastructure: rerunning failed jobs (%s of %s)\n' "$reruns" "$max_reruns"
        _gh run rerun "$run_id" --failed
        continue
    fi
    exit 1
done
