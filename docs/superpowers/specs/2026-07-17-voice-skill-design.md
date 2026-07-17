# /voice skill — design

Date: 2026-07-17
Status: pending spec review
Decision trail: Alex, 2026-07-17 (queue task 1) — "We need a feature that
learns my voice and the way I talk so it can prepare messages and replies
in my own tone when needed." Use cases approved via AskUserQuestion: all
three — chat & email drafts, PR/issue/commit text, docs & posts written as
Alex. Learning source approved: TRANSCRIPTS ONLY (fully automatic, no
curated samples). Mid-discussion constraints: "no new command" and "i
rarely use cs -commands" — the feature must not ask the user to run any cs
verb, ever. Design approved (re-confirmed after an interrupt): skill-only
surface, bundled extraction script, two-layer profile.

## Context and goal

Everything Alex has ever typed to Claude lives in the session transcripts
under `~/.claude/projects/*/*.jsonl` — 78 project directories, 2.3 GB on
this machine. That corpus is the raw material of Alex's writing voice:
direct, terse, lowercase-leaning, concrete, with casual typos. The goal:
a `/voice` skill, shipped by cs like merge/rotate/prose-hygiene, that
distills this corpus into a readable style profile and drafts messages,
replies, PR text, and longer prose that sound like Alex wrote them.

The register problem is the heart of the design. The corpus is
Alex-directing-an-AI (imperative, no pleasantries, many one-word acks); an
email to a colleague is a different register. The profile therefore
separates PORTABLE traits (directness, rhythm, vocabulary, how Alex
disagrees, real phrases) from CONTEXT-BOUND habits (terse acks,
lowercase-everything), and drafting applies the right layer per target.
A naive "imitate this corpus" would produce emails that read like
commands to a bot.

## Decisions

1. **Single surface: the `/voice` skill.** No user-facing cs verb, no
   hook, nothing to run before first use. The skill builds what it needs
   on first invocation and refreshes on demand. Rejected: `cs -voice
   build` extractor verb (contradicts the no-new-command constraint);
   SessionEnd hook for continuous learning (standing per-conversation
   tax; this project removed two indexer hooks for exactly that cost —
   rebuild-on-demand achieves the same result with zero standing cost).

2. **Extraction is a bash script bundled inside the skill:**
   `skills/voice/scripts/build-corpus.sh`. Deterministic, testable in the
   repo's bash suite, invisible to the user (the skill runs it). Rejected:
   inline extraction logic in SKILL.md (untestable, undeployable as
   code); an internal hidden cs subcommand (still a new cs command in
   spirit, and it buries skill implementation detail in bin/cs dispatch).

3. **The installer grows generic skill support-file deployment.** Today
   install.sh copies only `SKILL.md` per skill (both local `cp` and
   remote `curl`/`wget` modes), so a bundled script would silently not
   ship. A new `CS_SKILL_FILES` manifest lists per-skill support files as
   `<skill>/<relative-path>` entries (first entry:
   `voice/scripts/build-corpus.sh`); both deploy modes iterate it, and it
   is duplicated in bin/cs (lib/00-header.sh) and install.sh with the
   same KEEP-IN-SYNC comment and sync test that already guard
   `CS_SKILLS`. Deployed support scripts keep the executable bit (remote
   mode `chmod +x` after download). Uninstall already removes whole skill
   directories, which covers support files.

4. **Corpus and profile live at `$SESSIONS_ROOT/.voice/`**
   (`$HOME/.claude-sessions/.voice/` by default): `corpus.md`,
   `profile.md`. Machine-local by nature (transcripts are machine-local),
   user-global (voice is a property of the user, not of any session),
   outside every git repository, dot-prefixed so session listing globs
   never see it. The directory is created `chmod 700`: the corpus
   concentrates everything the user ever typed into one file and deserves
   the same posture as a credentials store.

