# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` — read the **Phase Status** widget at the top
   of §9 to find the IN-PROGRESS phase, then its expanded `§9.<N>`
   task list; pick up the first `[ ]` task.
3. The most recent `.dev/decisions/NNNN_*.md` ADR (if any) — to
   recover load-bearing deviations in flight.

## Current state

- **Phase**: **Phase 5 IN-PROGRESS.** Phases 0–4 are `DONE` (all
  SHAs backfilled in §9.<N> task tables; `git log --grep="§9.<N>
  / N.M"` is the canonical lookup).
- **Last commit**: `2b26a07` — §9.5 / 5.0 chunk d land: Engine /
  Store / Module / Instance / Func / Extern carved to
  `src/c_api/instance.zig`; `wasm_c_api.zig` 1559→159 (pure
  re-export hub). Chunk e is naturally absorbed.
- **Next task**: §9.5 / 5.1 — split `src/interp/mvp.zig` into
  int_ops / float_ops / conversions modules (see Active task).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.5 / 5.1 (split src/interp/mvp.zig)

`src/interp/mvp.zig` is at **1977 lines** (against §A2's 2000-line
hard cap — closest single file to the cap; soft-cap warning
already raised by `file_size_check.sh`). Per ROADMAP §9.5 the
target split is three sibling modules:

| File                              | Scope                                                       |
|-----------------------------------|-------------------------------------------------------------|
| `src/interp/mvp_int.zig`          | i32 / i64 ALU + bit ops + integer compare                   |
| `src/interp/mvp_float.zig`        | f32 / f64 arithmetic + compare + min/max + neg/abs/copysign |
| `src/interp/mvp_conversions.zig`  | trunc / convert / promote / demote / reinterpret            |
| `src/interp/mvp.zig` (residual)   | nop / unreachable / drop / select / control + `register()` shell that calls into each split module's own `register()` |

Plan:

1. Read `src/interp/mvp.zig` to map handlers to the three target
   buckets (most are pure data).
2. Move handlers + their tests out; each split module owns its
   own `pub fn register(table: *DispatchTable) void` that the
   shell `mvp.register` calls in sequence.
3. Three-host `test-all` after the split lands; the dispatch
   table-driven design (ROADMAP §A12) makes this verifiable
   purely via the existing spec corpus.

After 5.1 lands: §9.5 / 5.2 — `validator.zig` + `lowerer.zig`
carve toward §A2 soft cap (per phase-2 audit follow-up).
Other §9.5 rows: 5.3 `loop_info`, 5.4 `liveness`, 5.5 `verifier`,
5.6 `const_prop`, 5.7 phase-boundary audit, 5.8 phase tracker.

Re-evaluate `no_hidden_allocations` zlinter rule for the now-split
c_api modules (deferred per ADR-0009 — all 13 hits were in the
monolithic `wasm_c_api.zig`; per-zone exclusion becomes clean now
that it's split). Queue alongside §9.5 / 5.7 (Phase-5 audit).

## Outstanding spec gaps (queued for Phase 6 — v1 conformance)

These were surfaced during Phases 2–4 and deferred from their own
phase. Phase 6 (ADR-0008) absorbs them as part of the v1
conformance baseline; do NOT re-pick during Phase 5.

- **multivalue blocks (multi-param)**: `BlockType` needs to carry
  both params + results; `pushFrame` must consume params (Phase 2
  chunk 3b carry-over).
- **element-section forms 2 / 4-7**: explicit-tableidx and
  expression-list variants (Phase 2 chunk 5d-3).
- **ref.func declaration-scope**: §5.4.1.4 strict declaration-
  scope check (Phase 2 chunk 5e).
- **Wasm-2.0 corpus expansion**: 47 of 97 upstream `.wast` files
  deferred (block / loop / if 1-5, global 24, data 20, ref_*,
  return_call*) — each surfaces a specific validator gap.

## Open questions / blockers

(none — push to `origin/zwasm-from-scratch` is autonomous inside
the `/continue` loop per the skill's "Push policy"; no user
approval required.)
