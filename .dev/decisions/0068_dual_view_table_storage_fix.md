# 0068 — Synchronise dual-view table storage via op-time mirror writes

- **Status**: Accepted (2026-05-18 user-approved with audit-prep amendments — see "Audit-prep configurations" § below)
- **Date**: 2026-05-18
- **Author**: zwasm v2 maintainer (Phase 9 §9.9-III Cat III work — D-126 discharge)
- **Tags**: phase-9, cat-iii, jit, abi, table, call-indirect, cross-module, dispatch, 9.12-audit-prep

## Context

D-126 (filed 2026-05-16, evidence absorbed from D-143 on
2026-05-18 — see commit `c75343dc`) documents a load-bearing
storage inconsistency in `JitRuntime`'s table representation
for the spec-assertion runner:

- **`funcptr_base`** (= `scratch_funcptrs.ptr`, populated by
  `runner_mod.applyTableInit` from elem segments at
  `on_module_loaded` time) is read by **`call_indirect t0`**
  per `op_call.zig::emitCallIndirect` table-0 fast path
  (X26-cached load from prologue, established
  §9.9-l-1b-d093).
- **`tables_ptr[0].refs`** (= `scratch_table_refs[0]`, a
  separate buffer populated by
  `setupMultiTableScratch::populateTableRefs` with
  FuncEntity-pointer encoding) is read/written by
  **`table.get`** / **`table.set`** / **`table.copy`** /
  **`table.init`** / **`table.grow`** per
  `op_table.zig::emitTable*`.

These are TWO independent backing buffers indexed by the
same `table[i]` slot. The op handlers only mutate one
buffer; `call_indirect` reads from the other. Result:
after any of the 5 mutating ops, `call_indirect` sees the
PRE-mutation state.

Pre-γ-4 this bug was masked because most fixtures
exercising it (`table_copy`, `table_init`, `ref_func`,
`imports` families) skipped via `hasUnbindableImports`
(they import registered func aliases). The γ-4 probe
(2026-05-18) exposed 113 functional FAILs across these 4
families on Mac aarch64 / 112 on ubuntunote. Verified
minimal repro: `wasm-2.0-assert/table_copy/table_copy.2
.wasm` does `table.copy 0 0 [13,2,3]`; pre-test t0[13]=5,
spec expects post-test t0[13]=3, observed `check_t0(13)→5`
(= the pre-mutation funcptr from `scratch_funcptrs` that
`call_indirect` reads).

The dual-view layout has historical justification:

- **funcptr_base** (= raw 8-byte func body entry address):
  `call_indirect` does `BLR X17` after `LDR X17, [X26,
  X17, LSL #3]` — one load + one branch. Fast path.
- **tables_ptr[k].refs** (= FuncEntity pointers per the
  reftype encoding settled by lesson
  `2026-05-04-beta-funcref-encoding-rejected.md` /
  ADR-implied Alpha shape): `table.get` returns a funcref
  value (= `Value.fromFuncRef(&FuncEntity)`), which
  downstream consumers (`ref.is_null`, `ref.func`,
  cross-instance round-trips) consume as a 64-bit opaque
  pointer to a `FuncEntity`. The reftype-shape is
  load-bearing for Wasm spec §3.4.4 funcref semantics.

The two views encode **the same logical table entry** in
two different shapes. Mutating one without the other
breaks the invariant that `call_indirect i` and
`table.get i` see the same slot.

Phase 9 §9.9-III absorbs Wasm 1.0 cross-module work per
ADR-0065. D-126 + the γ-4-exposed expansion lives in Cat
III sub-chunk scope. This decision unblocks γ-4 permanent
landing + (c)-2.4 distiller's cross-module fixture
families.

## Decision

Adopt **Option B — sync at op time**: extend each of the 5
table-mutating JIT op handlers (`emitTableSet`,
`emitTableCopy`, `emitTableInit`, `emitTableGrow`, and
`emitTableFill`) on both arm64 and x86_64 to mirror their
existing `tables_ptr[k].refs` writes into a parallel
funcptr-view buffer.

Concrete plumbing:

