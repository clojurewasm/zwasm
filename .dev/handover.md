# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_completion_master_plan.md`](phase9_completion_master_plan.md)
   (master plan v2). §9.12-A `[x]` 2026-05-19; **§9.12-B is the next
   active row** (the biggest sub-row in the §9.12 cohort).
2. `git log --oneline -10` — recent autonomous-loop chunks under
   `chore(p9b):` prefix. §9.12-A subchunks A1..A7 landed in commits
   `f3626d77` (A1) through `8871f7ed` (close). Hotfix at `3461823a`.
3. `bash scripts/p9_completion_status.sh` — live progress per the
   enforcement-layer scripts; cites `bench/results/skip_impl_history.yaml`
   baseline 243.
4. `bash scripts/p9_simd_status.sh` — live SIMD status (13301/0/440
   Mac+ubuntu bit-identical).
5. `.dev/debt.md` `now` rows: none.

## §9.12-B progress (sub-chunks)

| Sub-chunk | Description | SHA |
|---|---|---|
| B1 | i32_add per-op file foundation (template + collector wire; stubs only; legacy dispatch retains authority) | `bb85b918` |
| B2 | dispatcher(comptime axis: Axis) function in dispatch_collector | `3660e3fa` |
| B3 | Dispatcher wire design note (`.dev/dispatcher_wire_design.md`); B-sequence revised per bytecode-vs-ZirOp layer findings | `19f3e04c` |
| B4 | arm64/emit.zig wire (cleanest; ZirOp + switch; i32.add proof-of-pattern; dispatcher narrowed to DispatchError) | `a33b6eb7` |
| B5 | x86_64/emit.zig wire (mirror of B4 pattern) | `a9f6b499` |
| B6 | interp populateDispatchTable (table-population scaffolding; activates when per-op handlers gain InterpFn signature) | `02925324` |
| B7 | wasm_byte_map.byteToZirOp helper + validator.zig wire (3 bytes mapped: i32.add/sub/mul) | `6eb27fe0` |
| B8 | lower.zig wire (mirror of B7; closes 5-of-5 dispatcher wires) | `bc7cde3d` |
| B9 | ADR-0074 — per-op file zone split along axis boundary (Zone 1: validate/lower/interp; Zone 2: arm64/x86_64). Amends ADR-0023 §4.5. Design-only; no code change | `5b42f526` |
| B10 | Zone 2 collector at `src/engine/codegen/dispatch_collector.zig` (ArchAxis = arm64/x86_64) + per-arch i32_add stubs at `src/engine/codegen/<arch>/ops/wasm_1_0/i32_add.zig`. i32_add.zig handlers aggregate narrowed to 3 IR-axes. arm64/x86_64 emit.zig wires retargeted to Zone 2 collector | `23ee2e6d` |
| B11 | arm64 i32.add real body migration; dispatcher refactor to bool-return + inferred-error pattern (no DispatchError shrapnel; per-arch file existing = migrated); x86_64 i32.add stub deferred to B12 | `e39db505` |
| B12 | x86_64 i32.add real body migration (mirror of B11; reuse op_alu_int.emitI32Binary's 7-arg signature) | `48bf44f4` |
| B13 | i32 binary ALU cohort migration to per-arch op files: i32.sub / i32.mul / i32.and / i32.or / i32.xor (5 ops × 2 arches; same emit body pattern as i32.add). 15 new files + collector updates | `d83aba97` |
| B14 | i64 binary ALU cohort migration: i64.add/sub/mul/and/or/xor × 2 arches. 18 new files | `0df0c44c` |
| B15 | i32 compare cohort: eq/ne/lt_s/lt_u/gt_s/gt_u/le_s/le_u/ge_s/ge_u × 2 arches. 30 new files | `<backfill>` |
| B16 | i64 compare cohort: same 10 ops at i64 width × 2 arches. Mirror of B15 with emitI64Compare. 30 new files | **NEXT** |
| B17..Bn | per-arch cohort migration (5-15 ops/chunk per arch). IR-axis (validate/lower/interp) migration deferred until cross-Zone-1 circular-dep is resolved | |

## Active state — §9.12-A [x]; §9.12-B autonomous (HUGE row)

§9.12-B Q3 C adoption completion + build-option DCE extension across
all 4 layers (IR/CLI/c_api/WASI):

1. Per-op file migration of all 581 ZirOp handlers from monolithic
   switches in `validator.zig` / `lower.zig` / `arm64/emit.zig` /
   `x86_64/emit.zig` / `interp/dispatch.zig` into
   `src/instruction/wasm_X_Y/<op>.zig` per ADR-0023 §4.5 amend +
   ADR-0073.
2. `dispatch_collector.zig` (A4 bootstrap; currently `collected_ops =
   {}`) gains the 581 op imports + the 5 dispatcher rewrites.
3. **CLI** declarative `args = .{ ... }` form with `wasm_level` /
   `wasi_level` metadata + comptime filter (per ADR-0073 §Layer 2).
4. **c_api** `exports = .{ ... }` form with `comptime @export` filter
   + `include/wasm.h` preprocessor gate (per ADR-0073 §Layer 3).
5. **WASI** `syscalls = .{ ... }` form with `wasi_level` metadata
   (per ADR-0073 §Layer 4).
6. Exit: `zig build -Dwasm={v1_0,v2_0,v3_0} -Dwasi={p1,p2} test-all`
   green for all 6 combinations; `scripts/check_build_dce.sh --gate`
   = 0; per-op file completeness comptime check passes.

This is a multi-week / multi-chunk row. Suggested chunking:

| Sub-chunk | Description |
|---|---|
| B1 | First batch of per-op file migrations (Wasm 1.0 control/numeric/parametric subset; ~50 ops) + dispatch_collector validate-axis wired |
| B2 | Wasm 1.0 memory/variable/table subset (~80 ops); validator + interp axes wired |
| B3 | Wasm 1.0 closing batch (control, refs, etc.); arm64-emit + x86_64-emit axes wired; lower.zig axis wired |
| B4 | Wasm 2.0 (SIMD + bulk-memory + nontrap-conv + sign-ext) per-op file migration |
| B5 | Wasm 3.0 placeholder stubs (all return `error.NotMigrated`) |
| B6 | CLI / c_api / WASI declarative form (3 layers) |
| B7 | check_build_dce all-6 combinations green + comptime check enforcement enabled |

Default chunk size per `LOOP.md` §Chunk granularity = 5-15 ops or
substrate change.

## Outstanding upstream / Phase-10 blockers

- **D-148** (Zig 0.16 self-hosted x86_64 backend miscompile):
  blocked-by upstream; workaround `build.zig` `.use_llvm = true`
  continues.

### Discipline reminders

- No `--no-verify`. 2-host per chunk (Mac + ubuntunote); windowsmini
  deferred to §9.13-0 per ADR-0049.
- Pre-push hook now runs check_subrow_exit + check_skip_impl_ratchet
  (per §9.12-A close); both are cheap when there's nothing to flag.
- Master plan §"don't give up" + ADR-0073 = no compromise on DCE
  literal absence.

## References

PRIMARY: [`phase9_completion_master_plan.md`](phase9_completion_master_plan.md).
Substrate audit doc: [`phase9_completion_substrate_audit.md`](phase9_completion_substrate_audit.md)
(§Decisions filled at §9.12 collab close).
Accepted ADRs: [`0070`](decisions/0070_libc_dependency_policy.md) /
[`0071`](decisions/0071_phase9_substrate_audit_resolution.md) /
[`0072`](decisions/0072_comment_as_invariant_rule.md) /
[`0073`](decisions/0073_build_option_dce_substrate.md);
amends [`0023`](decisions/0023_src_directory_structure_normalization.md) §4.5
+ [`0050`](decisions/0050_adr_lifecycle_and_skip_adr_enforcement.md) D-5/D-6.
Enforcement: [`scripts/p9_completion_status.sh`](../scripts/p9_completion_status.sh)
+ [`gate_consolidation_study.md`](gate_consolidation_study.md).
Bootstrap framework: [`src/ir/dispatch_collector.zig`](../src/ir/dispatch_collector.zig)
(empty `collected_ops` ready for §9.12-B per-op files).
