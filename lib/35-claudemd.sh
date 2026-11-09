# ABOUTME: Auto-memory setup, per-actor narrative files, and the session CLAUDE.md template.
# ABOUTME: Seeds and maintains a session's documentation scaffolding.

setup_auto_memory() {
    local session_dir="$1"
    mkdir -p "$session_dir/.cs"/{memory,plans}
    # Merge cs settings into settings.local.json (don't overwrite user's other settings)
    # autoMemoryDirectory requires absolute paths; plansDirectory supports relative paths
    local settings_file="$session_dir/.claude/settings.local.json"
    local memory_path="$session_dir/.cs/memory"
    mkdir -p "$session_dir/.claude"
    if [ -f "$settings_file" ] && command -v jq >/dev/null 2>&1; then
        # Write through a temp file: redirecting jq's output onto the settings
        # file truncates it before jq parses, so one syntax error in a
        # hand-edited file would cost the user every setting it holds. A file
        # jq cannot read is left alone, like the no-jq case below.
        if ! cs_write_atomic "$settings_file" jq --arg m "$memory_path" \
            '.autoMemoryDirectory = $m | .plansDirectory = ".cs/plans"' \
            "$settings_file" 2>/dev/null; then
            # stderr, not stdout: create_worktree_session returns its directory
            # by echoing it, and lib/99-main.sh captures that in a command
            # substitution, so anything on stdout here lands inside the path.
            warn "Could not parse $settings_file — left unchanged; cs memory settings not applied" >&2
        fi
    elif [ -f "$settings_file" ]; then
        # No jq, file exists — leave it alone rather than risk clobbering
        :
    else
        cat > "$settings_file" << SETTINGS
{
  "autoMemoryDirectory": "$memory_path",
  "plansDirectory": ".cs/plans"
}
SETTINGS
    fi

    # Migrate existing auto memory from the default location
    local real_path
    real_path="$(cd -- "$session_dir" 2>/dev/null && pwd -P)"
    local encoded_path
    encoded_path=$(_claude_encode_path "$real_path")
    local old_memory_dir="$HOME/.claude/projects/${encoded_path}/memory"
    if [ -d "$old_memory_dir" ]; then
        _move_memory_files "$old_memory_dir" "$session_dir/.cs/memory"
    fi
}

# Move every file under src (subdirectories included) to the same relative path
# under dest, deleting a source file only once dest holds a byte-identical copy.
# A name dest already holds with different content is copied beside it as
# <name>.claude-projects (not .md, so Claude Code does not load it as a topic).
# A copy that fails, or a .claude-projects name already holding something else,
# stops the move before anything is deleted, so src stays whole. Warnings go to
# stderr: create_worktree_session's caller captures stdout as a path.
_move_memory_files() {  # src, dest
    local src="$1" dest="$2" f rel target complete=1
    while IFS= read -r -d '' f; do
        rel="${f#"$src"/}"
        target="$dest/$rel"
        # A destination reached through a symlink is no copy at all: a link
        # back into src would pass cmp and the source would be deleted from
        # under it. Such a file stays where it is.
        if ! _memory_dest_is_plain "$dest" "$rel"; then
            warn "Not moving $f: $target is reached through a symlink" >&2
            complete=0
            continue
        fi
        # The destination root may itself be a link (a vaulted session keeps
        # .cs/memory elsewhere); only one pointing back at src makes the
        # target the source file, which no byte comparison can tell apart.
        if [ "$f" -ef "$target" ]; then
            warn "Not moving $f: $target is the same file" >&2
            complete=0
            continue
        fi
        if { [ -e "$target" ] || [ -L "$target" ]; } && ! cmp -s "$f" "$target"; then
            target="$target.claude-projects"
        fi
        if [ -e "$target" ] || [ -L "$target" ]; then
            if ! cmp -s "$f" "$target"; then
                warn "Not moving $f: $dest/$rel and $target both hold other content" >&2
                complete=0
            fi
            continue
        fi
        if mkdir -p "$(dirname "$target")" && cp -p "$f" "$target" && cmp -s "$f" "$target"; then
            if [ "$target" != "$dest/$rel" ]; then
                warn "Kept both copies of memory file $rel: the one from $src is $target" >&2
            fi
        else
            warn "Could not copy $f to $target" >&2
            complete=0
        fi
    done < <(find "$src" -type f -print0)

    if [ "$complete" -eq 0 ]; then
        warn "Left $src in place: not every file in it has a copy in $dest" >&2
        return 0
    fi
    while IFS= read -r -d '' f; do
        rel="${f#"$src"/}"
        _memory_dest_is_plain "$dest" "$rel" || continue
        if cmp -s "$f" "$dest/$rel" || cmp -s "$f" "$dest/$rel.claude-projects"; then
            rm -f "$f"
        fi
    done < <(find "$src" -type f -print0)
    # Only directories left empty go; one still holding anything (a symlink,
    # a file that appeared since) stays, and its rmdir failure is expected.
    find "$src" -depth -type d -empty -delete 2>/dev/null || true
}

