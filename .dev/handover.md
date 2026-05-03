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

- **Phase**: **Phase 6 IN-PROGRESS** (v1 conformance baseline per
  ADR-0008 🔒). 6.2 + 6.3 just deferred to Phase 7 per ADR-0010
  (root-cause investigation showed behaviour bugs, not missing
  ops; deferral preserves the 30+ match threshold for honest
  Phase-7 closure rather than lowering it).
- **Last commit**: `ae1a8a3` — §9.6 / 6.4 [x] + handover retarget
  at 6.2 root-cause. Investigation landed in this iteration:
  `[dispatch] unbound slot` instrumentation across 6 sampled
  fixtures (c_integer_overflow, c_many_functions, c_control_flow,
  rust_compression, rust_enum_match, c_btree, c_sha256_hash)
  produced **zero** unbound-slot prints. Behavior bug, not
  missing op. ADR-0010 filed; §9.6 / 6.2 + 6.3 annotated as
  DEFERRED.
- **Next task**: §9.6 / 6.8 — Phase-6 close (open §9.7 inline +
  flip phase tracker + backfill §9.6 SHAs). All non-deferred
  rows are now `[x]`.
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.6 / 6.8 (close Phase 6, open §9.7)

Phase-6 closing protocol per `continue` skill:

1. Backfill SHA pointers for §9.6 rows 6.0, 6.1, 6.4, 6.5, 6.6,
   6.7 (the closed rows). 6.2 + 6.3 retain their DEFERRED
   annotation; they get fresh SHA columns when they land in
   §9.7 per ADR-0010.
2. Update Phase Status widget: §6 → DONE, §7 → IN-PROGRESS.
3. Expand §9.7 task table inline. ROADMAP §9 / Phase 7 already
   has Goal + Exit criterion bullets; expand into a numbered
   `[ ]` table mirroring §9.5 / §9.6 structure. Add the two
   ADR-0010 carry-over rows (realworld stdout diff +
   ClojureWasm guest end-to-end) at the end of the table.
4. Replace handover with §9.7's first open task (likely
   `src/jit/regalloc.zig` greedy-local allocator).
5. Three-host `zig build test-all`.

Carry-overs from §9.5 (still queued):
- `no_hidden_allocations` zlinter re-evaluation (ADR-0009).
- Per-feature handler split for validator.zig (with §9.1 / 1.7).
- Liveness control-flow + memory-op coverage (Phase-7 regalloc
  drives this directly).
- Const-prop per-block analysis (Phase-15 hoisting).
- `src/frontend/sections.zig` (1073 lines) soft-cap split.

Carry-overs from Phase 6:
- `br-table-fuzzbug` v1 regression — multi-param `loop` block
  validator gap (re-add to NAMES when gap closes; see §9.7
  validator follow-up).
- 10 realworld SKIP-VALIDATOR fixtures (Go + cpp_unique_ptr).
- 39 realworld trap-mid-execution fixtures (root cause = behavior
  bug per ADR-0010; investigation tooling lands with §9.7
  `interp == jit_arm64` differential gate).

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
