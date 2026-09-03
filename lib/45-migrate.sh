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

# True when cs created this session directory, and so owns its mode. Two ways to
# fail: the directory sits outside the sessions root, or a symlink IN the root
# resolves to it — an adopted session, whose target is the user's own project
# and stays whatever mode they chose, even when they keep it inside the root.
#
# Both sides are resolved before comparing. A plain prefix test on the unresolved
# root silently never matched wherever the root itself sits behind a link (macOS
# /var -> /private/var is the everyday case), so the backfill quietly did nothing
# on exactly the machines it was written on.
_session_root_is_cs_owned() {  # session_dir
    local dir root e
    dir=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    root=$(cd "${SESSIONS_ROOT:-}" 2>/dev/null && pwd -P) || return 1
    case "$dir" in "$root"/*) ;; *) return 1 ;; esac
    for e in "${SESSIONS_ROOT:-}"/*; do
        [ -L "$e" ] || continue
        [ "$(cd "$e" 2>/dev/null && pwd -P)" = "$dir" ] && return 1
    done
    return 0
}

# Bring a session's own data directory to owner-only. cs writes narratives,
# plans, logs, the timeline and machine-local state here, and a session can hold
# anything its user worked on — but bare mkdir takes the caller's umask, so on
# any sessions root that is not itself private the whole lot is world-readable.
# Only .cs is set: reaching a file inside needs execute on the directory, so a
# private .cs covers everything under it whatever the files' own modes are.
#
# Scoped to .cs on purpose. adopt calls create_session_structure with the USER'S
# project directory, whose mode is theirs to choose — a shared checkout or a
# served directory may be world-readable deliberately — so the session root is
# hardened only where cs created it.
_harden_session_meta() {  # session_dir
    [ -d "$1/.cs" ] || return 0
    chmod 700 "$1/.cs" 2>/dev/null || true
    return 0
}

# Create session directory structure
create_session_structure() {
    local session_dir="$1"
    local claude_session_id claude_session_color
    claude_session_id=$(_alloc_uuid)
    claude_session_color=$(_alloc_random_color)

    mkdir -p "$session_dir/.cs/local"
    _harden_session_meta "$session_dir"

    # Machine-local values go to .cs/local/state, never the git-synced README.
    _set_local_state "$session_dir/.cs/local/state" claude_session_id "$claude_session_id"
    _set_local_state "$session_dir/.cs/local/state" claude_session_color "$claude_session_color"

    # Create README.md with YAML frontmatter for structured queries. A brand
    # new session never has one yet; adopt's orphaned-.cs re-adopt path is the
    # one caller that runs this against a directory that already carries one,
    # and its records must survive untouched.
    if [ ! -f "$session_dir/.cs/README.md" ]; then
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
    fi


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

# Convert a legacy line-per-message inbox (already renamed to
# inbox.jsonl.migrating) into per-message maildir documents. Lines at or below
# the old `seen` cursor were read and go to cur/; the rest go to new/. A line
# that does not parse at all is quarantined in mail/corrupt.jsonl — it is
# evidence of the append tearing the maildir removes, not garbage. Records may
# lack a numeric ts (accepted and pinned by test) or a usable id, so neither
# is assumed for the filename: a missing ts sorts to the front and a missing id
# becomes a migration-local sequence, preserving order within the legacy file.
# Every name derives only from the legacy content, so converting the same file
# twice produces the same names and the second run delivers nothing new — which
# is what makes an interrupted conversion safe to retry. Deletes the converted
# file and the cursor when done.
_convert_legacy_inbox() {  # maildir
    local maildir="$1" legacy="$1/inbox.jsonl.migrating"
    [ -f "$legacy" ] || return 0
    _mail_ensure_maildir "$maildir"
    local seen=""
    if [ -f "$maildir/seen" ]; then
        IFS= read -r seen < "$maildir/seen" || true
    fi
    case "$seen" in ''|*[!0-9]*) seen=0;; esac
    local lineno=0 seq=0 line meta ts id fname dest failed=0
    # `|| [ -n "$line" ]` converts a final line the stale writer never
    # terminated rather than dropping it.
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        case "$line" in *[![:space:]]*) : ;; *) continue ;; esac
        meta=$(printf '%s\n' "$line" | jq -r '
            (try (if (.ts|type) == "number" then (.ts|floor|tostring) else "" end) catch "") + "\t" +
            (try (if (.id|type) == "string" then .id else "" end) catch "")
        ' 2>/dev/null) || meta=""
        if [ -z "$meta" ]; then
            printf '%s\n' "$line" >> "$maildir/corrupt.jsonl"
            continue
        fi
        seq=$((seq + 1))
        ts="${meta%%$'\t'*}"
        id="${meta#*$'\t'}"
        # Base-10 normalize before printf %d, which reads a leading zero as octal.
        # A record with no usable ts sorts to the front rather than taking the
        # migration's own clock: "now" differs on every run, which would give
        # the same record a new name each time and defeat the rerun guard below.
        case "$ts" in ''|*[!0-9]*) ts=0;; *) ts=$((10#$ts));; esac
        case "$id" in ''|*[!A-Za-z0-9._-]*) id=$(printf 'legacy-%04d' "$seq");; esac
        # The line's own position is part of the name, so the name depends only
        # on the legacy file's content -- the same record converts to the same
        # filename on every run.
        fname="$(printf '%010d' "$ts")-${id}-$(printf '%04d' "$seq").json"
        if [ "$lineno" -le "$seen" ]; then dest="cur"; else dest="new"; fi
        # A conversion interrupted partway leaves records already delivered.
        # Skip those, in EITHER box: re-delivering one the recipient has since
        # read would resurrect it as unread, and delivering it twice would show
        # the same message twice.
        if [ -e "$maildir/new/$fname" ] || [ -e "$maildir/cur/$fname" ]; then
            continue
        fi
        if ! { printf '%s\n' "$line" > "$maildir/tmp/$fname" \
                && mv "$maildir/tmp/$fname" "$maildir/$dest/$fname"; }; then
            rm -f "$maildir/tmp/$fname"
            failed=1
        fi
    done < "$legacy"
    # Only drop the legacy file once every record reached a box. A failed write
    # is the non-final command of an && list, so errexit does not fire and the
    # loop runs on; unlinking here regardless would destroy the one copy of the
    # mail that never landed. Retrying is safe because the names above are a
    # pure function of the legacy content.
    [ "$failed" -eq 0 ] && rm -f "$legacy" "$maildir/seen"
    return 0
}

# One-time, idempotent mailbox migration, keyed ONLY on inbox.jsonl existing.
# It must not also require new/ to be absent: delivery creates the recipient's
# maildir on send, so a session receiving one new-format message before its
# next open would otherwise read the gate false forever and strand its legacy
# unread mail. Renaming before converting keeps a stale writer safe: one
# holding an open descriptor keeps writing into the renamed inode and its
# lines are still converted; one that reopens the path creates a fresh
# inbox.jsonl, which the next open converts.
migrate_mailbox() {  # session_dir
    local maildir="$1/.cs/local/mail"
    # A migration interrupted between rename and delete left real mail in
    # inbox.jsonl.migrating; convert it before renaming a fresh inbox over it.
    _convert_legacy_inbox "$maildir"
    [ -f "$maildir/inbox.jsonl" ] || return 0
    mv "$maildir/inbox.jsonl" "$maildir/inbox.jsonl.migrating" 2>/dev/null || return 0
    _convert_legacy_inbox "$maildir"
}

# Check if session needs migration from flat layout to .cs/ directory
needs_cs_migration() {
    local session_dir="$1"
    [[ ! -d "$session_dir/.cs" ]] && { [[ -d "$session_dir/logs" ]] || [[ -f "$session_dir/discoveries.md" ]]; }
}

# Rewrite the read-all-narratives sentences cs wrote into existing sessions, and
# the read-the-live-narratives sentences that replaced them (nobody can read a
# teammate's whole file either; a resume reads its own in full and a teammate's
# only from the line the digest names). Three places cs owns: a narrative's
# frontmatter description, its MEMORY.md pointer and the protocol block in
# CLAUDE.local.md. Only the exact sentences cs emitted are
# touched — a narrative body or a user's own prose never is. Temp+mv rather than
# sed -i (BSD/GNU disagree on -i). Idempotent: nothing matches on the second run.
migrate_narrative_resume_wording() {
    local session_dir="$1"
    local mem="$session_dir/.cs/memory" f tmp
    for f in "$mem"/narrative.*.md; do
        [ -f "$f" ] || continue
        # Keyed to the description line specifically (not just "somewhere in the
        # first 8 lines"): a cs-written narrative has exactly 7 header lines, so
        # a body line beginning on line 8 sits inside a bare line-range window
        # too and would otherwise be rewritten. No pipe into grep -q: under
        # pipefail a huge first line can make `head -8 | grep -q` exit 141 and
        # silently skip the file via `|| continue`.
        awk 'NR <= 8 && /^description: .*Read (all|the live) narrative\.\*\.md on resume[.;]/ { f = 1 } NR > 8 { exit } END { exit !f }' "$f" || continue
        tmp="$f.tmp"
        sed '1,8{/^description: /{s/Read all narrative\.\*\.md on resume\./Its owner reads it in full on resume; anyone else reads only the lines the resume digest names. Older sections are archived under .cs\/narrative-archive\/./;s/Read the live narrative\.\*\.md on resume; older sections are archived under \.cs\/narrative-archive\/\./Its owner reads it in full on resume; anyone else reads only the lines the resume digest names. Older sections are archived under .cs\/narrative-archive\/./;};}' "$f" > "$tmp" \
            && mv "$tmp" "$f"
    done
    f="$mem/MEMORY.md"
    if [ -f "$f" ] && grep -qE 'read (all|the live) narrative\.\*\.md on resume' "$f"; then
        tmp="$f.tmp"
        sed 's/read all narrative\.\*\.md on resume/its owner reads it in full on resume, anyone else only the lines the resume digest names; older sections under .cs\/narrative-archive\//;s/read the live narrative\.\*\.md on resume, older sections under \.cs\/narrative-archive\//its owner reads it in full on resume, anyone else only the lines the resume digest names; older sections under .cs\/narrative-archive\//' "$f" > "$tmp" \
            && mv "$tmp" "$f"
    fi
    f="$session_dir/CLAUDE.local.md"
    # cs has shipped two protocol-block wordings for the same sentence: the
    # current two-line form, and the July-2026 four-line form ("Note:
    # narratives are per-actor ... so co-developers never / conflict. Append
    # only to your own ... read all / narrative.*.md on resume to restore
    # your working narrative and see teammates' / in-progress findings.").
    # Either grep alternative can match a line that a CRLF checkout split
    # from its neighbour with a trailing \r, so the gate itself does not need
    # \r-tolerance — only the awk's line-for-line comparisons do.
    if [ -f "$f" ] && grep -qE "read all narrative\.\*\.md on resume to restore your|so co-developers never|on resume read the live narrative\.\*\.md \(rotation keeps|lab notebooks \(yours \+ teammates'\)" "$f"; then
        tmp="$f.tmp"
        awk '
            function strip(s) { sub(/\r$/, "", s); return s }
            {
                cur = strip($0)
            }
            cur == "Append only to your own; read all narrative.*.md on resume to restore your" {
                line1 = $0
                getline nextline
                if (strip(nextline) ~ /^working narrative and see teammates/) {
                    print "Append only to your own; on resume read your own in full, and a teammate narrative only"
                    print "from the line the resume digest names for it (nothing, when it names none). Older sections"
                    print "sit under .cs/narrative-archive/<actor>/ — grep on demand, never preload."
                    next
                }
                print line1; print nextline; next
            }
            cur == "3. **.cs/memory/narrative.*.md** - Per-actor lab notebooks (yours + teammates\047): findings, in-progress state, observations" {
                print "3. **.cs/memory/narrative.<actor>.md** - Per-actor lab notebooks: findings, in-progress state, observations. Yours in full; a teammate\047s only where the resume digest says it grew"
                next
            }
            cur == "Append only to your own; on resume read the live narrative.*.md (rotation keeps" {
                line1 = $0
                getline nextline
                if (strip(nextline) ~ /^them small\)\. Older sections sit under/) {
                    print "Append only to your own; on resume read your own in full, and a teammate narrative only"
                    print "from the line the resume digest names for it (nothing, when it names none). Older sections"
                    print "sit under .cs/narrative-archive/<actor>/ — grep on demand, never preload."
                    next
                }
                print line1; print nextline; next
            }
            cur == "Note: narratives are per-actor (narrative.<actor>.md) so co-developers never" {
                line1 = $0
                getline line2
                getline line3
                getline line4
                if (strip(line2) ~ /^conflict\. Append only to your own/ && strip(line3) ~ /^narrative\.\*\.md on resume/) {
                    print "Append only to your own; on resume read your own in full, and a teammate narrative only"
                    print "from the line the resume digest names for it (nothing, when it names none). Older sections"
                    print "sit under .cs/narrative-archive/<actor>/ — grep on demand, never preload."
                    next
                }
                print line1; print line2; print line3; print line4; next
            }
            { print }
        ' "$f" > "$tmp" && mv "$tmp" "$f"
    fi
}

# Migrate existing session to latest format
migrate_session() {
    local session_dir="$1"

    # Sessions created before cs set a mode are still world-readable on disk,
    # and git does not record directory modes, so a fresh clone recreates .cs
    # under the cloner's umask however it was set on the other machine.
    _harden_session_meta "$session_dir"
    # The root only when cs owns it. An adopted session's real directory is the
    # user's project, living wherever they keep it — re-permissioning that on
    # every launch would change their directory behind their back. Testing the
    # PARENT rather than the name: by the time migrate runs, the path has been
    # resolved through the symlink, so the adopted session no longer looks like
    # a link and its basename is the project's, not the session's.
    if _session_root_is_cs_owned "$session_dir"; then
        chmod 700 "$session_dir" 2>/dev/null || true
    fi

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

    # Phase 2a: Convert a legacy line-per-message mail inbox to the maildir,
    # and a legacy line-per-task queue file to the queue directory.
    migrate_mailbox "$session_dir"
    _queue_convert_legacy "$session_dir/.cs/local"

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

    # Phase 13: the resume protocol reads live narratives only; rewrite the
    # read-all sentences cs wrote into files that predate rotation.
    migrate_narrative_resume_wording "$session_dir"

    # Phase 5: move cs-managed sections out of CLAUDE.md, then ensure the
    # protocol is present in CLAUDE.local.md (machine-local, gitignored). A
    # sentinel-free CLAUDE.md that references .cs/ is a pre-sentinel-era cs
    # template: that session stays entirely on CLAUDE.md — extraction cannot
    # be surgical without sentinels, and a second protocol file would
    # duplicate instructions. A wholesale-moved old-template head lacks the
    # leading cs:session-protocol sentinel by definition (that absence is
    # what made it a wholesale-move candidate), so "protocol already
    # present" in CLAUDE.local.md is any cs sentinel at all, not just the
    # leading one — otherwise this fallback would re-append a duplicate
    # fresh template on top of it.
    migrate_claude_md_to_local "$session_dir"
    local claude_md="$session_dir/CLAUDE.md"
    local claude_local="$session_dir/CLAUDE.local.md"
    if ! { [ -f "$claude_local" ] && grep -q '<!-- cs:' "$claude_local"; } \
        && ! { [ -f "$claude_md" ] && grep -q '\.cs/' "$claude_md"; }; then
        if [ -f "$claude_local" ]; then
            printf '\n' >> "$claude_local"
            _emit_session_claude_md >> "$claude_local"
            warn "Appended the cs session protocol to your existing CLAUDE.local.md"
        else
            write_session_claude_md "$session_dir"
        fi
    fi

    # Phase 7: prune retired command-tracker artifacts.
    prune_commands_artifacts "$session_dir"

    # Phase 6: Add YAML frontmatter to README.md if missing
    local readme="$session_dir/.cs/README.md"
    # A trailing CR is stripped before the test: a repo cloned with autocrlf
    # with default autocrlf has "---\r" on line 1, which '^---$' does not match —
    # so this phase read the file as having NO frontmatter and PREPENDED a second
    # block, leaving the original orphaned in the body. Two frontmatter blocks
    # break every reader of it (tags, status, aliases) and strand the
    # machine-local fields outside the bounded block Phase 12 scans.
    if [ -f "$readme" ] && ! head -1 "$readme" | tr -d '\r' | grep -q '^---$'; then
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
        # Temp+mv, like every neighbouring write: redirecting onto the README
        # truncates the user's file before the block writes a byte, so a write
        # that does not complete leaves nothing behind.
        if {
            echo "---"
            echo "status: active"
            echo "created: $created_date"
            echo "tags: []"
            echo "aliases: [\"$session_name\"]"
            echo "---"
            echo "$existing_content"
        } > "$readme.tmp" 2>/dev/null && mv "$readme.tmp" "$readme"; then
            warn "Added frontmatter to .cs/README.md"
        else
            rm -f "$readme.tmp" 2>/dev/null || true
        fi
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
    # Bounded to the frontmatter block: opened by the `---` on line 1 that Phase 6
    # guarantees, and CLOSED by a second one, which it does not. Without a
    # terminator there is no way to tell frontmatter from prose — fm would stay
    # set to EOF and the strip below would delete a body line — so an unclosed
    # block is left entirely alone. All four keys are ordinary English, and the README
    # carries hand-written prose sections, so a body line beginning "updated:"
    # is the user's own content — matching it anywhere in the file deleted it.
    local _fm_field_re='^(claude_session_id|claude_session_color|last_resumed|updated):'
    # Matching is done on a CR-stripped COPY of each line, and the file is written
    # back untouched: a repo cloned with autocrlf enabled
    # arrives as CRLF, where /^---$/ never matches "---\r", fm is never set, and
    # the whole strip silently no-ops.
    if [ -f "$readme" ] && awk -v re="$_fm_field_re" '
            { line = $0; sub(/\r$/, "", line) }
            NR == 1 && line == "---" { fm = 1; next }
            fm && line == "---"      { closed = 1; exit }
            fm && line ~ re          { found = 1 }
            END                      { exit (found && closed) ? 0 : 1 }
        ' "$readme"; then
        local _legacy_uuid _legacy_color
        _legacy_uuid=$(awk '/^claude_session_id:/ { sub(/^claude_session_id:[[:space:]]*/, ""); gsub(/["\r]/, ""); print; exit }' "$readme")
        _legacy_color=$(awk '/^claude_session_color:/ { sub(/^claude_session_color:[[:space:]]*/, ""); gsub(/["\r]/, ""); print; exit }' "$readme")
        if [ -n "$_legacy_uuid" ] && [ -z "$(_read_local_state "$_state" claude_session_id)" ]; then
            _set_local_state "$_state" claude_session_id "$_legacy_uuid"
        fi
        if [ -n "$_legacy_color" ] && [ -z "$(_read_local_state "$_state" claude_session_color)" ]; then
            _set_local_state "$_state" claude_session_color "$_legacy_color"
        fi
        local _tmp="$readme.tmp"
        awk -v re="$_fm_field_re" '
            { line = $0; sub(/\r$/, "", line) }
            NR == 1 && line == "---" { fm = 1; print; next }
            fm && line == "---"      { fm = 0; print; next }
            fm && line ~ re          { next }
            { print }
        ' "$readme" > "$_tmp" && mv "$_tmp" "$readme"
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
    # write_session_claude_md). Phase 5 guarantees the local file for
    # migrated sessions; legacy sessions skip these phases.
    # Phases 9 and 10 manage sections in CLAUDE.local.md ONLY. Sessions
    # still on a legacy CLAUDE.md (pre-sentinel era, or a user file that
    # merely mentions .cs/) are left entirely alone — cs never writes to
    # CLAUDE.md again. Both phases' existing [ -f ] guards make them
    # no-ops when the local file is absent.
    local claude_md_p9="$session_dir/CLAUDE.local.md"
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
            warn "Added cs:memory-note to CLAUDE.local.md"
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

**Strong signals (sufficient on their own — but only when the phrase describes work that actually completed; never fire when it reports a problem, is negated, or is part of a plan for later):**
- "shipped", "PR merged", "PR up", "deployed", "released"
- "let's call it", "wraps up", "done for the day", "good place to stop"
- "all good now", "that did it", "ready to ship"

**Soft signals (require a corroborating signal — a recent commit, an explicit "done", or two or more soft signals in succession):**
- "that works", "looks good", "we're good", "all set"

**When fired**, use AskUserQuestion with header "Wrap up?" and these options:
- "Run /wrap" — distill memory entries AND write a session summary in sequence (the usual choice)
- "Run /sweep only" — just the memory pass; skip the narrative summary
- "Run /summary only" — just the narrative; skip the memory pass
- "Not yet — keep working"

Do not fire on every short affirmative ("yes", "ok", "thanks"). Fire when the *work itself* has reached a coherent stopping point, not when a single answer satisfied a single question. False positives erode the signal — be picky.

To opt out, delete the prose above but keep the `cs:wrap-cues` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
EOF
        warn "Appended session wrap-up cues to CLAUDE.local.md"
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
