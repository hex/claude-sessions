# cs-secrets concurrency — follow-up briefs

Deferred from the 2026-07-21 D1-D3 concurrency/durability work (branch
`windows-secrets-concurrency`). D1-D3 plus the lock-correctness fixes codex
surfaced in rounds 1-3 (reap TOCTOU, signal-terminate, trap-ordering, purge
coverage) are DONE and committed. The per-session mutex now serializes all three
live-store mutations: `encrypted_store`, `encrypted_delete`, `encrypted_purge`.

The items below are PRE-EXISTING concurrency gaps in adjacent code paths, not
regressions from that work. Alex chose to stop and log them rather than expand
scope (matches the "bound the codex rounds on pre-existing bugs" preference).

## F1 [high] — Concurrent export can publish a stale snapshot over a newer sync file

**Where:** `export_to_sync_file` (bin/cs-secrets) — openssl path ~:1732, age path ~:1683.

**Race:** export reads the encrypted store WITHOUT the session mutex, then later
renames its snapshot over the per-machine sync file. Export A reads `{A}` and
pauses during encryption; a store adds `B`; export B reads `{A,B}` and commits;
A resumes and renames `{A}` over B's newer backup. The **live store stays
correct** — only the sync BACKUP silently loses `B`, and a later import can
resurrect the stale state. The atomic temp+rename (D2) prevents partial/torn
files, not a stale-writer overwrite.

**Fix options (a design choice — discuss before implementing):**
1. Hold the same per-session mutex across collect → unchanged-compare → encrypt →
   rename/removal. Simplest and consistent, but holds the mutex across a
   potentially-slow export (age encryption / recipient I/O), briefly blocking
   store/delete/purge.
2. A separate per-session EXPORT lock (so export never blocks the live-store
   mutations) plus a snapshot/version guard so a stale writer is refused at
   commit. Cleaner separation, more design + code, new primitive.

**Test:** deterministic delayed-export test (slow-encrypt shim on export A) proving
an older export cannot overwrite a newer snapshot — mirror the D2 injection style.

## F2 — Concurrency audit of the remaining backend read-modify-write paths

The mutex was added to the three live-store mutations only. Before calling the
encrypted backend fully concurrency-safe, audit the other read-then-write paths
for the same stale-writer / lost-update class and decide which need the mutex:

- `import_from_sync_file` (merge mode) — reads the store, merges, writes back.
- `migrate-backend` — reads source backend, writes destination.
- `encrypted_export` (env-var export) — read-only, likely fine; confirm.

Keep the scope bounded: only serialize a path if a concrete lost-update/stale
scenario exists, and prefer the same lock primitive already in place. codex
confirmed the D3 salt hard-link publish and the D2 sync temp+rename are sound, so
those are out of scope here.

## Notes

- Lock primitive in place: `encrypted_lock_acquire`/`encrypted_lock_release`
  (atomic O_EXCL via `set -o noclobber`, PID-carrying, DELIBERATELY not
  auto-reaped — a leaked lock fails loud naming the file to remove). Any new
  serialized path MUST install `trap ... EXIT` + `trap 'exit N' INT/TERM/HUP`
  BEFORE calling acquire (see `encrypted_store`).
- Whatever gets serialized, add a deterministic failure/timing-injection test —
  the raw races do not reproduce without widening their window (slow-tool shim).
