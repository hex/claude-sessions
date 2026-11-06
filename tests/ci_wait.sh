#!/usr/bin/env bash
# ABOUTME: Waits for GitHub Actions jobs and reports their completed verdicts.
# ABOUTME: Distinguishes failed commands from pending runs and failed jobs.

set -euo pipefail

_usage() {
    echo 'usage: bash tests/ci_wait.sh <run-id> [--max-reruns N] [--since <rev>]' >&2
    exit 2
}

[ "$#" -eq 1 ] || _usage
run_id="$1"
case "$run_id" in '' | *[!0-9]*) _usage ;; esac

scratch=$(mktemp -d "${TMPDIR:-/tmp}/ci_wait.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

_gh() {
    if ! gh "$@" > "$scratch/response" 2> "$scratch/error"; then
        printf 'ci_wait: gh %s failed: "%s"\n' "$*" "$(cat "$scratch/error")" >&2
        exit 4
    fi
}

last_wait=''
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
        exit 0
    fi
    exit 1
done
