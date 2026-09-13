#!/usr/bin/env bash
# ABOUTME: Deterministic front half of the /finish skill: session context, feature capture,
# ABOUTME: GitHub PR state, and the closing report. Mutation goes through cs, never here.
set -euo pipefail

usage() {
    echo "usage: finish.sh prepare [feature] | finish.sh report <base> <feature> <captured-sha>" >&2
    exit 2
}

session_dir="${CLAUDE_SESSION_DIR:-$PWD}"
# Never `dirname "$session_dir"`: an adopted session's CLAUDE_SESSION_DIR is
# the resolved project path, whose parent is not the sessions root. Same
# default write-as-me's build-corpus.sh uses.
sessions_root="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}"
session_name="${CLAUDE_SESSION_NAME:-$(basename "$session_dir")}"

for tool in git jq perl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

# One key from .cs/local/state; the format lib/40-state.sh writes.
state_get() {  # dir key
    [ -f "$1/.cs/local/state" ] || return 0
    awk -v key="$2" 'index($0, key ":") == 1 { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' \
        "$1/.cs/local/state" 2>/dev/null || true
}

# owner/repo when origin is GitHub (https, ssh, or scp-like); empty otherwise.
github_repo() {  # dir
    local url
    url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
    case "$url" in
        https://github.com/*|http://github.com/*|ssh://git@github.com/*|git@github.com:*) ;;
        *) return 0 ;;
    esac
    url="${url#*github.com}"
    url="${url#[:/]}"
    url="${url%.git}"
    url="${url%/}"
    printf '%s\n' "$url"
}

# gh with a 10 s ceiling. perl's alarm exists on every platform cs supports;
# GNU timeout does not.
gh_timed() {
    perl -e 'alarm 10; exec @ARGV or exit 127' -- gh "$@"
}

# PR state for a head branch, as pr_* lines. Three shapes only: none, a state
# with its fields, or unknown with a reason. A gh failure is never "none".
pr_lookup() {  # base_dir branch
    local repo owner json n err
    repo=$(github_repo "$1")
    if [ -z "$repo" ]; then
        echo "pr_state: skipped"
        echo "pr_reason: origin is not a GitHub remote"
        return 0
    fi
    owner="${repo%%/*}"
    if ! command -v gh >/dev/null 2>&1; then
        echo "pr_state: unknown"
        echo "pr_reason: gh is not installed"
        return 0
    fi
    err=$(mktemp "${TMPDIR:-/tmp}/finish-gh.XXXXXX")
    if ! json=$(gh_timed pr list --repo "$repo" --head "$2" --state all --limit 100 \
            --json number,state,url,mergeCommit,mergedAt,baseRefName,headRefOid,headRepositoryOwner,isCrossRepository 2>"$err"); then
        echo "pr_state: unknown"
        echo "pr_reason: gh pr list failed: $(head -c 200 "$err" | tr '\n' ' ')"
        rm -f "$err"
        return 0
    fi
    rm -f "$err"
    if ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "pr_state: unknown"
        echo "pr_reason: gh output was not a JSON array"
        return 0
    fi
    # A PR whose head repository is gone cannot be told from a fork's; refuse
    # to guess.
    if [ "$(printf '%s' "$json" | jq '[.[] | select(.headRepositoryOwner == null)] | length')" != 0 ]; then
        echo "pr_state: unknown"
        echo "pr_reason: a PR on $2 has no head repository (deleted fork?); inspect it on GitHub"
        return 0
    fi
    # A fork's same-named branch is not this PR.
    json=$(printf '%s' "$json" | jq -c --arg owner "$owner" \
        '[.[] | select(.headRepositoryOwner.login == $owner and .isCrossRepository == false)]')
    n=$(printf '%s' "$json" | jq 'length')
    if [ "$n" = 0 ]; then
        echo "pr_state: none"
        return 0
    fi
    # Selection policy. One MERGED (newest mergedAt when several, a re-opened
    # and re-merged branch) or one OPEN is a state. Two OPEN PRs, or a MERGED
    # PR beside an OPEN one (branch reused after a landing), cannot be told
    # apart from here: unknown, with the numbers, never a guess.
    local n_open n_merged
    n_open=$(printf '%s' "$json" | jq '[.[] | select(.state == "OPEN")] | length')
    n_merged=$(printf '%s' "$json" | jq '[.[] | select(.state == "MERGED")] | length')
    if [ "$n_open" -gt 1 ] || { [ "$n_open" -gt 0 ] && [ "$n_merged" -gt 0 ]; }; then
        echo "pr_state: unknown"
        echo "pr_reason: ambiguous — $(printf '%s' "$json" | jq -r '[.[] | "#\(.number) \(.state)"] | join(", ")') all have head $2; pick one on GitHub"
        return 0
    fi
    local merged open
    merged=$(printf '%s' "$json" | jq -c '[.[] | select(.state == "MERGED")] | sort_by(.mergedAt) | last // empty')
    if [ -n "$merged" ]; then
        echo "pr_state: MERGED"
        printf '%s' "$merged" | jq -r '"pr_number: \(.number)\npr_url: \(.url)\npr_merge_commit: \(.mergeCommit.oid // "")\npr_base_ref: \(.baseRefName)\npr_head_oid: \(.headRefOid)"'
        return 0
    fi
    open=$(printf '%s' "$json" | jq -c '[.[] | select(.state == "OPEN")] | first // empty')
    if [ -n "$open" ]; then
        echo "pr_state: OPEN"
        printf '%s' "$open" | jq -r '"pr_number: \(.number)\npr_url: \(.url)\npr_base_ref: \(.baseRefName)\npr_head_oid: \(.headRefOid)"'
        return 0
    fi
    echo "pr_state: CLOSED"
    printf '%s' "$json" | jq -r 'first | "pr_number: \(.number)\npr_url: \(.url)"'
}

