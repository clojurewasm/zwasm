# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/decisions/0075_x86_64_emitctx_ctx_passing_unification.md`](decisions/0075_x86_64_emitctx_ctx_passing_unification.md)
   (Status: Proposed — user-confirmed 2026-05-19; flip to Accepted in
   the B53 commit per ROADMAP §18.2). This ADR drives B53..B6x. Its
   §"Implementation plan" lists concrete steps; execute B53 first.
2. **READ NEXT** [`.dev/phase9_completion_master_plan.md`](phase9_completion_master_plan.md)
   (master plan v2). §9.12-A `[x]` 2026-05-19; §9.12-B is the active
   row. **B30..B52 covered the dispatcher-signature-compatible cohort
   (374/581 IR-axis, 348/314 arch-axis); B53+ is gated on ADR-0075**.
3. `git log --oneline -10` — recent autonomous-loop chunks under
   `chore(p9b):` / `feat(p9b):` prefix. Last source commit
   `89261705` (B59 — reinterpret + promote/demote cohort migrated
   to `(ctx, ins)`; existing B28 stubs converted in place).
4. `bash scripts/p9_completion_status.sh` — live progress.
5. `bash scripts/p9_simd_status.sh` — live SIMD status.
6. `.dev/debt.md` `now` rows: none.

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
| B15 | i32 compare cohort: eq/ne/lt_s/lt_u/gt_s/gt_u/le_s/le_u/ge_s/ge_u × 2 arches. 30 new files | `0ac5c145` |
| B16 | i64 compare cohort: 10 ops at i64 width × 2 arches with emitI64Compare. 30 new files | `66dcd8d2` |
| B17 | i32/i64 eqz + shift cohort: 12 ops × 2 arches; heterogeneous delegates per arch. 36 new files | `c485f445` |
| B18 | i32/i64 bitcount cohort: clz/ctz/popcnt × 2 widths = 6 ops × 2 arches. 18 new files | `ca1ffb46` |
| B19 | i32/i64 sign-extension cohort: 5 ops × 2 arches (first wasm_2_0/ files). 15 new files | `4fb99ff1` |
| B20 | i32/i64 divide+remainder cohort: 8 ops, arm64-only migration (x86_64 deferred due to bounds_fixups arg). 16 new files | `ec83e434` |
| B21 | width-conversion cohort: 3 ops × 2 arches (i32.wrap_i64 + i64.extend_i32_{s,u}). 9 new files | `413d5278` |
| B22 | f32/f64 arithmetic cohort: 8 ops × 2 arches (add/sub/mul/div). 24 new files | `bf4f6453` |
| B23 | f32/f64 compare cohort: 12 ops × 2 arches (eq/ne/lt/gt/le/ge). 36 new files | `32e3efb8` |
| B24 | f32/f64 unary cohort: 14 ops × 2 arches (abs/neg/sqrt/ceil/floor/trunc/nearest). 42 new files | `14e4b959` |
| B25 | f32/f64 min/max + copysign cohort: 6 ops × 2 arches. 18 new files | `c91aa0de` |
| B26 | int→float convert cohort: f32/f64.convert_i32/i64_{s,u} = 8 ops × 2 arches. 24 new files | `d4059669` |
| B27 | Wasm 2.0 trunc_sat cohort: 8 ops × 2 arches. 24 new files | `caefc955` |
| B28 | reinterpret + demote/promote cohort: 6 ops × 2 arches. 18 new files | `208f62b1` |
| B29 | SIMD v128 logical cohort: 6 ops × 2 arches. 18 new files | `97880b4e` |
| B30 | SIMD int binary arith cohort: 10 ops × 2 arches | `8277c1e1` |
| B31 | SIMD int neg/abs cohort: 8 ops × 2 arches | `b1830b13` |
| B32 | SIMD i8x16 compare cohort: 10 ops × 2 arches | `4a0ca5b2` |
| B33 | SIMD i16x8 compare cohort: 10 ops × 2 arches. 30 new files | `<backfill>` |
| B34 | SIMD i32x4 compare cohort: 10 ops × 2 arches. 30 new files | `<backfill>` |
| B35 | SIMD i64x2 compare cohort: 6 ops × 2 arches (no _u variants). 18 new files | `<backfill>` |
| B36 | SIMD int shifts cohort: 12 ops × 2 arches. 36 new files | `<backfill>` |
| B37 | SIMD int min/max cohort: 12 ops × 2 arches. 36 new files + @setEvalBranchQuota bump | `<backfill>` |
| B38 | SIMD int sat arith + avgr_u (heterogeneous): Zone 1 × 10 + x86_64 × 10 + arm64 avgr_u × 2 | `<backfill>` |
| B39 | SIMD float arith cohort: 16 ops × 2 arches. 48 new files | `<backfill>` |
| B40 | SIMD float unary cohort: 14 ops × 2 arches. 42 new files | `<backfill>` |
| B41 | SIMD float compare cohort: 12 ops × 2 arches. 36 new files | `<backfill>` |
| B42 | SIMD bool reductions cohort: 9 ops × 2 arches. 27 new files | `<backfill>` |
| B43 | SIMD narrow + extend cohort: 16 ops × 2 arches. 48 new files | `<backfill>` |
| B44 | SIMD extmul + extadd_pairwise cohort (x86_64-only; 16 ops). 32 new files | `<backfill>` |
| B45 | SIMD misc heterogeneous cohort (swizzle + popcnt arm64 + dot + q15mulr + 7 fp conv/trunc_sat = 11 ops). 30 new files. 316/290/307 of 581 | `<backfill>` |
| B46 | arm64 globals + table cohort (9 ops, arm64-only). 18 new files | `<backfill>` |
| B47 | arm64 scalar load/store cohort (23 ops, arm64-only). 46 new files | `<backfill>` |
| B48 | arm64 memory.{fill,copy,init} cohort (3 ops, arm64-only). 6 new files | `<backfill>` |
| B49 | arm64 call cohort: 2 ops, arm64-only. 4 new files | `<backfill>` |
| B50 | arm64 control flow scalar cohort (6 ops, arm64-only). 12 new files | `<backfill>` |
| B51 | arm64 trapping trunc cohort: 8 ops, arm64-only. 16 new files | `<backfill>` |
| B52 | SIMD splats + ref.is_null cohort (7 ops, both arches): i{8x16,16x8,32x4,64x2}.splat + f{32x4,64x2}.splat + ref.is_null. 21 new files. 374/348/314 of 581 | `<backfill>` |
| B53 | ADR-0075 Accepted + x86_64 EmitCtx substrate. New file `src/engine/codegen/x86_64/ctx.zig` mirrors arm64's shape; `EmitCtx.init(args: InitArgs)` factory keeps emit.zig under the 2000-line hard cap. Initialised once at the top of `compile()`'s body-loop; `_ = &ctx;` keeps it inert until B54. No behaviour change. | `952e1a33` |
| B54 | PoC: migrate `i32.div_s` end-to-end to `(ctx, ins)`. New `op_alu_int.emitI32DivS(ctx, ins)` adapter; emit.zig dispatch arm splits div_s from div_u/rem_s/rem_u; new per-op file `x86_64/ops/wasm_1_0/i32_div_s.zig`; parallel `collected_x86_64_ctx_ops` tracks the migration (legacy tuple stays 314 until B6x+1 cutover). | `f1f62ba8` |
| B55 | Cohort migration: remaining div / rem variants (`i32.div_u` / `i32.rem_s` / `i32.rem_u` + i64 family) to `(ctx, ins)`. 7 per-op aliases (i32 cohort via `emitI32DivS` alias; i64 via `emitI64DivS` alias) + 7 per-op files + `collected_x86_64_ctx_ops` 1 → 8. | `c4ef5e11` |
| B56 | Cohort migration: trapping trunc cohort (`i{32,64}.trunc_f{32,64}_{s,u}`) to `(ctx, ins)`. 8 per-op aliases (signed family via `emitI32TruncF32S` alias; unsigned via `emitI32TruncF32U` alias) + 8 per-op files + `collected_x86_64_ctx_ops` 8 → 16. | `d663b8f4` |
| B57 | Cohort migration: Wasm 2.0 trunc_sat cohort (`i{32,64}.trunc_sat_f{32,64}_{s,u}`, 8 ops) to `(ctx, ins)`. Existing B27 7-arg stubs converted in place; moved from `collected_x86_64_ops` (314 → 306) to `collected_x86_64_ctx_ops` (16 → 24). Three group aliases per consumer (`emitFpTruncSatSigned` / `U32` / `U64`). | `3877b3cf` |
| B58 | Cohort migration: Wasm 1.0 int→float convert cohort (`f{32,64}.convert_i{32,64}_{s,u}`, 8 ops) to `(ctx, ins)`. Existing B26 7-arg stubs converted in place; moved from `collected_x86_64_ops` (306 → 298) to `collected_x86_64_ctx_ops` (24 → 32). Two group aliases (`emitFpConvertSimple` for 6 of 8, `emitFpConvertI64Unsigned` for i64_u pair). | `8c8d849d` |
| B59 | Cohort migration: reinterpret + promote/demote cohort (`i{32,64}.reinterpret_f{32,64}`, `f{32,64}.reinterpret_i{32,64}`, `f64.promote_f32`, `f32.demote_f64`, 6 ops) to `(ctx, ins)`. B28 7-arg stubs converted in place; moved from `collected_x86_64_ops` (298 → 292) to `_ctx_ops` (32 → 38). Single `emitFpConvertSimple` consumer (1 primary + 5 aliases). | `89261705` |
| **B60** | **Cohort migration: scalar load/store cohort (24 ops via `op_memory.emitMemOp` — `i{32,64}.load*`, `i{32,64}.store*`, `f{32,64}.load`/`store`)** to `(ctx, ins)`. Single legacy consumer. Existing per-op stubs at `x86_64/ops/wasm_1_0/` (likely from earlier B-series) — convert in place per B57/B58/B59 pattern. May exceed 800 LOC threshold — split into load (12) + store (12) sub-chunks if needed. | **NEXT** |
| B60..B6x | Bulk migrate remaining x86_64 emit fns in cohorts (5–15 ops/chunk per LOOP.md). Suggested order: scalar load/store → memory.{fill,copy,init} → table ops → globals → const → call → local. | |
| B6x+1 | Inline-switch dispatcher cutover per ADR-0073 — both arches' `emit.zig` giant switch replaced by `inline for (collected_X_ops) |op_mod| { if (op_mod.op_tag == ins.op) return op_mod.emit(ctx, ins); }`. Moment per-op files become load-bearing. | |

