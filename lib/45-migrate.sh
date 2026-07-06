# ABOUTME: Session structure creation, git merge attributes, and the legacy migration phases.
# ABOUTME: Runs migrate_session on every open to bring old layouts current.

setup_merge_attributes() {
    local dir="$1"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    git -C "$dir" config merge.ours.driver true 2>/dev/null || true
    local ga="$dir/.gitattributes"
    if ! grep -q 'MEMORY\.md merge=ours' "$ga" 2>/dev/null; then
        printf '.cs/memory/MEMORY.md merge=ours\n' >> "$ga"
    fi
    if ! grep -q 'timeline\.jsonl merge=union' "$ga" 2>/dev/null; then
        printf '.cs/timeline.jsonl merge=union\n' >> "$ga"
    fi
    if ! grep -q 'narrative\.\*\.md merge=union' "$ga" 2>/dev/null; then
        printf '.cs/memory/narrative.*.md merge=union\n' >> "$ga"
    fi
}

# Refuse to proceed if per-actor local state has been committed to git.
cs_assert_local_untracked() {
    local dir="$1"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    if [ -n "$(git -C "$dir" ls-files -- .cs/local 2>/dev/null)" ]; then
        error ".cs/local/ is tracked in git (per-actor state must stay local). Fix with: git -C \"$dir\" rm -r --cached .cs/local && git commit -m 'stop tracking .cs/local'"
    fi
}