5. **Two-layer profile.** `profile.md` is a readable style guide the user
   can open and correct by hand — that is the feedback loop, and why a
   document beats anything opaque. Layer one: the portable fingerprint
   (directness, sentence rhythm, vocabulary, how disagreement is voiced,
   verbatim phrase bank, languages used). Layer two: per-register dials
   for the three approved registers — chat/comms, dev artifacts
   (PR/issue/commit), long-form docs — each with an explicit casualness
   dial (lowercase starts, light punctuation) so chat drafts keep the
   habit and docs drafts drop it. Typos are normalized, never learned:
   the profile may note "types fast, casual misspellings" as a trait but
   drafts are spelled correctly. The profile ends with a provenance stamp:
   build date, message count, transcript-file count.

6. **Staleness never blocks a draft.** If `profile.md` is older than 30
   days, the skill offers a rebuild after delivering the requested draft
   with the existing profile. Missing profile: the skill builds corpus,
   distills, then drafts — one invocation, no pre-steps for the user.

7. **Secret redaction in the extractor.** The corpus must not become a
   plaintext concentration of accidentally pasted credentials. The
   extractor drops any message line matching obvious credential shapes
   (case-insensitive `api[_-]?key|token|secret|password|bearer` adjacent
   to a value, `sk-[A-Za-z0-9]{16,}`, unbroken base64/hex runs of 40+
   chars): the matching LINE is replaced with `[redacted line]` so the
   surrounding prose still contributes voice. Over-redaction is
   acceptable; leakage is not.

## Corpus extraction (concrete)

Inputs: every `*.jsonl` directly under `~/.claude/projects/*/`. The
script is standalone (it does not source bin/cs), so it derives its paths
itself: transcripts root `${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}`,
output root `${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}/.voice` — both
env-overridable, which is also how tests isolate it. Skipped entirely: any
path containing `/subagents/` and any file named `agent-*.jsonl` — their
"user" messages are dispatch prompts written by Claude, not the user.

Per entry, keep only records where ALL hold:
- `.type == "user"`
- `.isMeta` is not `true`
- `.isSidechain` is not `true`
- content is a string, or an array whose `type=="text"` items are joined
  with a space (tool_result items drop out naturally)

Then drop any message that matches a non-human sentinel: starts with
`Caveat:`, contains `<command-name>`, `<local-command-stdout>`,
`<system-reminder>`, `Stop hook feedback:`, `[Request interrupted`,
`TASKMASTER`, or starts with `This session is being continued` (compaction
summaries). These are harness-injected "user" messages, not typing.

Then:
- **Short-ack appendix, not corpus:** messages under 20 characters (after
  trimming) go to a frequency appendix (`sort | uniq -c | sort -rn`, top
  50) — "continue", "approved", "all good" carry voice as a phrase bank
  but 400 repetitions would drown the corpus.
- **Paste guard:** messages over 2000 characters are dropped; at that
  size they are almost always pasted logs, code, or documents, not typed
  prose.
- **Redaction pass** per Decision 7.
- **Dedup:** byte-identical messages collapse to one occurrence.
- **Ordering and cap:** newest first (voice drifts; recent wins), capped
  at 4000 messages. The cap is reported in the stats header when hit.

Output `corpus.md`: a stats header (built date, files scanned, messages
kept/dropped by reason, cap note), then messages as blocks separated by
`---` lines each prefixed with a `[project-dir-basename, YYYY-MM-DD]`
attribution line, then the short-ack appendix.

Implementation constraints (project law): bash 3.2 + BSD userland; jq
required (already a cs-statusline dependency) with a clear error naming
it when absent; standalone under `set -euo pipefail`; no early-exiting
consumer downstream of a producing pipe — per-file jq output is written
to a temp file and post-processed with awk reading files directly (the
SIGPIPE-under-pipefail law; transcripts routinely exceed 64 KB).

## Skill flow