# True when no component of dest/rel, from dest's first child down to the
# file itself (or its .claude-projects twin), is a symlink.
_memory_dest_is_plain() {  # dest, rel
    local path="$1" part rest="$2"
    while [ -n "$rest" ]; do
        part="${rest%%/*}"
        path="$path/$part"
        [ -L "$path" ] && return 1
        [ "$rest" = "$part" ] && break
        rest="${rest#*/}"
    done
    [ ! -L "$path.claude-projects" ]
}

# Ensure the session narrative topic file and its MEMORY.md index pointer exist.
# The narrative is the looser-bar lab notebook, held as a native memory topic
# file so it inherits lazy-load and /memory tooling. Idempotent: creates the
# stub on first run and re-adds the index pointer if a memory write dropped it.
# A caller that has already resolved the actor's slug passes it.
ensure_narrative_file() {  # session_dir, [actor_slug]
    local session_dir="$1"
    local mem_dir="$session_dir/.cs/memory"
    local index="$mem_dir/MEMORY.md"
    mkdir -p "$mem_dir"

    local actor="${2:-}"
    if [ -z "$actor" ]; then
        actor=$(cs_actor_slug "$session_dir")
    fi
    local narrative="$mem_dir/narrative.$actor.md"

    # One-time migration: a pre-per-actor narrative.md becomes this actor's file.
    if [ -f "$mem_dir/narrative.md" ] && [ ! -f "$narrative" ]; then
        mv "$mem_dir/narrative.md" "$narrative"
    fi

    if [ ! -f "$narrative" ]; then
        cat > "$narrative" << EOF
---
name: session-narrative-$actor
description: Session lab-notebook and work-in-progress narrative for $actor. Looser bar than durable memory. Its owner reads it in full on resume; anyone else reads only the lines the resume digest names. Older sections are archived under .cs/narrative-archive/.
type: narrative
---
# Session narrative ($actor)

EOF
    fi

    # Drop the legacy single-narrative index pointer if a migration left it stale.
    # Through a temp file instead of sed -i: the BSD `sed -i ''` form errors on
    # GNU sed and would abort session resume on Linux under set -e.
    if [ -f "$index" ] && grep -q '(narrative\.md)' "$index" 2>/dev/null; then
        cs_write_atomic "$index" sed '/(narrative\.md)/d' "$index" \
            || { warn "could not rewrite $index; the stale narrative.md pointer stays"; _CS_MIGRATE_CLEAN=0; }
    fi

    if [ ! -f "$index" ] || ! grep -q "(narrative\.$actor\.md)" "$index" 2>/dev/null; then
        printf -- '- [Session narrative — %s (lab notebook)](narrative.%s.md): looser-bar work-in-progress; its owner reads it in full on resume, anyone else only the lines the resume digest names; older sections under .cs/narrative-archive/\n' "$actor" "$actor" >> "$index"
    fi
}

