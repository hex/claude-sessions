#!/usr/bin/env bash
# ABOUTME: Content invariants for commands/*.md and skills/*/SKILL.md
# ABOUTME: Guards single-source doctrine, deployed-path references, and frontmatter correctness

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

COMMANDS_DIR="$SCRIPT_DIR/../commands"
SKILLS_DIR="$SCRIPT_DIR/../skills"
HOOKS_DIR="$SCRIPT_DIR/../hooks"
# The memory and summary passes /wrap reads; they deploy with the hook libraries.
SWEEP_PASS="$HOOKS_DIR/wrap-sweep.md"
SUMMARY_PASS="$HOOKS_DIR/wrap-summary.md"
RELEASE_MD="$SCRIPT_DIR/../.claude/commands/release.md"

# ============================================================================
# Frontmatter correctness
# ============================================================================

test_checkpoint_allowed_tools_hyphenated() {
    assert_file_contains "$COMMANDS_DIR/checkpoint.md" "allowed-tools:" \
        "checkpoint.md must use the hyphenated allowed-tools key" || return 1
    assert_file_not_contains "$COMMANDS_DIR/checkpoint.md" "allowed_tools" \
        "the underscore form is silently ignored by Claude Code" || return 1
}

test_store_secret_has_frontmatter() {
    local first_line
    first_line=$(head -1 "$SKILLS_DIR/store-secret/SKILL.md")
    assert_eq "---" "$first_line" \
        "store-secret SKILL.md must open with a YAML frontmatter block" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "name: store-secret" \
        "frontmatter must declare the skill name" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "description:" \
        "frontmatter must declare a description (the activation trigger)" || return 1
}

test_store_secret_backend_neutral() {
    assert_file_not_contains "$SKILLS_DIR/store-secret/SKILL.md" "keychain" \
        "storage backend may be the encrypted-file fallback, not a keychain" || return 1
}

# ============================================================================
# Single-source doctrine: the sweep pass owns the memory bar, the summary
# pass owns the skeleton, the prose-hygiene skill owns the scoring rubric
# ============================================================================

