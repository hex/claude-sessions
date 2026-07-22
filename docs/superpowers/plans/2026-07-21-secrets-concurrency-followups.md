# cs-secrets concurrency — follow-up briefs

Deferred from the 2026-07-21 D1-D3 concurrency/durability work (branch
`windows-secrets-concurrency`). D1-D3 plus the lock-correctness fixes codex
surfaced in rounds 1-3 (reap TOCTOU, signal-terminate, trap-ordering, purge
coverage) are DONE and committed. The per-session mutex now serializes all three
live-store mutations: `encrypted_store`, `encrypted_delete`, `encrypted_purge`.

The items below are PRE-EXISTING concurrency gaps in adjacent code paths, not
regressions from that work. Alex chose to stop and log them rather than expand
scope (matches the "bound the codex rounds on pre-existing bugs" preference).

## F1 [high] — Concurrent export can publish a stale snapshot over a newer sync file — DONE (2026-07-22)

**FIXED:** `export_to_sync_file` now holds the same per-session mutex across the
whole collect → compare → encrypt → rename transaction (Alex chose the shared-
mutex option over a separate export lock). Traps installed before acquire;
because export has several early returns, the EXIT-trap release references a
GLOBAL (`_CS_EXPORT_LOCK_SESSION`) so it survives to process exit under set -u.
Deterministic test `test_export_serialized_against_concurrent_store_no_stale_overwrite`
(slow-encrypt shim on export A + a concurrent store + re-export) — RED lost the
secret, GREEN keeps it. Original race, for the record:

> export reads the store WITHOUT the mutex, then renames its snapshot over the
> per-machine sync file. Export A reads `{A}`, pauses during encryption; a store
> adds `B`; export B reads `{A,B}` and commits; A resumes and renames `{A}` over
> B's newer backup — the live store stays correct, only the sync BACKUP loses
> `B`. Atomic temp+rename (D2) prevents torn files, not a stale-writer overwrite.

Test-harness note: the slow-encrypt shim must call `sleep`/`openssl` by ABSOLUTE
path, and `_ageless_path` now includes `sleep` — the lock's contention-wait needs
it, and the minimal sandbox omitting it silently no-op'd the injection at first.

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