- **Extend `TableSlice` extern struct** from 16 → 24 bytes:
  add `funcptrs: [*]u64` (and `typeidxs: [*]u32` for
  `call_indirect` sig check parity) alongside the existing
  `refs: [*]u64` / `len: u32` / `max: u32` fields. New
  stride for `tables_ptr` indexing is 24 (with padding to
  8-byte alignment).
- **`makeJitRuntime` initialisation**: bind
  `scratch_tables_descriptor[k].funcptrs` to the
  pre-existing `scratch_funcptrs` (for k=0) /
  `scratch_extra_funcptrs[k-1]` (for k>0), and
  `.typeidxs` to the analogous `scratch_typeidxs` arrays.
  No new allocation — just additional pointers into
  buffers that the runner already maintains.
- **Op-handler change** for the 5 mutating ops: where the
  current emit does `LDR X15, [X12, X16, LSL #3]; STR
  X15, [X11, X17, LSL #3]` (refs copy), add a paired
  `LDR Xfp, [X12_fp, X16, LSL #3]; STR Xfp, [X11_fp, X17,
  LSL #3]` (funcptr mirror) AND `LDR Wti, [X12_ti, X16,
  LSL #2]; STR Wti, [X11_ti, X17, LSL #2]` (typeidx
  mirror). Pre-load the funcptr/typeidx pointer slices
  alongside the refs slice at op entry; reuse spill-stage
  scratch regs (X10/X11/X12/X13 family per the existing
  `op_table.zig` register conventions).
- **`call_indirect` t0 fast path** stays unchanged
  (`funcptr_base` / `typeidx_base` still scalar fields in
  `JitRuntime`, bound to the same backing arrays). The
  fast path doesn't pay any extra cost; the mirror logic
  lives only in mutating ops.
- **`emitTableSet` derives funcptr from funcref input**:
  the funcref value being stored is a `*FuncEntity`. To
  populate the funcptr-view, `emitTableSet` adds a
  `LDR Xfp, [Xref, #FuncEntity.funcptr_offset]` (assuming
  `FuncEntity` carries a `funcptr: usize` field; if not,
  a 2-LDR walk through `FuncEntity.runtime.func_offsets`).
  This is one extra LDR per `table.set`, paid only on the
  reftype-write path.

The `funcptr` field on `FuncEntity` may already exist; if
not, add it as a precondition sub-chunk (small, isolated
runtime change with a single populator at
`Runtime.bindFuncEntities` or equivalent).

## Alternatives considered

### Alternative A — Unified storage (single buffer per table slot)

- **Sketch**: drop the `scratch_table_refs` arrays
  entirely; have `tables_ptr[k].refs` and `funcptr_base`
  both point at the SAME `scratch_funcptrs` buffer. Slot
  i holds a single `u64` shared by both reftype and
  funcptr views.
- **Why rejected**: the reftype encoding for funcref must
  remain a `*FuncEntity` (per lesson
  `2026-05-04-beta-funcref-encoding-rejected.md` —
  "beauty-driven design loses to 10 years of production
  experience" → Alpha = zombie-keep-alive
  `*FuncEntity`). Storing raw funcptrs in the slot would
  break `ref.func` / cross-instance round-trips via
  globals. Migrating the reftype shape to "raw funcptr"
  is too invasive — touches `Runtime`, c_api, Value
  encoding, interp/JIT alignment. Out of D-126's blast
  radius.

### Alternative C — Route call_indirect through tables_ptr

- **Sketch**: emit `call_indirect t0` as `LDR X16,
  [X19, #tables_ptr_off]; LDR X16, [X16, #refs_off]; LDR
  X17, [X16, X17, LSL #3]; BLR X17` instead of the
  X26-cached fast path. One source of truth — the refs
  buffer (containing FuncEntity ptrs); call_indirect
  dereferences `FuncEntity.funcptr` per call.