test_no_dangling_bucket_guidance_reference() {
    # The CLAUDE.md bucket-guidance table was retired in v2026.5.5 (bin/cs
    # Phase 9 strips it); no command or wrap pass may still point at it.
    local hits
    hits=$(grep -l "bucket-guidance" "$COMMANDS_DIR"/*.md "$SWEEP_PASS" "$SUMMARY_PASS" 2>/dev/null || true)
    assert_eq "" "$hits" \
        "no command or wrap pass may reference the retired CLAUDE.md bucket-guidance table" || return 1
}

test_sweep_owns_bucket_routing_table() {
    assert_file_contains "$SWEEP_PASS" 'user_\*.md' \
        "the sweep pass must carry the bucket routing table (user row)" || return 1
    assert_file_contains "$SWEEP_PASS" 'reference_\*.md' \
        "the sweep pass must carry the bucket routing table (reference row)" || return 1
}

test_sweep_routes_discovered_constraints() {
    # The project_* bucket is dominated by constraints found through work, not user
    # utterances. sweep must route them and must NOT blanket-drop them as "just a discovery".
    assert_file_not_contains "$SWEEP_PASS" "that's a discovery, not a memory" \
        "the blanket 'discovery is not a memory' exclusion drops the project_* class" || return 1
    assert_file_contains "$SWEEP_PASS" "discover while working" \
        "sweep must carry a routing path for constraints discovered through work" || return 1
}

test_sweep_updates_memory_index() {
    assert_file_contains "$SWEEP_PASS" "MEMORY.md" \
        "the sweep pass must instruct updating the MEMORY.md index after writing an entry" || return 1
}

test_wrap_family_pinned_to_opus() {
    # Distilling a whole session's documentation into what is worth keeping is
    # judgment work, and the summary is the artifact the session is remembered
    # by, so /wrap, which runs both passes, runs on the strongest model.
    # The family alias, not a point release: `claude-opus-5` would keep an
    # older Opus once a newer one ships.
    assert_file_contains "$COMMANDS_DIR/wrap.md" "^model: opus$" \
        "wrap.md must pin the opus family, not a point release, in frontmatter" || return 1
    if [ "$(head -1 "$COMMANDS_DIR/wrap.md")" != "---" ]; then
        echo "  FAIL: wrap.md must open with a YAML frontmatter block"
        return 1
    fi
}

test_wrap_references_deployed_passes() {
    assert_file_contains "$COMMANDS_DIR/wrap.md" "~/.claude/hooks/cs/wrap-sweep.md" \
        "wrap.md must reference the deployed sweep pass" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" "~/.claude/hooks/cs/wrap-summary.md" \
        "wrap.md must reference the deployed summary pass" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" '`hooks/wrap-sweep.md`' \
        "repo-relative paths are dead pointers at runtime" || return 1
}

# The guard ships as a hook library, so sweep must call it at its deployed path,
# and must take the snapshot that check and restore compare against.
test_sweep_runs_the_memory_index_guard() {
    local sub
    for sub in snapshot check restore; do
        assert_file_contains "$SWEEP_PASS" "bash ~/.claude/hooks/cs/memory-index-guard.sh $sub" \
            "the sweep pass must run the deployed guard's $sub" || return 1
    done
    assert_file_contains "$SWEEP_PASS" 'bash ~/.claude/hooks/cs/memory-index-guard.sh refs' \
        "the sweep pass must run the deployed guard's refs" || return 1
    assert_file_contains "$SCRIPT_DIR/../lib/01-manifests.sh" "^    memory-index-guard.sh$" \
        "the guard must ship with the hooks for that path to exist" || return 1
}

test_wrap_does_not_duplicate_memory_bars() {
    assert_file_contains "$SWEEP_PASS" "three months" \
        "the sweep pass owns the three-bar discipline" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" "three months" \
        "wrap.md must reference the bars, not restate them" || return 1
}

test_wrap_does_not_duplicate_summary_skeleton() {
    assert_file_contains "$SUMMARY_PASS" "# Session Summary:" \
        "the summary pass owns the summary skeleton" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" "# Session Summary:" \
        "wrap.md must reference the skeleton, not embed a second copy" || return 1
}

test_scoring_threshold_owned_by_skill() {
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "35/50" \
        "the prose-hygiene skill owns the revise threshold" || return 1
    local hits
    hits=$(grep -l "35/50" "$COMMANDS_DIR"/*.md "$SWEEP_PASS" "$SUMMARY_PASS" 2>/dev/null || true)
    assert_eq "" "$hits" \
        "no command or wrap pass may restate the skill's 35/50 threshold" || return 1
}

# ============================================================================
# Correctness strays
# ============================================================================

test_summary_reads_narrative() {
    assert_file_contains "$SUMMARY_PASS" 'memory/narrative\.<actor>\.md' \
        "summary must read the per-actor session narratives" || return 1
    assert_file_contains "$SUMMARY_PASS" "your own in full; a teammate's only from the line the resume digest named" \
        "summary reads its own narrative whole and a teammate's by the digest delta, never the whole file" || return 1
}

# /wrap writes the summary once: the summary pass spawns no critic and runs
# no revise loop, and wrap.md stops after no step of it.
test_summary_pass_runs_no_critic() {
    assert_file_not_contains "$SUMMARY_PASS" "subagent" \
        "the summary pass must not spawn a critic subagent" || return 1
    assert_file_not_contains "$SUMMARY_PASS" "critic" \
        "the summary pass must not run a critic loop" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" "critic" \
        "wrap.md must not describe a critic it skips" || return 1
}

test_prose_hygiene_has_modes_and_technical_carveout() {
    # A cold Skill invocation must be able to tell drafting from reviewing, and the
    # absolutist rules must not flag correct technical sentences.
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "## How to apply" \
        "the skill must surface drafting-vs-reviewing modes, not bury them in prose" || return 1
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "not false agency" \
        "the skill must carve out technical subjects from the false-agency/absolutist rules" || return 1
}

test_release_names_uninstall_source_not_bincs() {
    # run_uninstall lives in a lib/ fragment and bin/cs is assembled — the runbook must
    # name the editable source, since Step 1 and Important both forbid editing bin/cs.
    assert_file_contains "$RELEASE_MD" "lib/85-adopt-uninstall.sh" \
        "release.md must name the editable run_uninstall source, not bin/cs" || return 1
}

test_release_changelog_step_follows_approval() {
    # The changelog insertion needs the approved notes, so its step must come AFTER the
    # notes/approval step in the file — not forward-reference a later step.
    local notes_line changelog_line
    notes_line=$(grep -n 'Generate Release Notes' "$RELEASE_MD" | head -1 | cut -d: -f1)
    changelog_line=$(grep -n 'Update Changelog' "$RELEASE_MD" | head -1 | cut -d: -f1)
    if [ -z "$notes_line" ] || [ -z "$changelog_line" ]; then
        echo "  FAIL: could not find both the notes and changelog step headers"; return 1
    fi
    if [ "$changelog_line" -le "$notes_line" ]; then
        echo "  FAIL: 'Update Changelog' (line $changelog_line) must follow 'Generate Release Notes' (line $notes_line)"; return 1
    fi
}

test_prose_hygiene_records_upstream_sync() {
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "synced at upstream" \
        "the skill must record which stop-slop commit it was synced against" || return 1
}

# ============================================================================
# med+low finding invariants: summary / wrap / checkpoint / sweep guardrails
# ============================================================================

test_summary_replaces_existing_file() {
    # The summary pass must not stall deciding whether to overwrite a
    # pre-existing summary; the replace rule lives in the pass, not only wrap.md.
    assert_file_contains "$SUMMARY_PASS" "already exists, replace it" \
        "the summary pass step 3 must say to replace a pre-existing .cs/summary.md" || return 1
}

test_summary_bounds_git_log_to_session() {
    # 'derive from git history' is unbounded; the file list must be scoped to this
    # session via the timeline's earliest started timestamp, not the whole repo.
    assert_file_contains "$SUMMARY_PASS" "git log --since" \
        "the summary pass must bound the git log to the session, not the whole repo history" || return 1
}

test_wrap_report_is_not_two_line() {
    # 'two-line report' contradicts item 1's 'one path per line' once Pass 1 wrote
    # more than one file; the report must be sectioned, not line-capped.
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" "two-line" \
        "wrap.md must not cap the report at two lines (item 1 lists one path per line)" || return 1
}

test_checkpoint_routes_reserved_subcommands() {
    # run_checkpoint reserves list/ls/show; '/checkpoint list' must route to the
    # subcommand, not save a checkpoint labelled 'list' and report a phantom save.
    assert_file_contains "$COMMANDS_DIR/checkpoint.md" "Route reserved words to the matching subcommand" \
        "checkpoint.md must route list/ls/show to their subcommands instead of saving a label" || return 1
}

test_checkpoint_quotes_label_and_stops_on_failure() {
    # A label with a double quote, $, or backtick breaks or injects under double quotes;
    # single-quote it, and never silently retry a failed save.
    assert_file_contains "$COMMANDS_DIR/checkpoint.md" "single-quoting the label" \
        "checkpoint.md must single-quote the label, not double-quote it" || return 1
    assert_file_contains "$COMMANDS_DIR/checkpoint.md" "do not retry" \
        "checkpoint.md must stop (not retry) when cs -checkpoint fails" || return 1
}

test_sweep_supersedes_stale_entries() {
    # 'skip; do not append' with no supersede path leaves reversed/refined facts stale
    # forever; a contradicting or extending fact must update the entry in place.
    assert_file_contains "$SWEEP_PASS" "contradicts or materially extends" \
        "the sweep pass must give a supersede/update-in-place path, not only skip-or-duplicate" || return 1
}

test_sweep_stamps_measured_claims_with_their_provenance() {
    # A fact that holds because something was run (a Claude Code build, a cs
    # version) reads as timeless once written; nothing in the entry says when it
    # stops being trustworthy. The sweep must make the body name what the claim
    # was measured on, so a later session re-measures instead of trusting it.
    assert_file_contains "$SWEEP_PASS" "A measured claim names what it was measured on" \
        "the sweep pass must require provenance on measured claims" || return 1
    assert_file_contains "$SWEEP_PASS" "measured on Claude Code <version>" \
        "the sweep pass must show the provenance line's shape as a placeholder, not a copyable value" || return 1
}

test_sweep_names_the_entry_each_new_one_supersedes() {
    # The supersede path exists (test above) but nothing makes the model look
    # for the entry a new fact replaces; the dedup read catches paraphrases of
    # the same fact, not an older fact the new one overturns. Each written entry
    # must name what it supersedes, or state none, in the sweep's report.
    assert_file_contains "$SWEEP_PASS" "the entry it supersedes" \
        "the sweep pass must make each new entry name the one it supersedes" || return 1
    assert_file_contains "$SWEEP_PASS" "supersedes: none" \
        "the sweep pass must give the no-supersede form so the check is never skipped silently" || return 1
    # /wrap tells the model to skip the sweep's own report and emit its combined
    # one instead, so the answer is dead output unless that report carries it too.
    assert_file_contains "$COMMANDS_DIR/wrap.md" "supersedes: none" \
        "wrap.md's combined report must carry the supersedes answer the sweep decided" || return 1
}

test_sweep_bounds_the_dead_reference_pass() {
    # The first sweep after the check ships meets a backlog; unbounded, it is a
    # bulk edit of durable memory. A file in another repo or under ~/.claude is
    # not gone, and a "gone" sentence about it would be a written falsehood.
    assert_file_contains "$SWEEP_PASS" "at most five" \
        "the sweep pass must bound the dead-reference work per sweep" || return 1
    assert_file_contains "$SWEEP_PASS" "outside this checkout" \
        "the sweep pass must distinguish a file elsewhere from a file that is gone" || return 1
    assert_file_contains "$SWEEP_PASS" 'append ` [(]gone YYYY-MM-DD[)]` immediately after its backticked reference' \
        "the sweep pass must mark a gone reference where refs can skip it" || return 1
    assert_file_contains "$SWEEP_PASS" 'Delete a marker if its reference resolves again' \
        "the sweep pass must remove a gone marker that is no longer true" || return 1
}

test_sweep_states_filename_convention() {
    # The <bucket>_<short_slug>.md convention was only implied by the glob; a first
    # entry in an empty bucket needs it stated explicitly.
    assert_file_contains "$SWEEP_PASS" "<bucket>_<short_slug>.md" \
        "the sweep pass must state the memory-entry filename convention" || return 1
}

test_sweep_scopes_when_not_to_write() {
    # The exclusion section must be scoped to the strict buckets so it does not
    # suppress the looser-bar narrative appends step 4 invites.
    assert_file_contains "$SWEEP_PASS" "strict-bucket entry" \
        "the sweep pass 'When NOT to write' must scope to the strict buckets, not the narrative" || return 1
}

test_sweep_states_memory_pointer_format() {
    # 'Add a one-line pointer' with no format leaves the model to invent the MEMORY.md
    # line shape; it must match the existing [title](file.md) format.
    assert_file_contains "$SWEEP_PASS" '\[title\](file.md)' \
        "the sweep pass must state the MEMORY.md pointer format" || return 1
}

test_sweep_demotes_pointers_to_the_archive_before_rewording() {
    # Step 5's first remedy for an index over budget is moving a pointer line,
    # unchanged, into the archive the guard reads as a second pointer source;
    # rewording comes after, and a rule that must fire before a proposal stays.
    assert_file_contains "$SWEEP_PASS" '\.cs/memory/reference_memory_archive\.md' \
        "the sweep pass must name the archive file" || return 1
    assert_file_contains "$SWEEP_PASS" 'demote first' \
        "demotion must come before rewording" || return 1
    assert_file_contains "$SWEEP_PASS" 'a subject that no longer exists' \
        "the sweep pass must state the finished-subject criterion" || return 1
    assert_file_contains "$SWEEP_PASS" 'a test, hook or CI lane now enforces' \
        "the sweep pass must state the enforced-rule criterion" || return 1
    assert_file_contains "$SWEEP_PASS" 'has to fire before a proposal stays in `MEMORY\.md`' \
        "a rule that fires before a proposal must stay in the index" || return 1
    assert_file_contains "$SWEEP_PASS" 'byte for byte' \
        "a demoted pointer moves verbatim" || return 1
    assert_file_contains "$SWEEP_PASS" 'A `narrative\.\*\.md` pointer is never demoted' \
        "a narrative pointer stays in the index" || return 1
    # Two clones that each make a first demotion write the same header, so a
    # merge keeps one; nothing edits it after.
    assert_eq '---
name: memory-archive
description: "Pointers moved out of MEMORY.md; each entry still applies when its subject comes up"
metadata:
  type: reference
---' "$(awk '/^ *```markdown$/{on=1; next} on && /^ *```$/{exit} on' "$SWEEP_PASS" | sed 's/^   //')" \
        "the sweep pass gives the archive's exact frontmatter" || return 1
    assert_file_contains "$SWEEP_PASS" "Never edit the archive's frontmatter" \
        "the archive's frontmatter is written once" || return 1
    assert_file_contains "$SWEEP_PASS" "delete the archive's copy" \
        "a wrongly demoted rule goes back to the index on duplicate:" || return 1
    assert_file_contains "$SWEEP_PASS" 'keep the other copy as it stands' \
        "duplicate: deletes one copy and rewords neither" || return 1
    assert_file_contains "$SWEEP_PASS" 'a bare file name ending in `\.md`, with no `/` and no `:`' \
        "the sweep pass states which pointers dangling: checks" || return 1
    local label
    for label in 'demoted:' 'duplicate:' 'dangling:'; do
        assert_file_contains "$SWEEP_PASS" "\`$label\`" \
            "the sweep pass must say what check's $label means" || return 1
    done
}

test_sweep_resolves_actor_before_narrative_append() {
    # cs -whoami resolution must be repeated at the narrative step, not left only in the
    # framing parenthetical, so a multi-actor session appends to the right file.
    local count
    count=$(grep -c "cs -whoami" "$SWEEP_PASS" || true)
    if [ "$count" -lt 2 ]; then
        echo "  FAIL: the sweep pass must repeat 'cs -whoami' in the narrative step (found $count)"
        return 1
    fi
}

test_sweep_adds_check_tasks_and_keeps_the_entry() {
    # A rule-shaped entry usually carries the incident or measurement behind the rule,
    # which a check's failure message would lose, so a check that can carry the rule
    # becomes a task beside the entry, never a replacement for it.
    assert_file_contains "$SWEEP_PASS" "Could a check carry it instead" \
        "the sweep pass must ask whether a mechanical check could carry a rule" || return 1
    assert_file_contains "$SWEEP_PASS" "add a task to build it and keep the memory entry as written" \
        "the sweep pass must add a task for the check and keep the memory entry, never replace it" || return 1
}

# The sweep opens with the snags pass: where the session struggled, each moment named,
# routed to the fix that stops the repeat, and filed as a task the user picks,
# never applied by the pass. An unanchored candidate is generic advice and is dropped.
test_sweep_snags_propose_anchored_fixes_as_tasks() {
    assert_file_contains "$SWEEP_PASS" '^2\. \*\*Snags: where did this session struggle' \
        "the snags pass is the sweep's second step, before the fact bars" || return 1
    assert_file_contains "$SWEEP_PASS" 'Discard any candidate you cannot trace to one moment' \
        "an unanchored candidate is dropped" || return 1
    assert_file_contains "$SWEEP_PASS" 'A steering line that changed nothing | Delete it' \
        "the routing table includes deleting a no-op steering line" || return 1
    assert_file_contains "$SWEEP_PASS" 'A skill that would have helped and never fired | Tune that skill' \
        "a skill that never fired gets its description tuned" || return 1
    assert_file_contains "$SWEEP_PASS" 'never in one it only could have used' \
        "a fix lands only where the session read or ran" || return 1
    assert_file_contains "$SWEEP_PASS" 'never a second copy' \
        "guidance already present is reworded or placed, not duplicated" || return 1
    assert_file_contains "$SWEEP_PASS" 'Propose, never apply' \
        "the snags pass files tasks and edits nothing" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" '\*\*Snags:\*\*' \
        "the wrap report carries a snags item" || return 1
}

# ============================================================================
# lane 1b: store-secret guardrails, prose-hygiene scoring contract, release runbook
# ============================================================================

test_store_secret_opener_softened_and_stops_on_nothing() {
    # The skill fires proactively and misfires on docs/examples; the opener must not
    # assert detection as fact, and there must be a 'nothing qualifies' stop branch so a
    # primed model does not strain to store a non-secret.
    assert_file_not_contains "$SKILLS_DIR/store-secret/SKILL.md" "You detected that the user shared" \
        "the opener must not assert detection as established fact (the skill misfires)" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "nothing was stored and stop" \
        "the skill must have a stop branch for when every candidate is a placeholder/example" || return 1
}

test_store_secret_guards_silent_overwrite() {
    # cs -secrets set replaces an existing name silently; names are inferred, so two
    # keys can collide. The skill must warn before overwriting.
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "replaces an existing value silently" \
        "the skill must state that set overwrites silently" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "before overwriting" \
        "the skill must tell the model to confirm/rename before overwriting a colliding name" || return 1
}

test_store_secret_non_session_warns_and_forbids_file() {
    # The non-cs-session branch must not dead-end at 'skip storage' leaving a live
    # credential in chat with no guidance, and must forbid the file-write fallback.
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "conversation history" \
        "the non-session branch must warn the credential is now in the chat history" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "NEVER write the value to a project file" \
        "the non-session branch must forbid writing the secret to a project file" || return 1
}

test_store_secret_confirms_only_on_success() {
    # Step 5 must gate its success message on the set command actually succeeding, not
    # report success blindly if set errored (missing backend, session mismatch).
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "Stored secret: NAME" \
        "step 5 must key confirmation off the real success string set prints" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "report the failure" \
        "step 5 must report failure rather than claim a secret was stored" || return 1
}

test_prose_hygiene_scoring_reports_either_way_and_defers_revision() {
    # The Scoring section's bare 'means revise' left who-revises/what-to-output/loop
    # unstated. The skill judges only (revising and any loop are the caller's); it must
    # report the total whether or not it passes.
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "This skill only judges" \
        "scoring must state the skill judges only and reports the total either way" || return 1
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "belong to the caller" \
        "scoring must defer revising and the re-score loop to the caller (judge-only)" || return 1
}

test_release_has_branch_sync_preflight() {
    # Without a starting precondition the runbook will bump/commit/tag from a feature
    # branch or a stale main; a preflight must check branch and origin sync.
    assert_file_contains "$RELEASE_MD" "git status -sb" \
        "release.md must show a branch/ahead-behind preflight before Step 1" || return 1
    assert_file_contains "$RELEASE_MD" "up to date with origin" \
        "release.md must require being on main and up to date with origin before proceeding" || return 1
}

test_release_doc_review_has_procedure() {
    # The doc review is called 'the most important part' but was stated only as goals;
    # it must carry a concrete grep-against-source procedure and a required per-file report.
    assert_file_contains "$RELEASE_MD" "do not skim" \
        "the doc review must give a concrete verification procedure, not just goals" || return 1
    assert_file_contains "$RELEASE_MD" "issues found / fixed" \
        "the doc review must require an auditable per-file report" || return 1
}

test_release_empty_diff_expected_when_committed() {
    # The empty-diff caveat conflated the working-tree diff with release content; when
    # release work was committed earlier (the normal case) an empty /simplify diff is not
    # an anomaly. The caveat must say so and must not send the model chasing a non-anomaly.
    assert_file_contains "$RELEASE_MD" "already committed in earlier sessions" \
        "the empty-diff caveat must treat committed-earlier as the expected case" || return 1
    assert_file_not_contains "$RELEASE_MD" "zero code changes is unusual" \
        "the misleading 'zero code changes is unusual' framing must be gone" || return 1
}

test_release_handles_empty_prev_tag() {
    # If no v* tag exists (first release / failed fetch) PREV_TAG is empty and
    # git log ""..HEAD errors; the runbook must branch to a first-release path.
    assert_file_contains "$RELEASE_MD" "is empty (first release" \
        "release.md must handle an empty PREV_TAG as a first release" || return 1
}

test_release_approval_has_cancel_and_reapproval_loop() {
    # The approval gate offered only Approve/Edit with no abort and no restated loop;
    # it must add a cancel path and require re-approval after edits.
    assert_file_contains "$RELEASE_MD" "Cancel release" \
        "the approval gate must offer an abort path" || return 1
    assert_file_contains "$RELEASE_MD" "looping until you get an explicit" \
        "the approval gate must re-confirm after edits, not treat Edit as approval" || return 1
}

test_release_guards_stray_files_before_add_all() {
    # git add -A after git status had no branch for stray untracked files; the runbook
    # must tell the model to stage release files explicitly when status shows strays.
    assert_file_contains "$RELEASE_MD" "files unrelated to" \
        "release.md must handle stray files that git status reveals" || return 1
    assert_file_contains "$RELEASE_MD" "stage the release files explicitly" \
        "release.md must say to stage explicitly (not -A) when strays are present" || return 1
}

test_release_verifies_ci_workflow() {
    # 'gh release create' returning is not the finish line; the release workflow can
    # still fail. The runbook must verify the workflow and the signed assets landed.
    assert_file_contains "$RELEASE_MD" "Verify the Release Workflow Succeeded" \
        "release.md must add a step to confirm the CI release workflow succeeded" || return 1
    assert_file_contains "$RELEASE_MD" "release is not done until" \
        "release.md must gate completion on the signature asset" || return 1
    assert_file_contains "$RELEASE_MD" 'ssh-keygen -Y sign' \
        "release.md must sign the manifest locally after CI succeeds" || return 1
    assert_file_contains "$RELEASE_MD" 'git show "\${tag}:lib/00-header.sh".*VERSION=' \
        "release.md must confirm the tag names the tagged commit's VERSION before signing" || return 1
    assert_file_contains "$RELEASE_MD" 'gh release upload.*SHA256SUMS.sig' \
        "release.md must upload the manifest signature" || return 1
    assert_file_contains "$RELEASE_MD" 'git show.*:install.sh' \
        "release.md must compare the installer with its committed tag" || return 1
    assert_file_contains "$RELEASE_MD" 'diff -u.*install.sh' \
        "release.md must refuse an installer changed by CI" || return 1
    assert_file_contains "$RELEASE_MD" 'shasum -a 256 -c SHA256SUMS' \
        "release.md must support the macOS digest tool" || return 1
    assert_file_contains "$RELEASE_MD" 'RELEASE_SIGNING_KEY' \
        "release.md must describe the signing key override" || return 1
}

test_release_uses_ci_wait_for_each_workflow_gate() {
    local calls
    calls=$(awk '
        /^### / { step = $2 }
        /^bash tests\/ci_wait.sh / && (step == "0b." || step == "8c." || step == "10.") {
            print step "\t" $0
        }
    ' "$RELEASE_MD")
    assert_eq $'0b.\tbash tests/ci_wait.sh "$RUN_ID" --since "$PREV_TAG"\n8c.\tbash tests/ci_wait.sh "$RUN_ID" --since "$PREV_TAG"\n10.\tbash tests/ci_wait.sh "$RUN_ID"' "$calls" \
        'release steps 0b, 8c and 10 must call ci_wait with the right range' || return 1
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_commands.sh"
echo ""

# /wrap's last pass marks the conversation it ran in, so the rotate band stops
# offering a wrap that already finished. The command is run exactly as the file
# spells it. It writes the running conversation's own id (a teammate's wrap
# names the teammate, never the lead), and with no id to write it writes nothing
# and still succeeds, since a wrap outside Claude Code has no band to hide.
test_wrap_marks_the_wrapped_conversation() {
    local block dir
    block=$(awk '/^## Pass [0-9]+ — Mark the wrap finished/{p=1; next} /^## /{p=0} p && /^```/{f=!f; next} p && f' "$COMMANDS_DIR/wrap.md")
    [ -n "$block" ] || { echo "  FAIL: wrap.md has no command block under its Mark the wrap finished pass"; return 1; }
    dir="$TEST_TMPDIR/wrapped"
    mkdir -p "$dir/.cs/local" "$TEST_TMPDIR/csbin"
    ln -sf "$SCRIPT_DIR/../bin/cs" "$TEST_TMPDIR/csbin/cs"
    printf 'claude_session_id: 99999999-9999-4999-8999-999999999999\n' > "$dir/.cs/local/state"
    (cd "$dir" && PATH="$TEST_TMPDIR/csbin:$PATH" CLAUDE_CODE_SESSION_ID=11111111-2222-4333-8444-555555555555 bash -c "$block") \
        || { echo "  FAIL: the Pass 4 command failed"; return 1; }
    assert_eq "11111111-2222-4333-8444-555555555555" "$(cat "$dir/.cs/local/wrapped")" \
        "the marker names the conversation the wrap ran in, not the state's lead" || return 1
    rm -f "$dir/.cs/local/wrapped"
    (cd "$dir" && PATH="$TEST_TMPDIR/csbin:$PATH" env -u CLAUDE_CODE_SESSION_ID bash -c "$block") \
        || { echo "  FAIL: the Pass 4 command must succeed with no conversation id"; return 1; }
    assert_not_exists "$dir/.cs/local/wrapped" "no id, no marker" || return 1
    # cs is asked first, and while git tracks the control files it refuses and
    # the pass adds nothing there, still succeeding: the wrap itself finished.
    git -C "$dir" init -q
    git -C "$dir" add .cs/local/state
    git -C "$dir" -c user.name=t -c user.email=t@example.com commit -q -m tracked
    (cd "$dir" && PATH="$TEST_TMPDIR/csbin:$PATH" CLAUDE_CODE_SESSION_ID=11111111-2222-4333-8444-555555555555 \
        bash -c "$block" 2>/dev/null) \
        || { echo "  FAIL: the Pass 4 command must succeed while git tracks the control files"; return 1; }
    assert_eq "" "$(git -C "$dir" status --porcelain --ignored -- .cs/local)" \
        "nothing is added under a tracked .cs/local" || return 1
}

run_test test_checkpoint_allowed_tools_hyphenated
run_test test_store_secret_has_frontmatter
run_test test_store_secret_backend_neutral
run_test test_no_dangling_bucket_guidance_reference
run_test test_sweep_owns_bucket_routing_table
run_test test_sweep_routes_discovered_constraints
run_test test_sweep_updates_memory_index
run_test test_wrap_family_pinned_to_opus
run_test test_wrap_references_deployed_passes
run_test test_sweep_runs_the_memory_index_guard
run_test test_wrap_does_not_duplicate_memory_bars
run_test test_wrap_does_not_duplicate_summary_skeleton
run_test test_scoring_threshold_owned_by_skill
run_test test_summary_reads_narrative
run_test test_summary_pass_runs_no_critic
run_test test_prose_hygiene_has_modes_and_technical_carveout
run_test test_release_names_uninstall_source_not_bincs
run_test test_release_changelog_step_follows_approval
run_test test_prose_hygiene_records_upstream_sync
run_test test_summary_replaces_existing_file
run_test test_summary_bounds_git_log_to_session
run_test test_wrap_report_is_not_two_line
run_test test_checkpoint_routes_reserved_subcommands
run_test test_checkpoint_quotes_label_and_stops_on_failure
run_test test_sweep_supersedes_stale_entries
run_test test_sweep_stamps_measured_claims_with_their_provenance
run_test test_sweep_names_the_entry_each_new_one_supersedes
run_test test_sweep_bounds_the_dead_reference_pass
run_test test_sweep_states_filename_convention
run_test test_sweep_scopes_when_not_to_write
run_test test_sweep_states_memory_pointer_format
run_test test_sweep_demotes_pointers_to_the_archive_before_rewording
run_test test_sweep_resolves_actor_before_narrative_append
run_test test_sweep_adds_check_tasks_and_keeps_the_entry
run_test test_sweep_snags_propose_anchored_fixes_as_tasks
run_test test_store_secret_opener_softened_and_stops_on_nothing
run_test test_store_secret_guards_silent_overwrite
run_test test_store_secret_non_session_warns_and_forbids_file
run_test test_store_secret_confirms_only_on_success
run_test test_prose_hygiene_scoring_reports_either_way_and_defers_revision
test_release_has_code_review_gate() {
    assert_file_contains "$RELEASE_MD" "Code-Review the Release Range" \
        "release.md must carry a correctness review step" || return 1
    assert_file_contains "$RELEASE_MD" "Critical and Important findings are fixed" \
        "the code-review step must block on Critical/Important findings" || return 1
    assert_file_contains "$RELEASE_MD" "touches documentation alone" \
        "the code-review step must state its docs-only skip condition" || return 1
}

run_test test_release_has_branch_sync_preflight
run_test test_release_doc_review_has_procedure
run_test test_release_empty_diff_expected_when_committed
run_test test_release_handles_empty_prev_tag
run_test test_release_approval_has_cancel_and_reapproval_loop
run_test test_release_guards_stray_files_before_add_all
run_test test_release_verifies_ci_workflow
run_test test_release_uses_ci_wait_for_each_workflow_gate
run_test test_release_has_code_review_gate

# A shared .cs/memory/ makes "the user is X" false on every other actor's
# machine, while "actor <slug> is X" stays true everywhere. The rule has to
# cover MEMORY.md pointer lines too: those load at startup, whereas the bucket
# files they point at are only read lazily, so a poisoned pointer reaches
# context even when nothing opens the entry.
test_sweep_requires_identity_facts_to_be_keyed() {
    assert_file_contains "$SWEEP_PASS" "keyed" \
        "the sweep pass must require identity facts to be keyed to an actor" || return 1
    assert_file_contains "$SWEEP_PASS" "pointers load at startup" \
        "the rule must govern index pointer lines, not just entry bodies" || return 1
}

run_test test_sweep_requires_identity_facts_to_be_keyed

# The empirical remit. A reviewer reading a diff sees a rule once; a reviewer
# measuring it against the real population leaves the defect nowhere to sit.
# The corpus redactor survived 29 releases because every review after it was
# scoped to the range that release touched.
test_release_gate_mandates_an_empirical_pass() {
    assert_file_contains "$RELEASE_MD" "run it against the real population" \
        "Step 4b must require measuring a rule against real data, not reading the diff" || return 1
    assert_file_contains "$RELEASE_MD" "how often it fires" \
        "Step 4b must require reporting the firing rate" || return 1
    assert_file_contains "$RELEASE_MD" "author cannot supply that measurement" \
        "Step 4b must exclude the author from supplying their own measurement" || return 1
    assert_file_contains "$RELEASE_MD" "wrongly destroys" \
        "Step 4b must require testing both directions, not only what leaks" || return 1
}

run_test test_release_gate_mandates_an_empirical_pass

test_wrap_rotates_the_narrative_after_the_summary() {
    assert_file_contains "$COMMANDS_DIR/wrap.md" "## Pass 3 — Narrative rotation" \
        "wrap has a third pass" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" 'cs -narrative rotate' \
        "the pass runs the cs helper rather than describing file surgery" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" '4\. \*\*Narrative:\*\*' \
        "the report gains a fourth item" || return 1
}

# A wrap makes no commit (Alex, 2026-10-14: "No commits at all"): the memory
# entries, the summary, the narrative cut and the task archive stay on disk,
# and files under .cs/ are committed only when the user asks. The command says
# so in its archive pass, gives no git add or git commit to run, and its
# report has no commit item.
test_wrap_makes_no_commit() {
    local pass4
    pass4=$(awk '/^## Pass 4 /{p=1; print; next} /^## /{p=0} p' "$COMMANDS_DIR/wrap.md")
    assert_eq "## Pass 4 — Task archive" "$(printf '%s\n' "$pass4" | head -1)" \
        "the fourth pass is the task archive alone" || return 1
    assert_output_contains "$pass4" "The wrap makes no commit." "the pass says no commit is made" || return 1
    assert_output_contains "$pass4" "stay on disk, uncommitted" "and that the files stay on disk" || return 1
    assert_output_contains "$pass4" "commit them only when the user asks." \
        "and that only the user's ask commits them" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" "git commit" "the wrap runs no git commit" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" "git add" "and stages nothing" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" "session: wrap" "and names no commit subject" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" '\*\*Commit:\*\*' "the report has no commit item" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" 'the five labeled items below' "it has five items" || return 1
}


# /wrap archives completed task rows the way /rotate does, from the one place
# the procedure is written (the rotate skill's step 8), after the narrative
# pass and before the pass that marks the wrap finished, and reports the line.
test_wrap_archives_completed_task_rows() {
    local passes
    passes=$(grep '^## Pass ' "$COMMANDS_DIR/wrap.md" | sed 's/ — .*//; s/^## //' | tr '\n' ',')
    assert_eq "Pass 1,Pass 2,Pass 3,Pass 4,Pass 5," "$passes" "wrap runs five passes" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" "^## Pass 4 — Task archive" "the fourth pass archives task rows" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" "^## Pass 5 — Mark the wrap finished" "marking the wrap stays last" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" '/\.claude/skills/rotate/SKILL\.md` step 8' \
        "the pass follows the rotate skill's step rather than restating it" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" '5\. \*\*Tasks:\*\*' "the report gains a fifth item" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" 'ask as step 8 does for `forced: no`, whatever the plan'"'"'s `forced:` line says' \
        "a wrap is never a forced rotation, so it asks as a manual /rotate does" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" 'CS_ROTATE_FORCE_CTX' "the threshold setting decides nothing here" || return 1
}

test_summary_reads_live_narratives_not_archives() {
    assert_file_not_contains "$SUMMARY_PASS" "read all of them" \
        "the read-all instruction is gone" || return 1
    assert_file_contains "$SUMMARY_PASS" "narrative-archive" \
        "summary knows where older sections went" || return 1
}

run_test test_wrap_rotates_the_narrative_after_the_summary
run_test test_wrap_makes_no_commit
run_test test_wrap_archives_completed_task_rows
run_test test_wrap_marks_the_wrapped_conversation
run_test test_summary_reads_live_narratives_not_archives

report_results
