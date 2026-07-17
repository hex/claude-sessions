---
name: voice
description: Draft messages, replies, PR/issue/commit text, or longer prose in the user's own writing voice, learned from their Claude Code transcripts. Invoke when the user asks for a draft "in my voice", "as me", or asks for a message or reply they will send under their own name.
---

Write AS the user, not as an assistant writing about them. The voice comes
from a distilled profile document, never from improvisation.

## Files

- Profile: `${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}/.voice/profile.md`
- Corpus: `${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}/.voice/corpus.md`
- Builder: `~/.claude/skills/voice/scripts/build-corpus.sh`

## Flow

1. Read the profile. If it exists, go to step 4.
2. No profile: run the builder script, then distill the corpus into a
   profile (next section), then continue.
3. If the builder exits with "nothing to learn from", tell the user exactly
   that — there are no transcripts to distill on this machine — and stop.
4. Infer the register from the request: Chat & comms (Slack, email, DM),
   Dev artifacts (PR description, review comment, issue reply, commit
   message), or Long-form (README, announcement, post). If genuinely
   ambiguous, ask one question.
5. Load the profile, draft in the user's voice, deliver the draft for the
   user to edit and ship. Iterate on feedback. You never send anything —
   no Slack, no email, no gh commands; the draft is text in the
   conversation.
6. If the profile's Provenance date is older than 30 days, offer a rebuild
   (re-run the builder, re-distill) AFTER delivering the draft — staleness
   never blocks a draft.

## Distilling the profile

Read the corpus (with offset/limit chunks when it exceeds ~200 KB) and
write the profile with exactly these sections:

- `# Voice profile`
- `## Fingerprint` — portable traits that survive any register: directness,
  sentence rhythm and length, vocabulary, how disagreement is voiced, how
  questions are asked, greeting/sign-off habits (or their absence).
- `## Registers` — three subsections: `### Chat & comms`, `### Dev
  artifacts`, `### Long-form`. Each records a casualness dial (lowercase
  starts, punctuation weight, contraction use) and typical length. The
  corpus is coding-chat; extrapolate registers from the fingerprint plus
  the corpus evidence, and say in the profile which registers are
  corpus-backed and which are extrapolated.
- `## Phrase bank` — verbatim phrases the user actually types (draw from
  the corpus body and the short-ack frequency appendix).
- `## Languages` — languages observed and where they are used.
- `## Anti-patterns` — what the user never writes (e.g. corporate
  pleasantries, exclamation-heavy enthusiasm) — derived from the corpus,
  not invented.
- `## Provenance` — Built date, messages used, files scanned (copy from
  the corpus stats header).

The profile is a document the user can open and correct by hand; their
edits are authoritative on the next draft.

## Rules

- The profile is the single source of style truth. Do not apply traits the
  profile does not record.
- Never fabricate quotes, facts, decisions, or commitments on the user's
  behalf. A draft may carry placeholders like [date] for facts you lack.
- Typos in the corpus are a described trait; drafts are spelled correctly.
- Never reproduce `[redacted line]` markers or anything credential-shaped
  from the corpus into a draft.
- Deliver drafts for the user to edit and send; never send or post
  anything yourself.
