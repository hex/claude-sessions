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
        local current
        current=$(cat "$settings_file")
        echo "$current" | jq --arg m "$memory_path" \
            '.autoMemoryDirectory = $m | .plansDirectory = ".cs/plans"' > "$settings_file"
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
    real_path="$(cd "$session_dir" 2>/dev/null && pwd -P)"
    local encoded_path
    encoded_path=$(_claude_encode_path "$real_path")
    local old_memory_dir="$HOME/.claude/projects/${encoded_path}/memory"
    if [ -d "$old_memory_dir" ] && [ "$(ls -A "$old_memory_dir" 2>/dev/null)" ]; then
        cp -n "$old_memory_dir"/* "$session_dir/.cs/memory/" 2>/dev/null || true
        rm -rf "$old_memory_dir"
    fi
}

# Ensure the session narrative topic file and its MEMORY.md index pointer exist.
# The narrative is the looser-bar lab notebook, held as a native memory topic
# file so it inherits lazy-load and /memory tooling. Idempotent: creates the
# stub on first run and re-adds the index pointer if a memory write dropped it.
ensure_narrative_file() {
    local session_dir="$1"
    local mem_dir="$session_dir/.cs/memory"
    local index="$mem_dir/MEMORY.md"
    mkdir -p "$mem_dir"

    local actor
    actor=$(cs_actor_slug "$session_dir")
    local narrative="$mem_dir/narrative.$actor.md"

    # One-time migration: a pre-per-actor narrative.md becomes this actor's file.
    if [ -f "$mem_dir/narrative.md" ] && [ ! -f "$narrative" ]; then
        mv "$mem_dir/narrative.md" "$narrative"
    fi

    if [ ! -f "$narrative" ]; then
        cat > "$narrative" << EOF
---
name: session-narrative-$actor
description: Session lab-notebook and work-in-progress narrative for $actor. Looser bar than durable memory. Read all narrative.*.md on resume.
type: narrative
---
# Session narrative ($actor)

EOF
    fi

    # Drop the legacy single-narrative index pointer if a migration left it stale.
    # Temp+mv instead of sed -i: the BSD `sed -i ''` form errors on GNU sed and
    # would abort session resume on Linux under set -e.
    if [ -f "$index" ] && grep -q '(narrative\.md)' "$index" 2>/dev/null; then
        sed '/(narrative\.md)/d' "$index" > "$index.tmp" && mv "$index.tmp" "$index"
    fi

    if [ ! -f "$index" ] || ! grep -q "(narrative\.$actor\.md)" "$index" 2>/dev/null; then
        printf -- '- [Session narrative — %s (lab notebook)](narrative.%s.md): looser-bar work-in-progress; read all narrative.*.md on resume\n' "$actor" "$actor" >> "$index"
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
Claude's built-in memory writes durable facts to `.cs/memory/` (cs redirects via `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE`); the `MEMORY.md` index lists entries and individual `<bucket>_*.md` files are loaded lazily.
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

When resuming this session, read the following files to restore context:

1. **.cs/summary.md** - If exists, read first for previous session overview
2. **.cs/README.md** - Session objective, environment, and outcome
3. **.cs/memory/narrative.*.md** - Per-actor lab notebooks (yours + teammates'): findings, in-progress state, observations

Note: narratives are per-actor (narrative.<actor>.md) so co-developers never
conflict. Append only to your own (run `cs -whoami` for your actor); read all
narrative.*.md on resume to restore your working narrative and see teammates'
in-progress findings.

## Documentation Discipline

Update the markdown documentation files throughout the session:

1. **Start of session:** Fill in .cs/README.md objective and environment
2. **As you work:** Update .cs/memory/narrative.md with findings
3. **End of session:** Complete the .cs/README.md outcome section

Treat these files as a lab notebook - document as you go, not just at the end.

## Wrap-up Command

When the session is complete, use the `/wrap` command to distill durable memory entries and generate an intelligent summary of the entire session (.cs/summary.md). Use `/summary` for the narrative alone, or `/sweep` for the memory pass alone.

## Secure Secrets Handling

Store sensitive data (API keys, tokens, passwords) securely (macOS Keychain or
encrypted file) instead of writing it into project files. The `store-secret`
skill and `cs -secrets set` read the value from stdin so it never lands in a
file or the command log.

**Retrieving secrets:**
```bash
cs -secrets backend                # Check which storage backend is active
cs -secrets list                   # List secrets for current session
cs -secrets get API_KEY            # Get a specific secret value
cs -secrets export                 # Export as environment variables
```

**If you detect sensitive data** in the workspace (embedded credentials, a
committed token, etc.), store it with the `store-secret` skill and replace it
with a reference. The skill writes the value to a scratch file with the Write
tool (which the bash-logger does not capture) and feeds it in via a stdin
redirect, so the plaintext never reaches argv or the command log:
```bash
cs -secrets set <name> < /path/to/scratch-file   # value on stdin, not in argv
```
Never `echo`/`printf` a secret into a pipe — the bash-logger records the whole
Bash command (secret and all) in `.cs/local/session.log`.

EOF
    _emit_memory_note_block
    cat << 'EOF'

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

## Best Practices

- Document findings in .cs/memory/narrative.md as you go - don't wait until the end
- Run `/wrap` at the end to distill memory and create a cohesive record
- Never write raw API keys or passwords to project files - use cs -secrets
EOF
}

# Write the session CLAUDE.md template to the given directory (create path).
write_session_claude_md() {
    local session_dir="$1"
    _emit_session_claude_md > "$session_dir/CLAUDE.md"
}

# Generate a v4 UUID, lowercased. uuidgen on BSD (macOS) returns uppercase;
# Linux uuidgen and /proc are already lowercase. Lowercasing keeps the
# value consistent with how Claude Code stores its session jsonl paths.
