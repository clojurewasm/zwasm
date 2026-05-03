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
- **Last commit**: `c7fbe0d` — §9.5 / 5.1 land: `mvp.zig` split
  into mvp_int / mvp_float / mvp_conversions + residual shell;
  `mvp.zig` 1977→693 lines (out of soft-cap warn list).
- **Next task**: §9.5 / 5.2 — carve `validator.zig` (1426 lines)
  + `lowerer.zig` (1062 lines) toward §A2 soft cap (per phase-2
  audit follow-up).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.5 / 5.2 (carve frontend toward §A2 soft cap)

Two frontend monoliths still raise soft-cap warnings:

| File                          | Lines | Likely split axis                                                          |
|-------------------------------|-------|----------------------------------------------------------------------------|
| `src/frontend/validator.zig`  | 1426  | per-feature validators (mvp / sign-ext / sat-trunc / bulk-mem / ref-types / table-ops) keyed off the dispatch-table model |
| `src/frontend/lowerer.zig`    | 1062  | per-op lowerers; mirrors the interp `mvp_*` split where natural             |

Plan:

1. Read each file's structure; pick the split that follows the
   feature dispatch table (ROADMAP §A12 — same idiom as the
   `interp/mvp_*` split that just landed).
2. Land per-file (validator first, then lowerer) so each commit
   stays bounded; three-host `zig build test-all` after each.
3. Re-export shell stays at the original file path; behaviour
   identical (§14 forbids visible API drift mid-Phase).

Remaining §9.5 rows after 5.2: 5.3 `loop_info`, 5.4 `liveness`,
5.5 `verifier`, 5.6 `const_prop`, 5.7 phase-boundary audit,
5.8 phase tracker.

Queued for §9.5 / 5.7 (Phase-5 audit): re-evaluate
`no_hidden_allocations` zlinter rule for the now-split c_api +
mvp modules (deferred per ADR-0009 — all 13 monolith-era hits
were in `wasm_c_api.zig`; per-zone exclusion is clean post-split).

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