## Active state — §9.12-B mid-flight; B59 reinterpret cohort landed 2026-05-20

**B60 is the active task** — cohort migrate the scalar load/store
variants (~24 ops via `op_memory.emitMemOp` — `i32/i64.load*`,
`i32/i64.store*`, `f32/f64.load`/`store`) to the `(ctx, ins)`
shape. B59 closed the reinterpret/promote/demote cohort at
`89261705` (`collected_x86_64_ctx_ops` 32 → 38;
`collected_x86_64_ops` 298 → 292 by moving B28 stubs).

The loop for B60 mirrors B57-B59:

1. Survey `op_memory.emitMemOp` signature — it likely takes
   `bounds_fixups` + `ins.payload` + `func.func_idx`; the ctx
   adapter unpacks all from `*EmitCtx`.
2. Add `(ctx, ins)` adapter in op_memory.zig (or wrapper in
   op_convert/separate file); aliases for all 24 variants.
3. Replace the grouped arm in emit.zig (lines ~962-985) with
   24 per-op arms calling `(ctx, ins)` adapters via `&ctx`.
4. Convert existing per-op stub files in place (likely
   `i32_load.zig`, `i32_load8_s.zig`, etc — check first).
5. Update `collected_x86_64_ctx_ops` (38 → 62) + legacy tuple
   (292 → 268) + both assertion tests.