# Create session directory structure
create_session_structure() {
    local session_dir="$1"
    local claude_session_id claude_session_color
    claude_session_id=$(_alloc_uuid)
    claude_session_color=$(_alloc_random_color)

    mkdir -p "$session_dir/.cs/local"

    # Machine-local values go to .cs/local/state, never the git-synced README.
    _set_local_state "$session_dir/.cs/local/state" claude_session_id "$claude_session_id"
    _set_local_state "$session_dir/.cs/local/state" claude_session_color "$claude_session_color"

    # Create README.md with YAML frontmatter for structured queries
    cat > "$session_dir/.cs/README.md" << EOF
---
status: active
created: $(date '+%Y-%m-%d')
tags: []
aliases: ["$(basename "$session_dir")"]
---
# Session: $(basename "$session_dir")

**Started:** $(date '+%Y-%m-%d %H:%M:%S')
**Location:** $(hostname):$(pwd)

## Objective

[Describe what you're trying to accomplish in this session]

## Environment

[Describe the system, server, or context you're working in]

## Outcome

[To be filled when session is complete - summarize what was accomplished]
EOF


    write_session_claude_md "$session_dir"

    # Initialize session log (machine-local; never git-synced)
    cat > "$session_dir/.cs/local/session.log" << EOF
Claude Code Session Log
Session: $(basename "$session_dir")
Started: $(date '+%Y-%m-%d %H:%M:%S')
Location: $(hostname):$(pwd)

================================================================================

EOF

    # Redirect Claude Code auto memory into the session directory
    setup_auto_memory "$session_dir"

    # Create the session narrative topic file + index pointer
    ensure_narrative_file "$session_dir"
}

# Remove .cs/commands.md (and its adjacent state files), and strip the
# `@.cs/commands.md` import plus the "Discovered Commands" section from
# CLAUDE.md. Idempotent: silent and a no-op once a session is clean.
prune_commands_artifacts() {
    local session_dir="$1"
    local meta_dir="$session_dir/.cs"
    local removed=0

    local f
    for f in commands.md commands.md.tmp command-dates.txt promoted-commands.txt; do
        if [ -f "$meta_dir/$f" ]; then
            rm -f "$meta_dir/$f"
            removed=1
        fi
    done

    local claude_md="$session_dir/CLAUDE.md"
    if [ -f "$claude_md" ] && grep -qE '@\.cs/commands\.md|^## Discovered Commands|^[0-9]+\. \*\*\.cs/commands\.md\*\*' "$claude_md"; then
        local tmp="$claude_md.tmp"
        awk '
            /^## Discovered Commands[[:space:]]*$/ { in_section = 1; next }
            in_section && /^## / { in_section = 0 }
            in_section { next }
            /^[0-9]+\. \*\*\.cs\/commands\.md\*\*/ { next }
            { print }
        ' "$claude_md" > "$tmp" && mv "$tmp" "$claude_md"
        removed=1
    fi

    if [ "$removed" -eq 1 ]; then
        warn "Pruned retired command-tracker artifacts"
    fi
}

# Move a file or directory if source exists and destination doesn't (idempotent)
migrate_if_exists() {
    local src="$1" dst="$2"
    if [ -e "$src" ] && [ ! -e "$dst" ]; then
        mv "$src" "$dst"
    fi
}

# Check if session needs migration from flat layout to .cs/ directory
needs_cs_migration() {
    local session_dir="$1"
    [[ ! -d "$session_dir/.cs" ]] && { [[ -d "$session_dir/logs" ]] || [[ -f "$session_dir/discoveries.md" ]]; }
}

# Migrate existing session to latest format
migrate_session() {
    local session_dir="$1"

    # Per-actor local state must never be committed; refuse if it has been.
    cs_assert_local_untracked "$session_dir"

    # Backfill the merge attributes on existing sessions.
    setup_merge_attributes "$session_dir"

    # Backfill the .cs/local/ ignore rule on older sessions whose .gitignore
    # predates it, so per-actor local state never gets committed (which would
    # otherwise trip cs_assert_local_untracked and block the next resume).
    ensure_cs_gitignore_entries "$session_dir"

    # Phase 1: Structural migration (flat layout -> .cs/ directory)
    if needs_cs_migration "$session_dir"; then
        mkdir -p "$session_dir/.cs"

        # Move directories
        migrate_if_exists "$session_dir/logs" "$session_dir/.cs/logs"
        migrate_if_exists "$session_dir/archives" "$session_dir/.cs/archives"
        migrate_if_exists "$session_dir/age-recipients" "$session_dir/.cs/age-recipients"

        # Move metadata files
        migrate_if_exists "$session_dir/README.md" "$session_dir/.cs/README.md"
        migrate_if_exists "$session_dir/discoveries.md" "$session_dir/.cs/discoveries.md"
        migrate_if_exists "$session_dir/summary.md" "$session_dir/.cs/summary.md"
        migrate_if_exists "$session_dir/secrets.enc" "$session_dir/.cs/secrets.enc"
        migrate_if_exists "$session_dir/secrets.age" "$session_dir/.cs/secrets.age"

        # Update .gitignore for new structure
        create_session_gitignore "$session_dir"

        echo ""
        echo -e "${ORANGE}Migrated session to .cs/ directory structure${NC}"
        echo -e "${DIM}Session metadata moved to .cs/ - your workspace root is now clean for project files.${NC}"
        echo ""

        # Commit the migration if git is initialized
        if [ -d "$session_dir/.git" ]; then
            (
                cd "$session_dir" || exit 0
                git add -A 2>/dev/null || true
                if ! git diff --cached --quiet 2>/dev/null; then
                    git commit -q -m "Migrate session structure to .cs/ metadata directory" 2>/dev/null || true
                fi
            )
        fi
    fi

    # Phase 2: Ensure .cs/ subdirectories exist (handles partial migrations and edge cases)
    mkdir -p "$session_dir/.cs/local"

    # Phase 2b: Relocate the session log to machine-local state. The audit trail
    # (bash commands, lifecycle events, autosave notes) is per-checkout, not
    # shared — keeping it git-synced with merge=union interleaved every machine's
    # commands into the one shared repo. Move it under .cs/local/ (gitignored) so
    # it stays with the machine that produced it; the shared structured record
    # lives in timeline.jsonl. The tracked deletion is left for the next normal
    # commit, as with the README-frontmatter move below. One-time, idempotent:
    # once the old file is gone the block is a no-op. During the upgrade window a
    # peer still on the old cs may keep appending to the tracked log, so a
    # one-time modify/delete conflict on this low-stakes file is possible — take
    # either side.
    if [ -f "$session_dir/.cs/logs/session.log" ]; then
        cat "$session_dir/.cs/logs/session.log" >> "$session_dir/.cs/local/session.log"
        rm -f "$session_dir/.cs/logs/session.log"
        rmdir "$session_dir/.cs/logs" 2>/dev/null || true
        # Drop the obsolete union rule for the relocated log. grep -v exits 1 when
        # that was the only line, so guard on presence and tolerate the exit code
        # rather than leaving the rule (and a stray .tmp) behind.
        local ga="$session_dir/.gitattributes"
        if [ -f "$ga" ] && grep -q 'logs/session\.log merge=union' "$ga"; then
            grep -v 'logs/session\.log merge=union' "$ga" > "$ga.tmp" 2>/dev/null || true
            mv "$ga.tmp" "$ga" 2>/dev/null || rm -f "$ga.tmp"
        fi
        warn "Moved .cs/logs/session.log to machine-local .cs/local/session.log"
    fi

    # Remove inert sync/remote metadata left by older versions (the sync
    # subsystem was removed; nothing reads these files anymore)
    rm -f "$session_dir/.cs/sync.conf" "$session_dir/.cs/remote.conf"

    # Phase 4: Ensure auto memory and plans are configured
    if [ ! -d "$session_dir/.cs/memory" ] || [ ! -d "$session_dir/.cs/plans" ] || [ ! -f "$session_dir/.claude/settings.local.json" ]; then
        setup_auto_memory "$session_dir"
    fi

    # Phase 4b: Fold a legacy discoveries.md into the narrative topic file, then
    # ensure the narrative file + index pointer exist (idempotent on every resume).
    migrate_discoveries_to_narrative "$session_dir"
    ensure_narrative_file "$session_dir"

    # Phase 5: ensure the cs session protocol is present in CLAUDE.md. Append it
    # (never overwrite) so a user-authored or project CLAUDE.md is preserved; the
    # sentinel keeps it idempotent, and a file that already references .cs/ is a
    # prior cs template that needs nothing.
    local claude_md="$session_dir/CLAUDE.md"
    if [ -f "$claude_md" ] \
        && ! grep -q 'cs:session-protocol' "$claude_md" \
        && ! grep -q '\.cs/' "$claude_md"; then
        printf '\n' >> "$claude_md"
        _emit_session_claude_md >> "$claude_md"
        warn "Appended the cs session protocol to your existing CLAUDE.md"
    fi

    # Phase 7: prune retired command-tracker artifacts.
    prune_commands_artifacts "$session_dir"

    # Phase 6: Add YAML frontmatter to README.md if missing
    local readme="$session_dir/.cs/README.md"
    if [ -f "$readme" ] && ! head -1 "$readme" | grep -q '^---$'; then
        local session_name
        session_name=$(basename "$session_dir")
        # Derive created date from the "Started:" line, then from the git
        # date the README was added (shared history — every clone derives
        # the same value), then from file mtime (non-git sessions only;
        # mtime is not preserved across clones so it must never feed a
        # value that another machine could contradict on merge).
        local created_date
        created_date=$(grep -oE 'Started:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}' "$readme" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
        if [ -z "$created_date" ]; then
            created_date=$(git -C "$session_dir" log --diff-filter=A --format=%as -- .cs/README.md 2>/dev/null | tail -1 || true)
        fi
        if [ -z "$created_date" ]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                created_date=$(stat -f '%Sm' -t '%Y-%m-%d' "$readme" 2>/dev/null || date '+%Y-%m-%d')
            else
                created_date=$(stat -c '%y' "$readme" 2>/dev/null | cut -d' ' -f1 || date '+%Y-%m-%d')
            fi
        fi
        local existing_content
        existing_content=$(cat "$readme")
        {
            echo "---"
            echo "status: active"
            echo "created: $created_date"
            echo "tags: []"
            echo "aliases: [\"$session_name\"]"
            echo "---"
            echo "$existing_content"
        } > "$readme"
        warn "Added frontmatter to .cs/README.md"
    fi

    # Phase 12: Move machine-local fields out of README frontmatter into
    # .cs/local/state. claude_session_id / claude_session_color are copied
    # (unless the state file already has its own value — the local machine's
    # binding wins over whatever another machine last pushed); last_resumed
    # and updated are dropped, they are regenerated activity stamps. The
    # README then loses all four lines: hooks on every machine rewrote them
    # with divergent values, which made merge conflicts inevitable whenever
    # a session was shared through git.
    local _state="$session_dir/.cs/local/state"
    if [ -f "$readme" ] && grep -qE '^(claude_session_id|claude_session_color|last_resumed|updated):' "$readme"; then
        local _legacy_uuid _legacy_color
        _legacy_uuid=$(awk '/^claude_session_id:/ { sub(/^claude_session_id:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$readme")
        _legacy_color=$(awk '/^claude_session_color:/ { sub(/^claude_session_color:[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$readme")
        if [ -n "$_legacy_uuid" ] && [ -z "$(_read_local_state "$_state" claude_session_id)" ]; then
            _set_local_state "$_state" claude_session_id "$_legacy_uuid"
        fi
        if [ -n "$_legacy_color" ] && [ -z "$(_read_local_state "$_state" claude_session_color)" ]; then
            _set_local_state "$_state" claude_session_color "$_legacy_color"
        fi
        local _tmp="$readme.tmp"
        awk '/^(claude_session_id|claude_session_color|last_resumed|updated):/ { next } { print }' \
            "$readme" > "$_tmp" && mv "$_tmp" "$readme"
        warn "Moved machine-local fields from .cs/README.md to .cs/local/state"
    fi

    # Phase 8: Bind claude_session_id in local state to a real claude
    # transcript on disk so `claude --resume <uuid>` resolves to an actual
    # conversation. A recorded UUID with no matching transcript file is an
    # orphan — the cs hooks/doctor cross-checks will warn about it on every
    # launch, and `--resume` will fail. Steady state ("recorded UUID present,
    # transcript exists") is the fast path; cold paths run discovery.
    {
        local _existing _proj _bind_uuid=""
        _existing=$(_read_local_state "$_state" claude_session_id)
        _proj=$(_claude_project_dir "$session_dir")

        if [ -n "$_existing" ] && [ -f "$_proj/$_existing.jsonl" ]; then
            : # already bound — skip discovery entirely
        else
            local _discovered
            _discovered=$(_discover_session_uuid_in "$_proj")
            if [ -n "$_discovered" ]; then
                _bind_uuid="$_discovered"
            elif [ -z "$_existing" ]; then
                # No transcripts and no recorded UUID — allocate fresh.
                # A recorded UUID without transcripts is left alone: claude
                # hasn't written the jsonl yet (eg. session was just created
                # with --session-id but hasn't talked to the user).
                _bind_uuid=$(_alloc_uuid)
            fi
        fi

        if [ -n "$_bind_uuid" ]; then
            _set_local_state "$_state" claude_session_id "$_bind_uuid"
            if [ -z "$_existing" ]; then
                warn "Bound claude_session_id in .cs/local/state to $_bind_uuid"
            else
                warn "Repaired orphan claude_session_id (was $_existing)"
            fi
        fi
    }

    # Phase 9: Manage the cs:memory-note section in CLAUDE.md. Four states:
    #
    #   1. cs:memory-note already present — skip silently.
    #   2. cs:memory-rules sentinel + "## Auto-memory bucket guidance" header
    #      (any variant, with or without the "(scoop mode" suffix) — legacy
    #      imperative-prose block from v2026.5.2–5.4. Strip the entire block
    #      (sentinel through the next <!-- marker or EOF) and insert the
    #      cs:memory-note in its place. Adjacent cs:wrap-cues block keeps its
    #      order. Empirically the block did not influence claude's auto-memory
    #      writer (see .cs/memory/narrative.md); the note documents what cs
    #      actually owns — path redirect + indexing — without claiming
    #      behavioral ownership.
    #   3. cs:memory-rules sentinel without header line — user opted out via
    #      tombstone. The opt-out signal ("no cs memory documentation in my
    #      CLAUDE.md") carries over to the replacement note: preserve as-is,
    #      do NOT add the note.
    #   4. Neither sentinel present — append the note fresh.
    #
    # Note content lives in _emit_memory_note_block (shared with
    # write_session_claude_md). Phase 6 guarantees CLAUDE.md exists.
    local claude_md_p9="$session_dir/CLAUDE.md"
    if [ -f "$claude_md_p9" ]; then
        if grep -q '<!-- cs:memory-note -->' "$claude_md_p9"; then
            : # State 1: already on the note
        elif grep -q '<!-- cs:memory-rules -->' "$claude_md_p9"; then
            if grep -qE '^## Auto-memory bucket guidance' "$claude_md_p9"; then
                # State 2: legacy rules block — strip + insert note in place.
                # NEW_BLOCK passed via env (not -v) so awk doesn't re-process
                # C-style escapes in the markdown content.
                local tmp="$claude_md_p9.tmp"
                NEW_BLOCK=$(_emit_memory_note_block) awk '
                    /<!-- cs:memory-rules -->/ {
                        print ENVIRON["NEW_BLOCK"]
                        stripping = 1
                        next
                    }
                    stripping && /^<!-- / { stripping = 0 }
                    !stripping { print }
                ' "$claude_md_p9" > "$tmp" && mv "$tmp" "$claude_md_p9"
                warn "Retired auto-memory bucket guidance; replaced with cs:memory-note"
            # State 3: tombstone (sentinel without header) — preserve opt-out
            fi
        else
            # State 4: no sentinel of either kind — append fresh
            {
                echo ""
                _emit_memory_note_block
            } >> "$claude_md_p9"
            warn "Added cs:memory-note to CLAUDE.md"
        fi
    fi

    # Phase 10: Append session wrap-up cues to CLAUDE.md when sentinel absent.
    # The cs:wrap-cues marker (with or without content beneath) signals
    # "managed, do not re-add" — users opt out via tombstone (delete prose,
    # keep the HTML comment).
    if [ -f "$claude_md_p9" ] && ! grep -q 'cs:wrap-cues' "$claude_md_p9"; then
        cat >> "$claude_md_p9" << 'EOF'

<!-- cs:wrap-cues -->
## Session wrap-up cues

When the conversation reaches a natural stopping point — work shipped, a PR merged, a deploy completed, a bug fixed, or the user signaling they're winding down — proactively offer to distill the session via AskUserQuestion BEFORE the conversation drifts.

**Strong triggers (fire on any single occurrence):**
- "shipped", "PR merged", "PR up", "deployed", "released"
- "let's call it", "wraps up", "done for the day", "good place to stop"
- "all good now", "that did it", "ready to ship"

**Soft triggers (require a corroborating signal — a recent commit, an explicit "done", or two or more soft signals in succession):**
- "that works", "looks good", "we're good", "all set"

**When fired**, use AskUserQuestion with header "Wrap up?" and these options:
- "Run /wrap" — distill memory entries AND write a session summary in sequence (the usual choice)
- "Run /sweep only" — just the memory pass; skip the narrative summary
- "Run /summary only" — just the narrative; skip the memory pass
- "Not yet — keep working"

Do not fire on every short affirmative ("yes", "ok", "thanks"). Fire when the *work itself* has reached a coherent stopping point, not when a single answer satisfied a single question. False positives erode the signal — be picky.

To opt out, delete the prose above but keep the `cs:wrap-cues` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
EOF
        warn "Appended session wrap-up cues to CLAUDE.md"
    fi

    # Phase 11: Backfill claude_session_color in local state when absent.
    # Picks one of the 8 colors claude's /color command accepts. Idempotent —
    # runs only when the field is missing. Legacy sessions (pre-v2026.5.7)
    # get a randomly-chosen color on next launch and stay on it from then on.
    if [ -z "$(_read_local_state "$_state" claude_session_color)" ]; then
        local _new_color
        _new_color=$(_alloc_random_color)
        _set_local_state "$_state" claude_session_color "$_new_color"
        warn "Backfilled claude_session_color in .cs/local/state ($_new_color)"
    fi
}

# Cross-platform helpers
