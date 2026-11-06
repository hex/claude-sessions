#!/usr/bin/env bash
# ABOUTME: Waits for GitHub Actions jobs and reports their completed verdicts.
# ABOUTME: Distinguishes failed commands from pending runs and failed jobs.

set -euo pipefail

_usage() {
    echo 'usage: bash tests/ci_wait.sh <run-id> [--max-reruns N] [--since <rev>]' >&2
    if [ "$#" -gt 0 ]; then printf '%s\n' "$1" >&2; fi
    exit 2
}

[ "$#" -ge 1 ] || _usage
run_id="$1"
case "$run_id" in '' | *[!0-9]*) _usage ;; esac
shift
max_reruns=3
since=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --max-reruns)
            [ "$#" -ge 2 ] || _usage
            case "$2" in '' | *[!0-9]* | ??????????*) _usage ;; esac
            max_reruns=$((10#$2))
            shift 2
            ;;
        --since)
            [ "$#" -ge 2 ] || _usage
            [ -n "$2" ] || _usage
            since="$2"
            shift 2
            ;;
        *) _usage ;;
    esac
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/ci_wait.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
repo_root=$(git rev-parse --show-toplevel) || exit 4
base_sha=''
if [ -n "$since" ]; then
    if ! base_sha=$(git -C "$repo_root" rev-parse --verify --end-of-options "$since^{commit}" 2> "$scratch/error"); then
        _usage "ci_wait: cannot resolve revision \"$since\": \"$(cat "$scratch/error")\""
    fi
fi

_gh() {
    if ! gh "$@" > "$scratch/response" 2> "$scratch/error"; then
        printf 'ci_wait: gh %s failed: "%s"\n' "$*" "$(cat "$scratch/error")" >&2
        exit 4
    fi
}

_report_skips() {
    local missing_job
    jq '[.jobs[].name]' "$scratch/response" > "$scratch/jobs"
    _gh run view "$run_id" --log
    jq -Rn '
        reduce inputs as $line ({};
            ($line | sub("\r$"; "") |
                capture("^(?<job>[^\\t]+)\\t[^\\t]*\\t[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+ (?<text>.*)$") // null) as $entry |
            if $entry == null then .
            else
                .[$entry.job] //= {job:$entry.job, phase:"outside", candidate:[], lines:null} |
                if $entry.text == "skipped tests:" then
                    .[$entry.job].phase = "lines" | .[$entry.job].candidate = []
                elif .[$entry.job].phase == "lines" then
                    if $entry.text == "" then .[$entry.job].phase = "rule"
                    else .[$entry.job].candidate += [$entry.text]
                    end
                elif .[$entry.job].phase == "rule" then
                    if $entry.text == "================================================================" then
                        .[$entry.job].lines = .[$entry.job].candidate
                    else . end |
                    .[$entry.job].phase = "outside"
                else .
                end
            end
        )
    ' "$scratch/response" > "$scratch/job-logs"
    missing_job=$(jq -r --slurpfile jobs "$scratch/jobs" '
        [$jobs[0][] as $job | select(.[$job] == null) | $job][0] // empty
    ' "$scratch/job-logs")
    if [ -n "$missing_job" ]; then
        printf 'ci_wait: log has no lines for job %s\n' "$missing_job" >&2
        exit 4
    fi
    jq '[.[] | select(.lines != null) | {job, lines}]' "$scratch/job-logs" > "$scratch/skips"
    jq -r '
        if length == 0 then "skipped tests: none"
        else .[] | "skipped tests (\(.job)):", .lines[]
        end
    ' "$scratch/skips"
}

_registered_names() {
    awk '/^run_test[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]|$)/ { print $2 }' "$1" | LC_ALL=C sort -u
}

_check_added_skips() {
    local path base_entry
    git -C "$repo_root" ls-tree -r --name-only -z "$head_sha" -- tests > "$scratch/paths" || return 4
    : > "$scratch/added-lines"
    while IFS= read -r -d '' path; do
        case "$path" in tests/test_*.sh) ;; *) continue ;; esac
        git -C "$repo_root" show "$head_sha:$path" > "$scratch/head-source" || return 4
        : > "$scratch/base-source"
        base_entry=$(git -C "$repo_root" ls-tree "$base_sha" -- "$path") || return 4
        if [ -n "$base_entry" ]; then
            git -C "$repo_root" show "$base_sha:$path" > "$scratch/base-source" || return 4
        fi
        _registered_names "$scratch/head-source" > "$scratch/head-names"
        _registered_names "$scratch/base-source" > "$scratch/base-names"
        LC_ALL=C comm -23 "$scratch/head-names" "$scratch/base-names" |
            awk -v suite="${path##*/}" '{ print suite "\t" $0 }' >> "$scratch/added-lines"
    done < "$scratch/paths"
    jq -Rn '[inputs | split("\t") | {suite:.[0], name:.[1]}]' "$scratch/added-lines" > "$scratch/added"
    jq --slurpfile added "$scratch/added" '
        [.[] as $block | $block.lines[] |
            capture("^  (?<suite>[^:]+\\.sh): (?<name>[A-Za-z_][A-Za-z0-9_]*)(?: \\(.*\\))?$") |
            . as $test |
            select(any($added[0][]; .suite == $test.suite and .name == $test.name)) |
            "  \(.suite): \(.name) (\($block.job))"] | unique
    ' "$scratch/skips" > "$scratch/added-skips"
    if jq -e 'length > 0' "$scratch/added-skips" > /dev/null; then
        printf 'skipped tests added since %s:\n' "$since"
        jq -r '.[]' "$scratch/added-skips"
        exit 5
    fi
}

last_wait=''
reruns=0
rerun_attempt=0
stale_reads=0
head_sha=''
while :; do
    _gh run view "$run_id" --json status,attempt,headSha,jobs
    if ! jq -e '
        (.status | type == "string") and
        (.attempt | type == "number" and . >= 1 and . == floor) and
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
    if [ -z "$head_sha" ]; then
        run_head=$(jq -r '.headSha' "$scratch/response")
        if ! head_sha=$(git -C "$repo_root" rev-parse --verify --end-of-options "$run_head^{commit}" 2> /dev/null); then
            printf 'ci_wait: run head %s is not in this clone; git fetch and run again\n' "$run_head" >&2
            exit 4
        fi
    fi
    status=$(jq -r '.status' "$scratch/response")
    attempt=$(jq -r '.attempt' "$scratch/response")
    if [ "$attempt" -le "$rerun_attempt" ]; then
        stale_reads=$((stale_reads + 1))
        if [ "$stale_reads" -eq 1 ]; then
            printf 'waiting: rerun requested, attempt %s not started yet\n' "$((rerun_attempt + 1))"
        fi
        if [ "$stale_reads" -gt 20 ]; then
            printf 'ci_wait: attempt never rose past %s after the rerun\n' "$rerun_attempt" >&2
            exit 4
        fi
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
        if [ -n "$since" ]; then
            _check_added_skips
        fi
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
        stale_reads=0
        printf 'infrastructure: rerunning failed jobs (%s of %s)\n' "$reruns" "$max_reruns"
        _gh run rerun "$run_id" --failed
        continue
    fi
    exit 1
done