# Fold a legacy discoveries.md (and its compact companion) into the narrative
# topic file, then consume the originals so the fold runs at most once. A
# header-only or empty discoveries.md is ignored. Runs on resume of sessions
# that predate the narrative relocation.
migrate_discoveries_to_narrative() {
    local session_dir="$1"
    local meta="$session_dir/.cs"
    local disc="$meta/discoveries.md"
    local compact="$meta/discoveries.compact.md"

    [ -f "$disc" ] || return 0
    local disc_body compact_body
    disc_body=$(grep -vE '^# Discoveries & Notes$|^[[:space:]]*$' "$disc" 2>/dev/null || true)
    compact_body=""
    [ -f "$compact" ] && compact_body=$(grep -vE '^[[:space:]]*$' "$compact" 2>/dev/null || true)
    if [ -z "$disc_body" ] && [ -z "$compact_body" ]; then
        rm -f "$disc" "$compact"
        return 0
    fi

    ensure_narrative_file "$session_dir"
    local narrative="$meta/memory/narrative.$(cs_actor_slug "$session_dir").md"
    # Date the fold from shared git history, not the local clock: two clones
    # folding the same legacy file must produce byte-identical blocks so a
    # later merge collapses them instead of conflicting.
    local fold_date
    fold_date=$(git -C "$session_dir" log -1 --format=%as -- .cs/discoveries.md 2>/dev/null || true)
    {
        if [ -n "$disc_body" ]; then
            echo ""
            if [ -n "$fold_date" ]; then
                echo "## Folded from discoveries.md ($fold_date)"
            else
                echo "## Folded from discoveries.md"
            fi
            echo ""
            cat "$disc"
        fi
        if [ -n "$compact_body" ]; then
            echo ""
            echo "## Folded from discoveries.compact.md"
            echo ""
            cat "$compact"
        fi
    } >> "$narrative"
    rm -f "$disc" "$compact"
}

# Emit the cs memory disclosure note (cs:memory-note section).
# Single source of truth used by write_session_claude_md (new sessions) and
# migrate_session Phase 9 (lazy migration on existing sessions). The note
# documents what cs actually owns — path redirect via
# CLAUDE_COWORK_MEMORY_PATH_OVERRIDE and the MEMORY.md index — without
# claiming ownership of capture behavior, which is owned by Claude's
# built-in auto-memory harness.
_emit_memory_note_block() {
    cat << 'EOF'
<!-- cs:memory-note -->
## Where memory lives

Claude's built-in memory writes durable facts to `.cs/memory/` (cs redirects via `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE`); the `MEMORY.md` index lists entries and individual `<bucket>_*.md` files are loaded lazily. Only `narrative.<actor>.md` is per-actor: the durable buckets and their index are shared by every actor working in this session, so an entry may describe a different person than the one present.
EOF
}

# Emit the session wrap-up cues (cs:wrap-cues section): when to offer /wrap.
# Single source for the template, Phase 10 (which appends it to a session
# that lacks it) and Phase 16 (which puts it in place of a four-option block
# cs wrote).
_emit_wrap_cues_block() {
    cat << 'EOF'
<!-- cs:wrap-cues -->
## Session wrap-up cues

When the conversation reaches a natural stopping point — work shipped, a PR merged, a deploy completed, a bug fixed, or the user signaling they're winding down — proactively offer to distill the session via AskUserQuestion BEFORE the conversation drifts.

**Strong signals (sufficient on their own — but only when the phrase describes work that actually completed; never fire when it reports a problem, is negated, or is part of a plan for later):**
- "shipped", "PR merged", "PR up", "deployed", "released"
- "let's call it", "wraps up", "done for the day", "good place to stop"
- "all good now", "that did it", "ready to ship"

**Soft signals (require a corroborating signal — a recent commit, an explicit "done", or two or more soft signals in succession):**
- "that works", "looks good", "we're good", "all set"

**When fired**, use AskUserQuestion with header "Wrap up?" and these options:
- "Run /wrap" — distill memory entries AND write a session summary in sequence
- "Not yet — keep working"

Do not fire on every short affirmative ("yes", "ok", "thanks"). Fire when the *work itself* has reached a coherent stopping point, not when a single answer satisfied a single question. False positives erode the signal — be picky.

To opt out, delete the prose above but keep the `cs:wrap-cues` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
EOF
}