6. If diff > 800 LOC: split into load-only (12) + store-only
   (12) sub-chunks per LOOP.md chunk granularity.
7. Verify 2-host green; commit + push.

Note: op_convert.zig is now 1009 LOC (soft cap warn at 1000) —
the file may need a split plan in §9.12-D cleanup. Not blocking.

§9.12-B exit criterion stays as ROADMAP §9.12-B specifies (6 build
combos green + DCE 0 + completeness comptime check). Per-op file
substrate becomes load-bearing at B6x+1 (inline-switch cutover).

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
[`0073`](decisions/0073_build_option_dce_substrate.md) /
[`0074`](decisions/0074_per_op_file_zone_split.md);
Proposed (active, B53 will flip): [`0075`](decisions/0075_x86_64_emitctx_ctx_passing_unification.md);
amends [`0023`](decisions/0023_src_directory_structure_normalization.md) §4.5
+ [`0050`](decisions/0050_adr_lifecycle_and_skip_adr_enforcement.md) D-5/D-6.
Enforcement: [`scripts/p9_completion_status.sh`](../scripts/p9_completion_status.sh)
+ [`gate_consolidation_study.md`](gate_consolidation_study.md).
Bootstrap framework: [`src/ir/dispatch_collector.zig`](../src/ir/dispatch_collector.zig)
(empty `collected_ops` ready for §9.12-B per-op files).
