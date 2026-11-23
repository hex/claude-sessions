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

# gh with a 10 s ceiling. perl's alarm and fork exist on every platform cs
# supports; GNU timeout does not. The alarm has to reach a forked child: a
# bare `alarm; exec` replaces the perl process, taking the pending alarm's
# handler with it, and the ceiling never fires. Exits 143 on the kill.
gh_timed() {
    perl -e '$p=fork; exec @ARGV or exit 127 unless $p; $SIG{ALRM}=sub{kill TERM,$p}; alarm 10; waitpid $p,0; exit(($?&127)?128+($?&127):$?>>8)' -- gh "$@"
}

# One word for the checks of the commit the PR landed as, so the skill can
# decide whether that commit is vouched for. The PR's own rollup describes its
# head, and a merge commit with newer base changes is a tree the head's checks
# never ran on, so the fold reads the landing commit's check runs and commit
# statuses: a check run carries a conclusion (null while it runs), a status a
# state; nothing at all is "none", never "success"; a gh failure is "unknown"
# with the reason, never a guess.
landing_checks() {  # repo sha
    local err runs statuses status=0
    err=$(mktemp "${TMPDIR:-/tmp}/finish-gh.XXXXXX")
    # Both lists page at 30; a red context on page two must not hide behind
    # thirty green ones on page one.
    runs=$(gh_timed api --paginate "repos/$1/commits/$2/check-runs" --jq '.check_runs[] | .conclusion // "PENDING"' 2>"$err") || status=$?
    if [ "$status" = 0 ]; then
        statuses=$(gh_timed api --paginate "repos/$1/commits/$2/status" --jq '.statuses[] | .state' 2>"$err") || status=$?
    fi
    if [ "$status" != 0 ]; then
        echo "pr_checks: unknown"
        # A killed child says nothing on stderr; the ceiling is the diagnosis.
        if [ "$status" = 143 ] || [ "$status" = 142 ]; then
            echo "pr_checks_reason: gh timed out after 10 s reading the checks of $2"
        else
            echo "pr_checks_reason: gh api failed reading the checks of $2: $(head -c 200 "$err" | tr '\n' ' ')"
        fi
        rm -f "$err"; return 0
    fi
    rm -f "$err"
    printf 'pr_checks: %s\n' "$(printf '%s\n%s\n' "$runs" "$statuses" | jq -R -s '
        [split("\n")[] | select(. != "") | ascii_upcase] as $v
        | if ($v | length) == 0 then "none"
          elif ($v | any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STALE" or . == "STARTUP_FAILURE")) then "failure"
          elif ($v | all(. == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL"))
            then (if ($v | any(. == "SUCCESS")) then "success" else "none" end)
          else "pending" end' -r)"
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
    local gh_status=0
    json=$(gh_timed pr list --repo "$repo" --head "$2" --state all --limit 100 \
            --json number,state,url,mergeCommit,mergedAt,baseRefName,headRefOid,headRepositoryOwner,isCrossRepository 2>"$err") \
        || gh_status=$?
    if [ "$gh_status" != 0 ]; then
        echo "pr_state: unknown"
        # A killed child says nothing on stderr; the ceiling is the diagnosis.
        if [ "$gh_status" = 143 ] || [ "$gh_status" = 142 ]; then
            echo "pr_reason: gh timed out after 10 s"
        else
            echo "pr_reason: gh pr list failed: $(head -c 200 "$err" | tr '\n' ' ')"
        fi
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
    # Every field the filter and the selection policy read must be present and
    # the right shape. A record missing one silently falls out of the filter
    # below and would be reported as "no PR" — the one answer that must never
    # be a guess.
    local malformed
    malformed=$(printf '%s' "$json" | jq -r '
        [ .[]
          | select( ( (.state == "OPEN" or .state == "MERGED" or .state == "CLOSED")
                      and (.headRepositoryOwner | type) == "object"
                      and (.headRepositoryOwner.login | type) == "string"
                      and (.isCrossRepository | type) == "boolean" ) | not )
          | "#\(.number // "?")" ] | join(", ")')
    if [ -n "$malformed" ]; then
        echo "pr_state: unknown"
        echo "pr_reason: gh returned a PR record with missing or malformed fields ($malformed)"
        return 0
    fi
    # A fork's same-named branch is not this PR. GitHub logins are
    # case-insensitive and origin's URL carries whatever case was typed.
    json=$(printf '%s' "$json" | jq -c --arg owner "$owner" \
        '[.[] | select((.headRepositoryOwner.login | ascii_downcase) == ($owner | ascii_downcase) and .isCrossRepository == false)]')
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
        # pr_merge_commit is the PR path's input to cs; without it there is
        # nothing to integrate and the skill must not proceed on a blank.
        if [ -z "$(printf '%s' "$merged" | jq -r '.mergeCommit.oid // ""')" ]; then
            echo "pr_state: unknown"
            echo "pr_reason: PR $(printf '%s' "$merged" | jq -r '"#\(.number)"') is MERGED with no merge commit recorded; inspect it on GitHub"
            return 0
        fi
        echo "pr_state: MERGED"
        printf '%s' "$merged" | jq -r '"pr_number: \(.number)\npr_url: \(.url)\npr_merge_commit: \(.mergeCommit.oid // "")\npr_base_ref: \(.baseRefName)\npr_head_oid: \(.headRefOid)"'
        landing_checks "$repo" "$(printf '%s' "$merged" | jq -r '.mergeCommit.oid')"
        return 0
    fi
    open=$(printf '%s' "$json" | jq -c '[.[] | select(.state == "OPEN")] | first // empty')
    if [ -n "$open" ]; then
        echo "pr_state: OPEN"
        printf '%s' "$open" | jq -r '"pr_number: \(.number)\npr_url: \(.url)\npr_base_ref: \(.baseRefName)\npr_head_oid: \(.headRefOid)"'
        return 0
    fi
    # CLOSED is stated, never inferred from "neither OPEN nor MERGED".
    if [ "$(printf '%s' "$json" | jq '[.[] | select(.state == "CLOSED")] | length')" != "$n" ]; then
        echo "pr_state: unknown"
        echo "pr_reason: gh returned a PR state this script does not classify: $(printf '%s' "$json" | jq -r '[.[] | "#\(.number) \(.state)"] | join(", ")')"
        return 0
    fi
    echo "pr_state: CLOSED"
    printf '%s' "$json" | jq -r 'first | "pr_number: \(.number)\npr_url: \(.url)"'
}

# Everything uncommitted in the worktree, as porcelain lines, unfiltered.
# Integrate carries no uncommitted work, so every path here stays out of what
# lands; the retire then fuses the .cs records among them into the base's
# working tree, uncommitted, and refuses over the rest.
dirt_lines() {  # dir
    local dirt
    dirt=$(git -C "$1" status --porcelain 2>/dev/null || true)
    echo "dirt_count: $(printf '%s' "$dirt" | grep -c . || true)"
    [ -z "$dirt" ] || printf '%s\n' "$dirt" | sed 's/^/dirt: /'
}

# What the integrate and the retire will make of the feature, read from the
# record cs's features screen prints for it (cs <base> -features --porcelain:
# task branch ahead merged ff wt_dirty untracked base_dirty lock state), so
# this script holds no copy of cs's rules. base_dirty is the integrate's
# refusal over the base; feature_dirty and feature_untracked are the retire's
# over the worktree, counted whatever lock the state word names first.
# cs is the one that launched this conversation (CS_BIN), else the one on
# PATH, else where install.sh puts it. Without an answer the state is
# "unknown" with the reason, never "ready".
readiness_lines() {  # base task
    local cs="${CS_BIN:-}" err records fields status=0
    [ -n "$cs" ] || cs=$(command -v cs 2>/dev/null || true)
    [ -n "$cs" ] || [ ! -x "$HOME/.local/bin/cs" ] || cs="$HOME/.local/bin/cs"
    if [ -z "$cs" ]; then
        echo "feature_state: unknown"
        echo "feature_state_reason: no cs found (CS_BIN, PATH, ~/.local/bin/cs), so the feature's readiness was not read"
        return 0
    fi
    err=$(mktemp "${TMPDIR:-/tmp}/finish-cs.XXXXXX")
    records=$("$cs" "$1" -features --porcelain 2>"$err") || status=$?
    if [ "$status" != 0 ]; then
        echo "feature_state: unknown"
        echo "feature_state_reason: $cs $1 -features --porcelain failed (exit $status): $(head -c 200 "$err" | tr '\n' ' ')"
        rm -f "$err"
        return 0
    fi
    rm -f "$err"
    fields=$(printf '%s\n' "$records" | awk -F'\t' -v task="$2" '
        $1 == task && NF == 10 {
            printf "feature_dirty: %s\nfeature_untracked: %s\nbase_dirty: %s\nfeature_state: %s\n", $6, $7, $8, $10
            found = 1
            exit
        }
        END { exit !found }') || fields=""
    if [ -z "$fields" ]; then
        echo "feature_state: unknown"
        echo "feature_state_reason: $cs $1 -features --porcelain printed no ten-field record for $2"
        return 0
    fi
    printf '%s\n' "$fields"
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
    readiness_lines "$session_name" "$task"
    pr_lookup "$session_dir" "cs/$task"
}

# Whether the content of a branch that is not an ancestor of the base landed
# anyway (a squash or rebase landing, a cherry-pick): every path <sha> changed
# since its merge base with <base_head>, the base's HEAD as the report printed
# it, must be the same on <base_head>,
# the same mode and blob or absent from both. A rename is a deletion and an
# addition, both checked. A submodule's pointer counts whatever .gitmodules or
# diff.ignoreSubmodules says, since the branch may be the one ref holding it.
# Prints content_paths_checked and, one per line, content_differs for each
# path <base_head> holds differently. The local HEAD is the
# evidence, not origin's branch: the retire acts on this base, the PR path has
# already fast-forwarded it onto the landing, and origin may have moved since.
content_landing() {  # sha base_head
    local top mb tmp status=0
    top=$(git -C "$session_dir" rev-parse --show-toplevel) \
        || { echo "error: $session_dir is not a git checkout"; return 1; }
    # No merge base: the branch shares no history with the base, so there is
    # no "what the branch changed" to check.
    mb=$(git -C "$top" merge-base "$1" "$2" 2>/dev/null) || { echo "content_paths_checked: none"; return 0; }
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/finish-paths.XXXXXX") \
        || { echo "error: could not create a temporary directory to compare paths in"; return 1; }
    git -C "$top" diff --no-renames --ignore-submodules=none --name-only -z "$mb" "$1" > "$tmp/changed" \
        || { rm -rf "$tmp"; echo "error: git diff failed listing the paths $1 changed since $mb"; return 1; }
    # Every path <base_head> holds differently from <sha>, over the whole tree,
    # so no path list goes on a command line (ARG_MAX). <base_head>, never
    # HEAD: a base commit while this runs must not change what is listed. Listed twice: NUL-separated
    # to match against the changed paths, and as git quotes names to print
    # them. git lists both in the same order. -C0: names are bytes, whatever
    # PERL_UNICODE says.
    git -C "$top" diff --no-renames --ignore-submodules=none --name-only -z "$1" "$2" > "$tmp/differ" \
        && git -C "$top" diff --no-renames --ignore-submodules=none --name-only "$1" "$2" > "$tmp/named" \
        || { rm -rf "$tmp"; echo "error: git diff failed comparing $1 with base HEAD"; return 1; }
    perl -C0 -e '
        my ($changed_file, $differ_file, $named_file) = @ARGV;
        my (%changed, @differ, @named);
        {
            local $/ = "\0";
            open(my $c, "<", $changed_file) or die "error: cannot read $changed_file: $!\n";
            while (my $p = <$c>) { chomp $p; $changed{$p} = 1 }
            open(my $d, "<", $differ_file) or die "error: cannot read $differ_file: $!\n";
            @differ = <$d>;
            chomp @differ;
        }
        open(my $n, "<", $named_file) or die "error: cannot read $named_file: $!\n";
        @named = <$n>;
        chomp @named;
        if (@differ != @named) {
            printf "error: git listed %d paths that differ from base HEAD NUL-separated but %d quoted\n",
                scalar @differ, scalar @named;
            exit 1;
        }
        printf "content_paths_checked: %d\n", scalar keys %changed;
        for my $i (0 .. $#differ) { print "content_differs: $named[$i]\n" if $changed{$differ[$i]} }
    ' "$tmp/changed" "$tmp/differ" "$tmp/named" || status=$?
    rm -rf "$tmp"
    return "$status"
}

cmd_report() {  # base task sha
    local base="$1" task="$2" sha="$3" wt="$sessions_root/$1@$2"
    [ -d "$wt" ] || { echo "error: no worktree at $wt"; exit 1; }
    local landed="no"
    if git -C "$session_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        landed="yes"
    fi
    echo "landed: $landed"
    local base_head
    base_head=$(git -C "$session_dir" rev-parse HEAD) \
        || { echo "error: git rev-parse HEAD failed in the base $session_dir"; exit 1; }
    echo "base_head: $base_head"
    local tip n_after
    tip=$(git -C "$wt" rev-parse HEAD) || { echo "error: git rev-parse HEAD failed in the worktree $wt"; exit 1; }
    n_after=$(git -C "$wt" rev-list --count "$sha..HEAD" 2>/dev/null || echo 0)
    echo "not_integrated: $n_after"
    dirt_lines "$wt"
    pr_lookup "$session_dir" "cs/$task"
    # What the retire entry will do with this worktree. It removes the
    # worktree and branch and never merges, so a tip the base does not have
    # is another /finish first. A branch that is not an ancestor (a squash or
    # rebase landing) is retirable when the base holds every path it changed
    # as it has it, or else only on the PR's own evidence.
    local not_integrated="retire: $n_after commit(s) on cs/$task after the captured commit are not integrated; run /finish $task again before retiring"
    if [ "$landed" = "yes" ]; then
        if git -C "$session_dir" merge-base --is-ancestor "$tip" HEAD 2>/dev/null; then
            echo "retire: ready"
        else
            echo "$not_integrated"
        fi
        return 0
    fi
    local content checked differing n_differing status=0
    # Run captured, so its error line comes back here to print. Path names
    # are bytes in any encoding (core.quotePath false prints them raw), so
    # every sed and grep over them runs in the C locale.
    content=$(content_landing "$sha" "$base_head") || status=$?
    if [ "$status" != 0 ]; then
        printf '%s\n' "$content" | grep '^error: ' \
            || echo "error: comparing the paths cs/$task changed with base HEAD failed (exit $status)"
        exit 1
    fi
    checked=$(printf '%s\n' "$content" | LC_ALL=C sed -n 's/^content_paths_checked: //p')
    # A check that counted nothing vouches for nothing.
    case "$checked" in
        none) ;;
        ''|*[!0-9]*)
            echo "error: comparing the paths cs/$task changed with base HEAD gave '$checked' as the path count, not none or a number"
            exit 1 ;;
    esac
    differing=$(printf '%s\n' "$content" | LC_ALL=C sed -n 's/^content_differs: //p')
    if [ "$checked" != none ] && [ -z "$differing" ]; then
        # The entry refuses a tip past the captured commit under --force too.
        if [ "$n_after" != 0 ]; then
            echo "$not_integrated"
            return 0
        fi
        echo "retire: content-landed"
        echo "retire_paths_checked: $checked"
        echo "retire_note: cs/$task is not an ancestor of base, but every path it changed is identical on base HEAD; retire with --force"
        return 0
    fi
    echo "retire: not-landed"
    echo "retire_note: cs/$task is not an ancestor of base (a squash or rebase landing); retire with --force only on a MERGED pr_state"
    if [ -n "$differing" ]; then
        n_differing=$(printf '%s\n' "$differing" | LC_ALL=C grep -c .)
        echo "retire_paths_differing: $n_differing of $checked"
        printf '%s\n' "$differing" | LC_ALL=C sed -n '1,10s/^/retire_differs: /p'
        [ "$n_differing" -le 10 ] || echo "retire_differs_more: $((n_differing - 10))"
    fi
}

case "${1:-}" in
    prepare) shift; cmd_prepare "$@" ;;
    report) [ $# -eq 4 ] || usage; cmd_report "$2" "$3" "$4" ;;
    *) usage ;;
esac