- **Why rejected**: adds two extra LDRs per
  `call_indirect` on the hot path (table-deref + FuncEntity-
  deref instead of single-array index). The
  §9.9-l-1b-d093 X26 fast path was specifically
  optimised; removing it regresses bench-relevant
  workloads. Also: drops the funcptr cache that
  `applyTableInit` precomputes for imports (which would
  re-introduce per-call work for cross-module dispatch).
  Acceptable cost reduction strategy only if Phase 15
  optimisations later remove it as part of a broader IR
  refactor — not a Phase 9 §9.9-III scope-fit change.

### Alternative D — Defer the fix until Phase 15

- **Sketch**: leave D-126 as `now` debt; γ-4 stays
  reverted; the dual-view bug remains latent until Phase
  15 optimisation work touches table representation.
- **Why rejected**: γ-4 is on the close-plan §6 (c) path
  to Phase 9 §9.9 close. (c)-2.4 distiller would want to
  extend cross-module fixtures, but those would re-trip
  D-126. Phase 9 close cannot proceed without addressing
  D-126.

## Consequences

- **Positive**:
  - Unblocks γ-4 permanent landing (re-relax
    `hasUnbindableImports`) and any subsequent cross-module
    chunks in (c)-2.4.
  - The dual-view consistency invariant becomes
    op-handler-local: each mutating op preserves both
    views; no global runtime-level sync logic.
  - Existing `call_indirect t0` fast path stays unchanged;
    no perf regression on the hot path.
  - The TableSlice extension is one-time; all future
    table-mutating ops follow the same triple-write pattern
    by default.

- **Negative**:
  - Each of the 5 mutating ops grows by ~6-10 instructions
    (paired refs/funcptr/typeidx LDR-STR per loop iter for
    table.copy/init; single triple-write for table.set).
    For table.copy of `n` slots, the per-iter cost goes
    from 2 inst (LDR+STR) to 6 inst (3× LDR+STR). 3× the
    in-loop work.
  - `TableSlice` stride change (16→24 bytes) is a
    load-bearing ABI change for JIT-emit code that
    hard-codes the stride. All `op_call.zig::emitCallIndirect`
    multi-table indexing arithmetic + `op_table.zig`
    tbl_off computations need to be re-derived. Must
    grep the codebase for `* 16` / `<< 4` references to
    `TableSlice` and update.
  - `emitTableSet` needs `FuncEntity.funcptr` (or a
    derivation path). Adding it to `FuncEntity` is a
    Runtime-side ABI change — affects interp + c_api.
  - The mirror discipline must be maintained for any
    future table op (e.g. `table.fill`, future Wasm 3.0
    reftype ops). Reviewer checklist + an
    `audit_scaffolding` §G probe should verify all
    table-write op handlers do the triple-write.

- **Neutral / follow-ups**:
  - **`FuncEntity` funcptr field audit**: confirm whether
    `Runtime.FuncEntity` already carries `funcptr: usize`.
    If not, add it as a sub-chunk before the JIT changes
    so `emitTableSet` can rely on it.
  - **TableSlice stride sweep**: grep `scripts/zone_check.sh`-
    style: every `* 16` / `<<4` operating on a
    `tables_ptr` index in `engine/codegen/` needs
    re-derivation. Likely 4-6 sites per arch.
  - **Reviewer-rule update**: add to
    `.claude/rules/edge_case_testing.md` (or a new
    `dual_view_consistency.md` rule) that any new
    table-mutating op handler must triple-write the three
    views.
  - **Bench**: Phase 8b bench delta should be captured for
    a table-heavy fixture before/after the change. Even
    if cross-module table.copy is rare in the bench
    corpus, the in-loop overhead change should be
    measured.
  - **(c)-2.4 distiller order**: after this ADR's
    implementation lands and γ-4 is re-relaxed, (c)-2.4
    can extend the corpus distiller `supported` set
    without hitting D-126 again.

## Audit-prep configurations (9.12 substrate audit alignment)

The original Option B framing optimised for "γ-4 unblock
fast"; the user reframe (2026-05-18) prioritises landing the
fix AND keeping the codebase digestible for the 9.12
substrate audit (which revisits §4.5 dispatch-table / §4.6
build flags). The following 7 configurations re-shape Option
B so the audit isn't constrained by D-126 land's choices:

### A1. Common `mirrorWrite` helper

