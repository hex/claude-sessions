#!/usr/bin/env bash
# ABOUTME: Content invariants for commands/*.md and skills/*/SKILL.md
# ABOUTME: Guards single-source doctrine, deployed-path references, and frontmatter correctness

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

COMMANDS_DIR="$SCRIPT_DIR/../commands"
SKILLS_DIR="$SCRIPT_DIR/../skills"
HOOKS_DIR="$SCRIPT_DIR/../hooks"
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
# Single-source doctrine: sweep owns the memory bar, summary owns the
# skeleton and prose gate, the prose-hygiene skill owns the scoring rubric
# ============================================================================

test_no_dangling_bucket_guidance_reference() {
    # The CLAUDE.md bucket-guidance table was retired in v2026.5.5 (bin/cs
    # Phase 9 strips it); no command may still point at it.
    local hits
    hits=$(grep -l "bucket-guidance" "$COMMANDS_DIR"/*.md 2>/dev/null || true)
    assert_eq "" "$hits" \
        "no command may reference the retired CLAUDE.md bucket-guidance table" || return 1
}

test_sweep_owns_bucket_routing_table() {
    assert_file_contains "$COMMANDS_DIR/sweep.md" 'user_\*.md' \
        "sweep.md must carry the bucket routing table (user row)" || return 1
    assert_file_contains "$COMMANDS_DIR/sweep.md" 'reference_\*.md' \
        "sweep.md must carry the bucket routing table (reference row)" || return 1
}

test_sweep_routes_discovered_constraints() {
    # The project_* bucket is dominated by constraints found through work, not user
    # utterances. sweep must route them and must NOT blanket-drop them as "just a discovery".
    assert_file_not_contains "$COMMANDS_DIR/sweep.md" "that's a discovery, not a memory" \
        "the blanket 'discovery is not a memory' exclusion drops the project_* class" || return 1
    assert_file_contains "$COMMANDS_DIR/sweep.md" "discover while working" \
        "sweep must carry a routing path for constraints discovered through work" || return 1
}

test_sweep_updates_memory_index() {
    assert_file_contains "$COMMANDS_DIR/sweep.md" "MEMORY.md" \
        "sweep.md must instruct updating the MEMORY.md index after writing an entry" || return 1
}

test_wrap_family_pinned_to_sonnet() {
    # The wrap/sweep/summary passes are distillation work, not development;
    # they run on Sonnet so a wrap never burns the heavyweight model.
    local cmd
    for cmd in wrap.md sweep.md summary.md; do
        assert_file_contains "$COMMANDS_DIR/$cmd" "^model: claude-sonnet-5" \
            "$cmd must pin model: claude-sonnet-5 in frontmatter" || return 1
        if [ "$(head -1 "$COMMANDS_DIR/$cmd")" != "---" ]; then
            echo "  FAIL: $cmd must open with a YAML frontmatter block"
            return 1
        fi
    done
}

test_wrap_references_deployed_commands() {
    assert_file_contains "$COMMANDS_DIR/wrap.md" "~/.claude/commands/sweep.md" \
        "wrap.md must reference the deployed sweep.md path" || return 1
    assert_file_contains "$COMMANDS_DIR/wrap.md" "~/.claude/commands/summary.md" \
        "wrap.md must reference the deployed summary.md path" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" '`commands/sweep.md`' \
        "repo-relative paths are dead pointers at runtime" || return 1
}

test_wrap_does_not_duplicate_memory_bars() {
    assert_file_contains "$COMMANDS_DIR/sweep.md" "three months" \
        "sweep.md owns the three-bar discipline" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" "three months" \
        "wrap.md must reference the bars, not restate them" || return 1
}

test_wrap_does_not_duplicate_summary_skeleton() {
    assert_file_contains "$COMMANDS_DIR/summary.md" "# Session Summary:" \
        "summary.md owns the summary skeleton" || return 1
    assert_file_not_contains "$COMMANDS_DIR/wrap.md" "# Session Summary:" \
        "wrap.md must reference the skeleton, not embed a second copy" || return 1
}

test_scoring_threshold_owned_by_skill() {
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "35/50" \
        "the prose-hygiene skill owns the revise threshold" || return 1
    local hits
    hits=$(grep -l "35/50" "$COMMANDS_DIR"/*.md 2>/dev/null || true)
    assert_eq "" "$hits" \
        "no command may restate the skill's 35/50 threshold" || return 1
}

# ============================================================================
# Correctness strays
# ============================================================================

test_summary_reads_narrative() {
    assert_file_contains "$COMMANDS_DIR/summary.md" 'memory/narrative\.\*\.md' \
        "summary must read the per-actor session narratives" || return 1
}

test_prose_critic_pinned_and_contracted() {
    assert_file_contains "$COMMANDS_DIR/summary.md" "model: opus" \
        "the prose critic is a quality-judge task and must pin a capable tier" || return 1
    assert_file_contains "$COMMANDS_DIR/summary.md" "final message" \
        "the critic's deliverable must be demanded in its final message" || return 1
}

test_prose_hygiene_has_modes_and_technical_carveout() {
    # A cold Skill invocation must be able to tell drafting from reviewing, and the
    # absolutist rules must not flag correct technical sentences (summary.md applies EVERY rule).
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
    # /summary run standalone must not stall deciding whether to overwrite a
    # pre-existing summary; the replace rule lives in summary.md, not only wrap.md.
    assert_file_contains "$COMMANDS_DIR/summary.md" "already exists, replace it" \
        "summary.md step 3 must say to replace a pre-existing .cs/summary.md" || return 1
}

test_summary_bounds_git_log_to_session() {
    # 'derive from git history' is unbounded; the file list must be scoped to this
    # session via the timeline's earliest started timestamp, not the whole repo.
    assert_file_contains "$COMMANDS_DIR/summary.md" "git log --since" \
        "summary.md must bound the git log to the session, not the whole repo history" || return 1
}

test_summary_prose_loop_is_bounded() {
    # The apply/re-run critic loop must terminate: one re-run cap, stop regardless of
    # the second verdict — otherwise the model loops or stalls below threshold.
    assert_file_contains "$COMMANDS_DIR/summary.md" "stop regardless" \
        "summary.md must cap the critic loop so it terminates" || return 1
}

test_summary_relints_after_applying_rewrites() {
    # Rewrites applied after the lexical lint would otherwise land unlinted and trip
    # the prose-lint Stop hook at turn-end; the step must re-lint after applying.
    assert_file_contains "$COMMANDS_DIR/summary.md" "edits introduced before moving to step 6" \
        "summary.md must re-run cs -lint after applying the critic's rewrites" || return 1
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
    assert_file_contains "$COMMANDS_DIR/sweep.md" "contradicts or materially extends" \
        "sweep.md must give a supersede/update-in-place path, not only skip-or-duplicate" || return 1
}

test_sweep_states_filename_convention() {
    # The <bucket>_<short_slug>.md convention was only implied by the glob; a first
    # entry in an empty bucket needs it stated explicitly.
    assert_file_contains "$COMMANDS_DIR/sweep.md" "<bucket>_<short_slug>.md" \
        "sweep.md must state the memory-entry filename convention" || return 1
}

test_sweep_scopes_when_not_to_write() {
    # The exclusion section must be scoped to the strict buckets so it does not
    # suppress the looser-bar narrative appends step 4 invites.
    assert_file_contains "$COMMANDS_DIR/sweep.md" "strict-bucket entry" \
        "sweep.md 'When NOT to write' must scope to the strict buckets, not the narrative" || return 1
}

test_sweep_states_memory_pointer_format() {
    # 'Add a one-line pointer' with no format leaves the model to invent the MEMORY.md
    # line shape; it must match the existing [title](file.md) format.
    assert_file_contains "$COMMANDS_DIR/sweep.md" '\[title\](file.md)' \
        "sweep.md must state the MEMORY.md pointer format" || return 1
}

test_sweep_resolves_actor_before_narrative_append() {
    # cs -whoami resolution must be repeated at the narrative step, not left only in the
    # framing parenthetical, so a multi-actor session appends to the right file.
    local count
    count=$(grep -c "cs -whoami" "$COMMANDS_DIR/sweep.md" || true)
    if [ "$count" -lt 2 ]; then
        echo "  FAIL: sweep.md must repeat 'cs -whoami' in the narrative step (found $count)"
        return 1
    fi
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
    # unstated. The skill judges only (revising + the loop are the caller's, single-source
    # in summary.md); it must report the total whether or not it passes.
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
    # 'gh release create' returning is not the finish line; the signing/upload workflow can
    # still fail. The runbook must verify the workflow and the signed assets landed.
    assert_file_contains "$RELEASE_MD" "Verify the Release Workflow Succeeded" \
        "release.md must add a step to confirm the CI release workflow succeeded" || return 1
    assert_file_contains "$RELEASE_MD" "release is not done until" \
        "release.md must gate 'done' on the .minisig and install.sh assets appearing" || return 1
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_commands.sh"
echo ""
run_test test_checkpoint_allowed_tools_hyphenated
run_test test_store_secret_has_frontmatter
run_test test_store_secret_backend_neutral
run_test test_no_dangling_bucket_guidance_reference
run_test test_sweep_owns_bucket_routing_table
run_test test_sweep_routes_discovered_constraints
run_test test_sweep_updates_memory_index
run_test test_wrap_family_pinned_to_sonnet
run_test test_wrap_references_deployed_commands
run_test test_wrap_does_not_duplicate_memory_bars
run_test test_wrap_does_not_duplicate_summary_skeleton
run_test test_scoring_threshold_owned_by_skill
run_test test_summary_reads_narrative
run_test test_prose_critic_pinned_and_contracted
run_test test_prose_hygiene_has_modes_and_technical_carveout
run_test test_release_names_uninstall_source_not_bincs
run_test test_release_changelog_step_follows_approval
run_test test_prose_hygiene_records_upstream_sync
run_test test_summary_replaces_existing_file
run_test test_summary_bounds_git_log_to_session
run_test test_summary_prose_loop_is_bounded
run_test test_summary_relints_after_applying_rewrites
run_test test_wrap_report_is_not_two_line
run_test test_checkpoint_routes_reserved_subcommands
run_test test_checkpoint_quotes_label_and_stops_on_failure
run_test test_sweep_supersedes_stale_entries
run_test test_sweep_states_filename_convention
run_test test_sweep_scopes_when_not_to_write
run_test test_sweep_states_memory_pointer_format
run_test test_sweep_resolves_actor_before_narrative_append
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
run_test test_release_has_code_review_gate
report_results