# The rule for committing session files (cs:session-commits section). Single
# source used by _emit_session_claude_md (new sessions) and migrate_session
# Phase 15 (existing sessions). Models committed each narrative append and
# each handoff pass on their own, under subjects they made up; the rule says
# nothing commits session files unless the user asks.
_emit_session_commits_block() {
    cat << 'EOF'
<!-- cs:session-commits -->
## Committing session files

Apart from the one commit that creates a new session and the merge commit `/finish` makes to integrate a feature, which also carries the pointers cs adds to `.cs/memory/MEMORY.md`, cs, its skills and its commands never commit files under `.cs/` (narratives, handoffs, `.cs/README.md`, `.cs/summary.md`, memory entries, the task archive), and neither do you on your own: commit them only when the user asks. Uncommitted, they are safe: autosave snapshots every Write and Edit to a shadow ref.

To opt out, delete the prose above but keep the `cs:session-commits` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
EOF
}

# The diagram instruction shared by the session template and migration Phase 17.
_emit_mermaid_diagrams_block() {
    cat << 'EOF'
<!-- cs:mermaid-diagrams -->
## Diagrams

Mermaid flowchart fences (```mermaid with graph TD or graph LR) are drawn as diagrams in this terminal. Add one beside the prose only when an answer describes a flow that branches, loops or has four or more stages; never for a task list or numbered steps. One fence, short labels, no subgraphs; `{ }` for a decision, `(( ))` for a start or end, `[ ]` for a step; other diagram types show as source.

To opt out, delete the prose above but keep the `cs:mermaid-diagrams` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
EOF
}

# The protocol for an encrypted session: migrate_session appends it once
# .cs/private exists. It overrides the README instructions of the base
# protocol, which every session gets from _emit_session_claude_md.
_emit_encrypted_protocol_block() {
    cat << 'EOF'
<!-- cs:encrypted-protocol -->
## Encrypted session

This session keeps its private files in an encrypted vault: `.cs/memory`, `.cs/plans` and `.cs/private` link into it. Every other path in the session directory is plaintext on disk and in backups. These rules override the Session Files and Documentation Discipline sections above:

- Keep the objective, environment and outcome at the top of your narrative (`.cs/memory/narrative.<actor>.md`), and read them from there on resume. `.cs/README.md` stays frontmatter only; cs does not copy your first prompt into it.
- cs logs session start and end, tool failures and autosaves to `.cs/private/session.log`, inside the vault.
- Rotation handoffs live in `.cs/private/handoffs/` and are never committed; the `rotate` skill says how.
- `cs -narrative rotate` archives your narrative's older sections into `.cs/private/narrative-archive/<actor>/` (or through a `.cs/narrative-archive` link into the vault); grep there on demand.
- `/checkpoint` saves under `.cs/private/checkpoints/`, and the timeline records no label.
- Keep session notes (research, scratch, drafts) under `.cs/memory`, `.cs/plans` or `.cs/private`.
EOF
}

# Emit the session CLAUDE.md template to stdout. The leading sentinel lets both
# the create path (overwrite) and the migrate path (guarded append) detect
# whether the protocol is already present.
_emit_session_claude_md() {
    cat << 'EOF'
<!-- cs:session-protocol -->
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory. The session root is your workspace for project files.

## Session Files - READ THESE ON RESUME

At the start of every conversation in this session, read the following files to restore context (any conversation after the first is a resume; on a true first run they are stubs). Skip any that don't exist yet — they are created as the session progresses.

1. **.cs/summary.md** - If exists, read first for previous session overview
2. **.cs/README.md** - Session objective, environment, and outcome
3. **.cs/memory/narrative.<actor>.md** - Per-actor lab notebooks: findings, in-progress state, observations. Yours in full; a teammate's only where the resume digest says it grew

Narratives are per-actor (narrative.<actor>.md) so co-developers never conflict.
Append only to your own; on resume read your own in full, and a teammate narrative only
from the line the resume digest names for it (nothing, when it names none). Older sections
sit under .cs/narrative-archive/<actor>/ — grep on demand, never preload.

## Documentation Discipline

Update the markdown documentation files throughout the session:

1. **Once the objective is clear** (from the first substantive request): fill in the .cs/README.md objective and environment — don't block the user's first answer on this; on resume, update the existing text rather than overwriting it
2. **As you work:** Update your narrative (.cs/memory/narrative.<actor>.md) with findings
3. **End of session:** Complete the .cs/README.md outcome section

Treat these files as a lab notebook - document as you go, not just at the end.

EOF
    _emit_session_commits_block
    cat << 'EOF'

## Wrap-up Command

When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (.cs/summary.md). Mid-session, use `/checkpoint <label>` to snapshot git state and the narrative — e.g. before a risky refactor or destructive operation, and after reaching a green milestone (tests passing, a feature working) — saved under .cs/checkpoints/.

When a conversation's context grows heavy or a work phase completes, invoke the `rotate` skill: it writes a handoff to .cs/handoffs/ and arms it, so the user can run `/clear` to continue in a fresh conversation without leaving Claude Code (exiting and answering `r` at the next launch does the same). `cs -conversations` shows the session's conversation chain.

## Secure Secrets Handling

Secrets live in the cs session store, never in a project file. `cs -secrets set`
and the `store-secret` skill read the value on **stdin** via a file redirect —
never `echo`/`printf` a secret into a pipe or a Bash heredoc, either of which
puts the plaintext in the Bash command itself.

Consume a secret inline — `some-command --token "$(cs -secrets get API_KEY)"` —
so it stays out of the tool result and the transcript. A retrieved value is read
by a command, never printed, echoed, piped, or written to a file (that includes
`cs -secrets export` output). `cs -secrets --help` lists the rest of the verbs.

**When you find a credential already in the workspace**, invoke the
`store-secret` skill — it carries the full procedure. Replace the literal with
the reference the file wants — `${API_KEY}` in a config, `$(cs -secrets get
API_KEY)` in a shell script. Doing it by hand instead, the safe path is exactly
this: create a fresh scratch file OUTSIDE the session directory with
`mktemp "${TMPDIR:-/tmp}/cs-secret.XXXXXX"` (any Write inside the session
directory is snapshotted into the autosave ref and survives `rm`), write the
value to the path it printed with the **Write** tool, then store it and
delete the scratch file in ONE Bash command, which keeps the store's exit
status: `f='<that path>'; cs -secrets set NAME < "$f"; rc=$?; rm -f "$f"; exit $rc`.

EOF
    _emit_memory_note_block
    echo
    _emit_wrap_cues_block
    echo
    _emit_mermaid_diagrams_block
}

# Write the session protocol template to the given directory (create path).
# Targets CLAUDE.local.md: machine-local, gitignored, regenerated by cs, so
# a user-owned CLAUDE.md is never touched.
write_session_claude_md() {
    local session_dir="$1"
    _emit_session_claude_md > "$session_dir/CLAUDE.local.md"
}

# Put the session protocol into CLAUDE.local.md without losing a line of it:
# written when absent, appended below a user's own file, and a file that
# already carries any cs sentinel is left alone. A user's CLAUDE.local.md is
# gitignored by convention, so git holds no copy to recover it from.
ensure_session_claude_md() {
    local session_dir="$1"
    local claude_local="$session_dir/CLAUDE.local.md"
    if [ ! -f "$claude_local" ]; then
        write_session_claude_md "$session_dir"
    elif ! grep -q '<!-- cs:' "$claude_local"; then
        printf '\n' >> "$claude_local"
        _emit_session_claude_md >> "$claude_local"
        notice CLAUDE.local.md "added the cs session protocol below your own lines"
    fi
}

# Move cs-managed content from a session's CLAUDE.md into CLAUDE.local.md.
# A pure function of the file's content (no timestamps, no local state), so
# two clones migrating the same tracked file produce byte-identical edits.
# SAFETY: cs never wrote CLAUDE.local.md before this feature, so an existing
# CLAUDE.local.md without the protocol sentinel is USER content — it is only
# ever APPENDED to, never overwritten. No pipes feed a grep -q whose early
# exit could SIGPIPE the producer under pipefail (GNU grep exits on first
# match; BSD drains) — head detection uses a case glob on captured text.
# Cases:
#   - CLAUDE.md absent, sentinel-free, or CLAUDE.local.md already carries
#     the protocol: no-op.
#   - Nothing but whitespace above the first cs sentinel (nothing of the
#     user's), OR the head's first non-blank line is exactly
#     "# Session Documentation Protocol" AND the first sentinel is not the
#     legacy cs:memory-rules block (the pre-leading-sentinel template era
#     wrote that heading first and gained sentinels only for later
#     sections, so the whole head is cs's, not the user's): the whole file
#     moves; CLAUDE.md is removed. Appended, not moved, when a user
#     CLAUDE.local.md exists.
#   - Old head immediately followed by an unretired cs:memory-rules block:
#     mixed-split as below, unmoved — Phase 9 still needs the split layout
#     to retire that block in place before the file can be a wholesale-move
#     candidate.
#   - User head above the first sentinel: head stays in CLAUDE.md (trailing
#     blank lines of the head collapse — deterministic), sentinel-to-EOF
#     moves (or appends); both files kept.
migrate_claude_md_to_local() {
    local session_dir="$1"
    local claude_md="$session_dir/CLAUDE.md"
    local local_md="$session_dir/CLAUDE.local.md"
    if [ ! -f "$claude_md" ] || ! grep -q '<!-- cs:' "$claude_md"; then
        return 0
    fi
    if [ -f "$local_md" ] && grep -q 'cs:session-protocol' "$local_md"; then
        return 0
    fi
    local split_line
    split_line=$(awk '/<!-- cs:/{print NR; exit}' "$claude_md")
    local head_text=""
    if [ "$split_line" -gt 1 ]; then
        head_text=$(sed -n "1,$((split_line - 1))p" "$claude_md")
    fi
    # The head's first non-blank line, read from the file directly (no
    # pipe: a consumer quitting early would SIGPIPE a producer still
    # writing a >64KB head, and under pipefail that kills the launch).
    local first_head_line
    first_head_line=$(awk -v n="$split_line" 'NR >= n { exit } /[^[:space:]]/ { print; exit }' "$claude_md")
    local first_sentinel
    first_sentinel=$(awk '/<!-- cs:/{print; exit}' "$claude_md")
    local wholesale=0
    case "$head_text" in
        *[![:space:]]*)
            if [ "$first_head_line" = "# Session Documentation Protocol" ] \
                && [ "$first_sentinel" != "<!-- cs:memory-rules -->" ]; then
                wholesale=1
            fi
            ;;
        *)
            wholesale=1
            ;;
    esac
    if [ "$wholesale" -eq 1 ]; then
        if [ -f "$local_md" ]; then
            printf '\n' >> "$local_md"
            cat "$claude_md" >> "$local_md"
            rm "$claude_md"
        else
            mv "$claude_md" "$local_md"
        fi
        notice CLAUDE.local.md "holds the cs session protocol, moved from CLAUDE.md"
    else
        if [ -f "$local_md" ]; then
            printf '\n' >> "$local_md"
            sed -n "${split_line},\$p" "$claude_md" >> "$local_md"
        else
            sed -n "${split_line},\$p" "$claude_md" > "$local_md"
        fi
        cs_write_atomic "$claude_md" printf '%s\n' "$head_text" || error "could not rewrite $claude_md"
        notice CLAUDE.local.md "holds cs's sections, moved from CLAUDE.md, where your own lines stay"
    fi
    return 0
}

# Generate a v4 UUID, lowercased. uuidgen on BSD (macOS) returns uppercase;
# Linux uuidgen and /proc are already lowercase. Lowercasing keeps the
# value consistent with how Claude Code stores its session jsonl paths.
