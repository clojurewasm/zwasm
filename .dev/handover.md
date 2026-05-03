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

- **Phase**: **Phase 7 IN-PROGRESS** (JIT v1 ARM64 baseline). 6
  closed per phase tracker; 6.2 + 6.3 deferred-in to §9.7 / 7.7
  + 7.8 per ADR-0010.
- **Last commit**: `a717ad3` — ADR-0010 deferral commit (§9.6 /
  6.2 + 6.3 → §9.7); 6.8 phase close lands in this iteration's
  ROADMAP-edit commit (SHA backfill + widget advance + §9.7
  task table opened with 11 rows).
- **Next task**: §9.7 / 7.0 — `src/jit/reg_class.zig` (define
  GPR / FPR / SIMD / inst_ptr_special / vm_ptr_special /
  simd_base_special classes per ROADMAP §4.2 W54-class day-1
  slot).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.7 / 7.0 (jit/reg_class.zig)

Per ROADMAP §4.2 the `RegClass` enum slot exists in `src/ir/zir.zig`
with day-1 reservation (W54-class lesson — naming the class set
upfront prevents the regalloc-stage IR shape from implicitly
encoding "what classes exist" via downstream switches).

Today: `pub const RegClass = enum(u8) { gpr, fpr, simd, _ };`
(non-exhaustive). Target shape per §9.7 / 7.0: add the three
*_special variants. The classes are NAME-only at this phase; the
matching machine-register tables are §9.7 / 7.2 (jit_arm64 ABI).

Plan:

1. Survey the W54 post-mortem references in
   `~/Documents/MyProducts/zwasm/.dev/archive/w54-redesign-postmortem.md`
   AND `~/zwasm/private/v2-investigation/notes/v1-audit.md`
   §"Implicit Contract Sprawl" — both are mandatory inputs for
   regalloc-touching work per `textbook_survey.md` Guard 4.
2. Create `src/jit/reg_class.zig` that owns the canonical
   `RegClass` enum + a "regclass info" table (sizeof / alignment
   / call-clobbered status — placeholder, real values land
   in 7.2's ABI work).
3. Promote the §4.2 `zir.RegClass` to a re-export from this new
   module so the slot identity is preserved (the old constraint:
   "renaming or removing the type would be a §4.2 deviation
   requiring an ADR" — re-exporting under the same name is fine).
4. Tests: each class enum-value round-trips via @intFromEnum;
   the regclass-info table covers every variant.
5. Three-host `zig build test-all`.

Carry-overs that consume regalloc work:
- §9.5 / 5.4 liveness control-flow + memory-op coverage —
  Phase-7 regalloc surfaces specific gaps; refine as needed.
- ADR-0010 deferred-in §9.7 / 7.7 + 7.8 (realworld stdout diff
  + ClojureWasm guest) — closeable once §9.7 / 7.6
  `interp == jit_arm64` gate proves operand-stack discipline.

Other carry-overs (still queued):
- §9.5: `no_hidden_allocations` zlinter re-evaluation
  (ADR-0009); per-feature handler split for validator.zig
  (with §9.1 / 1.7); const-prop per-block (Phase-15 hoisting);
  `src/frontend/sections.zig` (1073 lines) soft-cap split.
- §9.6: `br-table-fuzzbug` v1 multi-param `loop` block; 10
  realworld SKIP-VALIDATOR fixtures; 39 trap-mid-execution
  fixtures (debugged in §9.7 / 7.6's `interp == jit_arm64`
  differential gate).

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