Land triple-write logic in **one** shared site —
`src/engine/codegen/shared/table_storage.zig::mirrorWrite(ctx,
tableidx, ...)` — and call it from each of the 5 mutating op
handlers (`emitTableCopy` / `emitTableInit` / `emitTableSet` /
`emitTableGrow` / `emitTableFill`) on both arch backends. If
the 9.12 audit decides unified storage (Option A in this
ADR's Alternatives), the helper internal becomes a no-op /
single-write; call sites stay unchanged. **Forbid inlining
the triple-write logic into per-op handlers** — the audit
cleanup grep target is the helper, not 8 scattered sites.

### A2. Scaffolding-wart `// TODO(9.12-audit)` markers

Every triple-write site (= every `mirrorWrite` callsite) AND
the `TableSlice` extern struct extension AND the
`FuncEntity.funcptr` field carry a literal
`// TODO(9.12-audit): table storage shape — see D-126 /
ADR-0068` comment. `audit_scaffolding §F` walks these via
`grep -rn "TODO(9.12-audit)" src/` so the 9.12 cleanup chunk
sees the full inventory in one shot. The 9.12 audit
deliberation document (`.dev/phase9_completion_substrate_
audit.md`) gains a Q6 row referencing this TODO marker
convention.

### A3. Contract-level fixtures, not implementation-internal

`test/edge_cases/p9/table_storage_sync/` carries 5–10 small
WAT fixtures: `table.copy 0 0` / `table.copy 0 1` / `table.
init` / `table.set` / `table.grow` each followed by a
`call_indirect` that round-trips the mutated slot. Each
fixture asserts the SPEC-EXTERNAL behaviour (= the funcref
at the post-mutation slot dispatches to the expected
func body), NOT the dual-view internals. The 9.12 audit may
unify / split / re-bind storage; these fixtures stay green
regardless because they're a contract on `call_indirect`
post-mutation correctness. Per
`.claude/rules/edge_case_testing.md` discipline (same-commit
fixture for boundary semantics).

### A4. Bundle to 3 chunks, not 6

ADR's original Forward Plan listed 6 sub-chunks; per the
chunk-granularity rule (`continue/SKILL.md` §"Bundle when
ALL hold"), collapse to:
- **Chunk α**: precondition + ABI shape — `FuncEntity.funcptr`
  field + `TableSlice` 16→24 byte stride extension + setup
  wiring in `runner_mod` / `spec_assert_runner_base` /
  `nonSimdOnModuleLoaded`. New `shared/table_storage.zig`
  with empty `mirrorWrite` stub (helper exists but does
  nothing yet; safe to land — call sites added in β/γ).
  Includes the contract-fixture set (A3) — they fail at this
  chunk's gate because mirror isn't wired.
- **Chunk β**: arm64 4-op triple-write — wire mirrorWrite
  into emitTableCopy / TableInit / TableSet / TableGrow on
  arm64; helper writes both refs + funcptr_base. Fixtures
  go green on Mac. ubuntunote stays red (x86_64 mirror
  pending).
- **Chunk γ**: x86_64 4-op triple-write + γ-4 permanent relax
  in `hasUnbindableImports`. Fixtures + spec corpus green on
  both hosts. γ-4 lands.

emitTableFill is bundled with whichever chunk touches its
sibling on each arch (likely β/γ-paired). chunk α LOC ≈ 200
(ABI + wiring + fixtures), β ≈ 250, γ ≈ 250 — all within the
800-LOC chunk cap.

### A5. Bench delta as optional baseline

The §9.8b bench-delta trigger doesn't fire for §9.9 rows,
but the triple-write's +6 inst/loop affects JIT hot paths
that Phase 15 may want to optimise. Capture
`bash scripts/run_bench.sh --quick --diff HEAD~1 > /tmp/
bench-delta.md` at chunk γ commit and paste into the
commit body under `## Bench delta (informational —
baseline for Phase 15 perf restore)`. Negative deltas are
expected and acceptable; they document the perf debt that
Phase 15 will recover.

### A6. Q3 (per-op-file) decoupling via the helper

If 9.12 substrate audit Q3 picks the per-op-file
architecture (hypothesis C in ADR-0062), `emitTableCopy`
etc. will move from `op_table.zig` to per-op files like
`feature/table/copy.zig`. **Because the triple-write goes
through `mirrorWrite` (A1), the per-op cutover only needs
to relocate the helper callsite — the mirror logic stays
intact**. Without A1, the cutover would have to re-derive
the triple-write at each new per-op file. A6 IS A1's payoff
for the audit-prep case.

### A7. Discipline rule for future table-mutating ops

A new rule `.claude/rules/dual_view_table_sync.md` codifies
the helper-must-be-called discipline so future op handlers
(e.g. Wasm 3.0 reftype additions, GC table operations)
don't accidentally bypass `mirrorWrite`. The rule
auto-loads when editing `op_table.zig` /
`feature/table/**` / `shared/table_storage.zig`.
Distinct from `abi_callee_saved_pinning.md` (which is
about ABI register-class invariants) — table-view sync is
a runtime data-structure invariant; deserves its own
header.

### Net effect of A1-A7

Phase 9 closes with γ-4 landed, 100 % PASS on the
cross-module corpus, AND the dual-view storage is wrapped
in a single-site helper + marked everywhere with
`// TODO(9.12-audit)`. The 9.12 substrate audit can pick
ANY of unify / split / per-op / per-table without touching
the call sites — only `mirrorWrite`'s body and the
`TableSlice` shape need to change. Contract fixtures
survive any of those reshapes.

## References

- ROADMAP §9.9-III (Cat III absorption per ADR-0065)
- Related ADRs:
  - [`0065_wasm_1_0_instance_work_phase9_rescope.md`](0065_wasm_1_0_instance_work_phase9_rescope.md)
    — Cat III absorption that puts D-126 in Phase 9 scope.
  - [`0066_cross_module_import_bridge_thunks.md`](0066_cross_module_import_bridge_thunks.md)
    + §A1 amendment — bridge thunk design and the D-142
    fix (A) chain. D-126 is the next blocker downstream
    of D-142 fix (A) for cross-module spec corpora.
  - [`0017_jit_function_call_marshalling.md`](0017_jit_function_call_marshalling.md)
    — original in-module call ABI; this ADR extends the
    table-mutating path without changing the call path.
  - [`0027_globals_runtime_pointer_strategy.md`](0027_globals_runtime_pointer_strategy.md)
    — runtime-ptr reservation strategy that the table
    ops' index arithmetic relies on.
  - [`0052_globals_storage_layout.md`](0052_globals_storage_layout.md)
    — pointer-per-entry shape for globals (parallel to
    the dual-view question for tables; informs why the
    reftype shape stays a FuncEntity ptr).
- Debt:
  - D-126 (this row; updated 2026-05-18 with γ-4 evidence
    and Option A/B/C enumeration; D-143 absorbed).
  - D-079 (sibling cross-module imports row; sub-gap ii
    v128 still open).
- Lessons:
  - [`2026-05-04-beta-funcref-encoding-rejected.md`](../lessons/2026-05-04-beta-funcref-encoding-rejected.md)
    — why the reftype shape must remain `*FuncEntity`
    (rules out Option A).
  - [`2026-05-17-gamma3d-dispatch-write-segv-bisect.md`](../lessons/2026-05-17-gamma3d-dispatch-write-segv-bisect.md)
    — D-142 investigation chain that preceded D-126's
    exposure.
- Close-plan: [`../phase9_close_plan.md`](../phase9_close_plan.md)
  §6 step (c) — Cat III work umbrella.

## Revision history

| Date       | SHA          | Note                                                                                                                          |
|------------|--------------|-------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-18 | `<backfill>` | Initial proposed version (Phase 9 §9.9-III D-126 discharge plan). User review pending before flipping `Status: Accepted`.                          |
| 2026-05-18 | `<backfill>` | Accepted with audit-prep amendments §A1–A7 (user-approved 100% PASS not negotiable + 9.12 audit-friendly). Sub-chunks collapsed 6→3 (α/β/γ). Q6 anchor for 9.12. |