# Everything uncommitted in the worktree, as porcelain lines, unfiltered. The
# retire verb's untracked filter (lib/30-worktree.sh _worktree_untracked_at_risk)
# is a REMOVAL-risk filter that drops records because retirement fuses them;
# integrate fuses nothing, so a new tracked-mode plan or memory file under
# .cs/ is exactly the dirt the user must hear about.
dirt_lines() {  # dir
    local dirt
    dirt=$(git -C "$1" status --porcelain 2>/dev/null || true)
    echo "dirt_count: $(printf '%s' "$dirt" | grep -c . || true)"
    [ -z "$dirt" ] || printf '%s\n' "$dirt" | sed 's/^/dirt: /'
}

cmd_prepare() {  # [feature]
    local feature="${1:-}" cs_base task_branch
    cs_base=$(state_get "$session_dir" cs_base)
    task_branch=$(state_get "$session_dir" task_branch)
    if [ -n "$task_branch" ] && [ -n "$cs_base" ]; then
        # A feature session: integrate mutates the base and runs only from the
        # base's own conversation. Hand off; nothing here changes.
        echo "role: feature"
        echo "base: $cs_base"
        echo "task: ${task_branch#cs/}"
        echo "handoff: run /finish ${task_branch#cs/} in session $cs_base"
        return 0
    fi
    echo "role: base"
    echo "base: $session_name"
    # A cs session has a .cs/ directory; an ordinary checkout does not. The
    # skill's plain-branch path (checkout + merge + branch -d) is only for the
    # latter — a cs base on a non-default branch must never enter it.
    if [ -d "$session_dir/.cs" ]; then echo "cs_session: yes"; else echo "cs_session: no"; fi
    echo "base_branch: $(git -C "$session_dir" symbolic-ref -q --short HEAD 2>/dev/null || echo detached)"
    if [ -z "$feature" ]; then
        echo "task: "
        return 0
    fi
    local task="$feature" wt="$sessions_root/$session_name@$feature"
    echo "task: $task"
    if [ ! -d "$wt" ]; then
        echo "error: no worktree at $wt"
        exit 1
    fi
    echo "worktree: $wt"
    local head_branch
    head_branch=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || echo detached)
    echo "branch: $head_branch"
    if [ "$head_branch" != "cs/$task" ]; then
        echo "error: worktree is on $head_branch, not cs/$task"
        exit 1
    fi
    echo "sha: $(git -C "$wt" rev-parse HEAD)"
    dirt_lines "$wt"
    pr_lookup "$session_dir" "cs/$task"
}

cmd_report() {  # base task sha
    local base="$1" task="$2" sha="$3" wt="$sessions_root/$1@$2"
    [ -d "$wt" ] || { echo "error: no worktree at $wt"; exit 1; }
    local landed="no"
    if git -C "$session_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        landed="yes"
    fi
    echo "landed: $landed"
    echo "base_head: $(git -C "$session_dir" rev-parse HEAD)"
    local tip n_after
    tip=$(git -C "$wt" rev-parse HEAD)
    n_after=$(git -C "$wt" rev-list --count "$sha..HEAD" 2>/dev/null || echo 0)
    echo "not_integrated: $n_after"
    dirt_lines "$wt"
    pr_lookup "$session_dir" "cs/$task"
    if [ "$landed" = "yes" ]; then
        # Retirement fuses the BRANCH, not the captured commit. A tip the base
        # does not have would arrive unreviewed and ungated through the retire
        # verb, so the advice is another /finish, not --merge.
        if ! git -C "$session_dir" merge-base --is-ancestor "$tip" HEAD 2>/dev/null; then
            echo "retire: $n_after commit(s) on cs/$task after the captured commit are not integrated; run /finish $task again before retiring"
        # Tracked-.cs mode: the integrate's timeline event dirties the base,
        # and the retire verb refuses dirt. Say so rather than let the verb's
        # refusal be the first the user hears of it.
        elif [ -n "$(git -C "$session_dir" status --porcelain -- .cs 2>/dev/null)" ]; then
            echo "retire: commit the session bookkeeping in $base (git status -- .cs), close the feature session, then: cs $base --merge $task"
        else
            echo "retire: close the feature session, then: cs $base --merge $task"
        fi
    else
        echo "retire: do NOT run cs $base --merge $task — cs/$task is not an ancestor of base (squash or rebase landing) and the verb will try to merge the branch again; continue on a new task and leave this worktree until the preservation-first retire spec ships"
    fi
}

case "${1:-}" in
    prepare) shift; cmd_prepare "$@" ;;
    report) [ $# -eq 4 ] || usage; cmd_report "$2" "$3" "$4" ;;
    *) usage ;;
esac