`/voice <request>` where the request names or pastes the thing to write
("reply to this Slack message from Dan: …", "PR description for this
branch", "short post announcing X").

1. Read `$SESSIONS_ROOT/.voice/profile.md`. Present and fresh → step 4.
2. Missing → run `~/.claude/skills/voice/scripts/build-corpus.sh`, then
   distill: read `corpus.md` and write `profile.md` per Decision 5. The
   4000-message cap bounds messages, not bytes — a corpus can reach
   megabytes — so the skill reads it with offset/limit in sequential
   chunks whenever it exceeds ~200 KB, accumulating observations before
   writing the profile.
3. Corpus empty or no transcripts found → report exactly that and stop;
   nothing to learn from is a user-visible condition, not a silent pass.
4. Infer the register from the request (chat/comms, dev artifact,
   long-form); if genuinely ambiguous, ask one question. Load the
   profile, draft, deliver. Iterate on feedback in conversation.
5. Profile older than 30 days → after delivering, offer a rebuild
   (re-run script + re-distill) — never before the draft.

The SKILL.md carries the load-bearing prompt rules: never fabricate
quotes or commitments on the user's behalf; never reproduce redacted or
credential-shaped content; typos are a described trait, not an output
feature; the draft is presented for editing, not sent anywhere by the
skill; the profile document is the single source of style truth (no
improvising traits the profile does not record).

## Error handling

- No `~/.claude/projects` directory, no jsonl files, or zero kept
  messages → named, actionable message; skill stops.
- `jq` missing → error names the dependency and how to get it.
- Unreadable/corrupt jsonl lines → skipped silently by jq (`-r` with
  error suppression per file); a file that fails wholesale is counted in
  the stats header as skipped.
- Interrupted build → the script writes to temp files and moves into
  place at the end, so a partial run never leaves a truncated
  corpus/profile pair.

## Testing

`tests/test_voice_corpus.sh` (new suite, run_all glob picks it up),
fixtures under an isolated fake `$CLAUDE_PROJECTS_DIR`:
- typed string message kept; array text-parts joined; tool_result-only
  entries dropped
- `isMeta: true` dropped; `isSidechain: true` dropped
- files under `subagents/` skipped; `agent-*.jsonl` skipped
- each sentinel class dropped (one fixture per marker)
- short ack lands in appendix with count, not in corpus body
- >2000-char paste dropped and counted in stats
- credential-shaped line redacted, surrounding message survives
- byte-identical duplicates collapse
- newest-first ordering; 4000-message cap enforced and reported
- stats header numbers match fixture arithmetic (independent literals)
- empty projects dir → error path, non-zero exit, named message
- SIGPIPE probe: a fixture transcript over 64 KB total builds cleanly
  (exit 0, corpus intact)
- suite obeys harness law: every assert `|| return 1`, `report_results`
  last, runs under stock `/bin/bash` 3.2 with BSD userland

Manifest sync: `test_lib.sh` (or the existing skills sync test) extends to
assert `CS_SKILL_FILES` is identical in bin/cs and install.sh, and that
`voice` appears in `CS_SKILLS` in both.

Skill text: `tests/test_voice_skill.sh` pins load-bearing SKILL.md
phrases (the never-fabricate rule, the normalize-typos rule, the
profile-is-source-of-truth rule, the script path it invokes), same
pattern as `test_merge_skill.sh`.

Empirical final review: build the real corpus on this machine, read the
generated profile for register separation and redaction, and produce one
real draft per register, judged against the profile.

## Out of scope (YAGNI)

- No hooks, no continuous/background learning, no auto-rebuild.
- No per-recipient or per-channel profiles.
- No curated-samples folder (Alex chose transcripts-only; the profile
  document itself is hand-correctable, which covers the gap).
- No cs verb, no TUI surface, no doctor check beyond the existing skills
  deploy-drift machinery picking up the new files.
- No cross-machine sync of corpus/profile.
- No sending of drafts anywhere; the skill writes text, the user ships it.
