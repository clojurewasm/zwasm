## §9.12-B progress (sub-chunks)

> **Doc-state**: ARCHIVED-IN-PLACE

> **Schema version 1 (pre-2026-05-21)** — `Sub-chunk | Description
> | SHA`. B1–B158 are grandfathered without a `Type` column per
> close-plan §6 (b). New phase_log files use schema v2
> (`Sub-chunk | Type | Description | SHA`) — see
> [`.claude/skills/continue/LOOP.md` §"Chunk types"](../../.claude/skills/continue/LOOP.md).

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
| B60 | Cohort migration: scalar load/store cohort (23 ops via `op_memory.emitMemOp`) to `(ctx, ins)`. 23 NEW per-op files (these ops were never in legacy tuple — only emit.zig's grouped switch arm). Single primary `emitI32Load` + 22 aliases. `collected_x86_64_ctx_ops` 38 → 61; legacy tuple unchanged at 292. | `18ac9b49` |
| B61 | Cohort migration: bulk-memory cohort (`memory.fill` / `memory.copy` / `memory.init`, 3 ops) to `(ctx, ins)`. 3 distinct adapters (no aliases — fill/copy/init use distinct legacy helpers). 3 NEW per-op files. `_ctx_ops` 61 → 64; legacy unchanged at 292. data.drop / elem.drop deferred (no Zone 1 meta files). | `84abd51e` |
| B62 | Cohort migration: globals cohort (`global.get` / `global.set`, 2 ops) to `(ctx, ins)`. 2 distinct adapters (set has no `next_vreg`). 2 NEW per-op files. `_ctx_ops` 64 → 66; legacy unchanged at 292. | `f4aac465` |
| B63 | Cohort migration: table ops cohort (`table.{get,set,size,grow,fill,copy,init}`, 7 ops) to `(ctx, ins)`. 7 distinct adapters (heterogeneous — table.copy/init use ins.extra; table.grow uses outgoing_max_bytes). 7 NEW per-op files. `_ctx_ops` 66 → 73; legacy unchanged at 292. | `344e1d29` |
| B64 | Cohort migration: call cohort (`call`, `call_indirect`, 2 ops) to `(ctx, ins)`. 2 distinct adapters in op_call.zig. 2 NEW per-op files. `_ctx_ops` 73 → 75; legacy unchanged at 292. Scalar `*.const` + `ref.{null,func}` cohort deferred (Zone 1 meta files missing). | `c6eccb2b` |
| B65 | Cohort migration: control-structure cohort (`block`, `loop`, 2 ops) to `(ctx, ins)`. 2 distinct adapters in op_control.zig. 2 NEW per-op files. `_ctx_ops` 75 → 77; legacy unchanged at 292. local.{get,set,tee} + br/br_if/br_table/if/else/end/return/unreachable deferred (Zone 1 meta files missing OR emit.zig private helpers need extraction). | `e81266f4` |
| B66 | Zone 1 meta-file backfill: 16 NEW meta files at `src/instruction/wasm_1_0/` (br/if_/end_/return_/unreachable_/select/drop/local_{get,set,tee}/{i32,i64,f32,f64}_const/ref_{null,func}). Substrate chunk — no Zone 2 / collector changes. Unblocks 3+ future cohorts. | `750191e5` |
| B67 | Cohort migration: const cohort (`i32.const`, `i64.const`, `f32.const`, `f64.const`, 4 ops) to `(ctx, ins)`. Extracted i32/i64.const inline bodies into op_alu_int helpers; f32/f64.const wrap existing `emitFpConst` via op_alu_float aliases. 4 NEW per-op files. `_ctx_ops` 77 → 81; legacy unchanged at 292. | `ee5d604b` |
| B68 | Cohort migration: ref cohort (`ref.null`, `ref.func`, 2 ops) to `(ctx, ins)`. Extracted inline bodies into `op_alu_int.emit{RefNull,RefFunc}` adapters. 2 NEW per-op files. `_ctx_ops` 81 → 83; legacy unchanged at 292. | `7a6c6a77` |
| B69 | Single-op migration: `drop` to `(ctx, ins)`. Inline body (pop vreg, no codegen) → `op_control.emitDropCtx`. 1 NEW per-op file. `_ctx_ops` 83 → 84. Select deferred to B70. | `75c463f6` |
| B70 | Single-op migration: `select` (+ `select_typed` shares emit arm) to `(ctx, ins)`. ~70-line 3-path body extracted into `op_alu_int.emitSelectCtx` (added op_simd + op_alu_float imports to op_alu_int; no cycle). 1 NEW per-op file. `_ctx_ops` 84 → 85. | `74734076` |
| B71 | Cohort migration: `memory.size` + `memory.grow` (2 ops) to `(ctx, ins)`. Inline meta backfill (memory_size.zig + memory_grow.zig at Zone 1). memory.size body extracted to op_call.emitMemorySizeCtx; memory.grow wraps existing emitMemoryGrow. 2 NEW per-op files. `_ctx_ops` 85 → 87. | `aa7455d9` |
| B72 | Single-op migration: `nop` (1 op) to `(ctx, ins)` + Zone 1 meta backfill. Zero-bytes adapter at op_control.emitNopCtx. 1 NEW per-op file. `_ctx_ops` 87 → 88. atomic.fence deferred (UnsupportedOp on x86_64); unreachable deferred (ctx ext for `dead_code` local needed). | `095ea19d` |
| B73 | Single-op migration: `unreachable` to `(ctx, ins)` with ctx extension (added `dead_code: *bool` field to EmitCtx, mirrors existing pointer-to-local pattern). 1 NEW per-op file. `_ctx_ops` 88 → 89. | `608e8f45` |
| B74 | Single-op migration: `return` to `(ctx, ins)` with ctx extension (added `frame_bytes: u32` + `uses_runtime_ptr: bool` set-once fields). Marshal + epilogue + RET sequence extracted. 1 NEW per-op file. `_ctx_ops` 89 → 90. | `2166c0a8` |
| B75 | Cohort migration: br family (`br` + `br_if` + `br_table`, 3 ops) to `(ctx, ins)`. All ctx fields already present post-B74 (no extension). emitBrCtx sets dead_code; br_if / br_table fall through. 3 NEW per-op files. `_ctx_ops` 90 → 93. | `a19573c8` |
| B76 | Cohort migration: `if` + `else` (2 ops) to `(ctx, ins)`. emitIfCtx threads ins.extra (blocktype/arity); emitElseCtx is a thin wrapper. All ctx fields already present (no extension). 2 NEW per-op files. `_ctx_ops` 93 → 95. `end` deferred (function-level form pulls in marshal + epilogue + trap-stub + bounds-fixup, ~60 LOC; split into emitEndInter/emitEndIntra is a chunk of its own). | `fdcc03e7` |
| B77 | Single-op migration: `end` to `(ctx, ins)`. emitEndCtx dispatches on `labels.items.len`: intra-function form reuses existing emitEndIntra; function-level form (new emitEndInter helper) extracts marshalReturnRegs + epilogue + RET + trap stub (bounds_fixups/unreach_fixups) + SIMD const-pool emission + RIP-rel fixup patching. emit.zig dispatch arm snapshots labels.len pre-call for body-loop break. All ctx fields already present (no extension); new jit_abi import in op_control. 1 NEW per-op file. `_ctx_ops` 95 → 96. emit.zig 1828 → 1753 LOC. | `0e2f75d2` |
| B78 | Cohort migration: local ops (`local.get` / `local.set` / `local.tee`, 3 ops) to `(ctx, ins)`. New op_locals.zig host module with 3 helpers + 3 adapters. ctx ext: `total_locals: u32` + `local_disps: []const i32` (set once at function entry; mirror B74 pattern). Unused `localValType` wrapper deleted (was a no-op pass-through). 3 NEW per-op files. `_ctx_ops` 96 → 99. emit.zig 1753 → 1599 LOC. | `95fa70fd` |
| B79 | Legacy → ctx cohort move: i32 binary ALU (i32.add/sub/mul/and/or/xor, 6 ops). New `emitI32BinaryCtx(ctx, ins)` adapter wraps existing emitI32Binary. 6 per-op files regenerated. Legacy 292 → 286; ctx 99 → 105. Pattern mirrors B57/B58/B59. | `075224c0` |
| B80 | Legacy → ctx cohort move: i64 binary ALU (6 ops). Mirror of B79; emitI64BinaryCtx adapter. Legacy 286 → 280; ctx 105 → 111. | `31898f22` |
| B81 | Legacy → ctx cohort move: i32 compare (10 ops). emitI32CompareCtx adapter. Legacy 280 → 270; ctx 111 → 121. | `0d64626c` |
| B82 | Legacy → ctx cohort move: i64 compare (10 ops). emitI64CompareCtx adapter. Legacy 270 → 260; ctx 121 → 131. | `ce698ad2` |
| B83 | Legacy → ctx cohort move: i32+i64 shift (10 ops). emitI{32,64}ShiftCtx adapters. Legacy 260 → 250; ctx 131 → 141. | `caa09171` |
| B84 | Legacy → ctx cohort move: bitcount (6) + eqz (2) = 8 ops. 4 adapters. Legacy 250 → 242; ctx 141 → 149. | `38164478` |
| B85 | Legacy → ctx cohort move: sign-ext (5) + width-conv (3) = 8 ops. Legacy 242 → 234; ctx 149 → 157. | `0a94c60a` |
| B86 | Legacy → ctx cohort move: FP arith (8 ops). Legacy 234 → 226; ctx 157 → 165. | `130eeec9` |
| B87 | Legacy → ctx cohort move: FP compare (12 ops). Legacy 226 → 214; ctx 165 → 177. | `2b3c1d81` |
| B88 | Legacy → ctx cohort move: FP unary (14 ops). Legacy 214 → 200; ctx 177 → 191. | `22f6a06f` |
| B89 | Legacy → ctx cohort move: FP min/max+copysign (6 ops). Legacy 200 → 194; ctx 191 → 197. | `4ec2bff1` |
| B90 | Legacy → ctx SIMD cohort move: v128 logical (6 ops). First SIMD migration. Legacy 194 → 188; ctx 197 → 203. | `766ffade` |
| B91 | Legacy → ctx SIMD cohort move: int binary arith (10 ops; i64x2.mul deferred). Legacy 188 → 178; ctx 203 → 213. | `8f6d0c83` |
| B92 | Legacy → ctx SIMD cohort move: int neg/abs (8 ops). Legacy 178 → 170; ctx 213 → 221. | `f66ed1f9` |
| B93 | Legacy → ctx SIMD cohort move: i8x16 compare (10 ops). Legacy 170 → 160; ctx 221 → 231. | `ba509a26` |
| B94 | Legacy → ctx SIMD cohort move: i16x8 compare (10 ops). Legacy 160 → 150; ctx 231 → 241. | `10f18f43` |
| B95 | Legacy → ctx SIMD cohort move: i32x4 compare (10 ops). Legacy 150 → 140; ctx 241 → 251. | `840e15f2` |
| B96 | Legacy → ctx SIMD cohort move: i64x2 compare (6 ops, no _u). Legacy 140 → 134; ctx 251 → 257. | `7efa6e2b` |
| B97 | Legacy → ctx SIMD cohort move: int shifts (12 ops). Legacy 134 → 122; ctx 257 → 269. | `f6814fb3` |
| B98 | Legacy → ctx SIMD cohort move: int min/max (12 ops). Legacy 122 → 110; ctx 269 → 281. | `f7f5e155` |
| B99 | Legacy → ctx SIMD cohort move: int sat arith (10 ops). Legacy 110 → 100; ctx 281 → 291. | `f9c8fc10` |
| B100 | Legacy → ctx SIMD cohort move: f32x4 arith (8 ops). Legacy 100 → 92; ctx 291 → 299. | `e2ea1b5f` |
| B101 | Legacy → ctx SIMD cohort move: f64x2 arith (8 ops). Legacy 92 → 84; ctx 299 → 307. | `34a1ca6f` |
| B102 | Legacy → ctx SIMD cohort move: float unary (14 ops). Legacy 84 → 70; ctx 307 → 321. | `e214d151` |
| B103 | Legacy → ctx SIMD cohort move: float compare (12 ops). Legacy 70 → 58; ctx 321 → 333. | `8a1b8c3b` |
| B104 | Legacy → ctx SIMD cohort move: bool reductions (9 ops). Legacy 58 → 49; ctx 333 → 342. | `d4bdad29` |
| B105 | Legacy → ctx SIMD cohort move: narrow + extend (16 ops; 12 extend 5-arg + 4 narrow 6-arg). FILE-SIZE-EXEMPT marker added (file at 2015 lines). Legacy 49 → 33; ctx 342 → 358. | `20aae453` |
| B106 | Legacy → ctx SIMD cohort move: extmul (12 ops; all 5-arg). Adapters in op_simd_int_cmp_lane.zig (FILE-SIZE-EXEMPT already in place from B105). Legacy 33 → 21; ctx 358 → 370. | `9732e831` |
| B107 | Legacy → ctx SIMD residual cohort (21 ops): ref.is_null + 6 splats + swizzle + 4 extadd_pairwise + dot + q15mulr_sat + 7 fp-conv. Legacy 21 → 0 — x86_64 legacy tuple empty. ctx 370 → 391. | `71dc1156` |
| B108 | Soft inline-switch cutover for x86_64: new `dispatchX86_64Ctx` walks collected_x86_64_ctx_ops (391); wired before the giant switch. | `d2b1e9d2` |
| B109 | Pruned 242 dead switch arms in x86_64/emit.zig. emit.zig 1628→1300 LOC. Remaining arms cover payload-laden / no-Zone-1-meta ops (extract_lane / replace_lane / shuffle / i64x2.mul / v128.const / load_lane / store_lane / popcnt / trunc_sat_f64x2 / convert_low_i32x4_u + multi-line `end`). | `fc6cc1d3` |
| B110 | arm64 inline-switch cutover (mirror of B109 for arm64). Removed 221 dead arms in arm64/emit.zig + 6 unused imports. emit.zig 1995→1630 LOC. Per-op files load-bearing for 348 ops via dispatch_collector.dispatch(.arm64, ...). Both arches complete. | `c1780807` |
| B111 | §9.12-B exit check ran `check_build_dce.sh --gate`. 4/6 combos clean; **2/6 FAIL**: v1_0:p1 and v1_0:p2 contain `_instruction.wasm_2_0.*` symbols. Filed D-150. | (debt-only) |
| B112 | D-150 closed: `wasm_2_0_enabled` comptime gate in src/api/instance.zig (imports + register calls). All 6 DCE combos now clean. v1_0 binary -7.5KB. §9.12-B flipped to [x]. | `59bde111` |
| B113 | §9.12-C substrate prep: abi.zig adds `table_emit_scratch_gprs` + `memory_emit_scratch_gprs` named-constant pools + extended comptime disjointness assert. | `03959b75` |
| B114 | §9.12-C docs: added "Stress axes" section to `.claude/rules/edge_case_testing.md` (8 named axes: numeric range / alignment / register pressure / dispatch shape / ABI boundary / control flow / validator strictness / cross-module). | `c139c5af` |
| B115 | §9.12-C audit §G.3 strengthening: `check_invariant_comments.sh` now also greps forbidden-phrase patterns from single_slot_dual_meaning.md. Combined --strict gate. | `c67d3e35` |
| B116 | §9.12-C bug_fix_survey.md tightening: inlined 4-item Step 4 checklist (same-class-cases grep / multi-tag arm audit / §14 re-read / boundary fixture). B109's select_typed regression now named as case study. | `7d894171` |
| B117 | Lesson capture: `2026-05-20-inline-switch-cutover-dce-substrate-coupling.md` documents B108-B112 retrospective (use-site DCE gating requirement + B109 select_typed regression). | `c356d5ae` |
| B118 | abi.zig overlap rationale documented inline (spill_stage/table_emit X14/X15 share is intentional + d-64 pattern keeps simultaneous use ≤ 2). Sets the contract for the D-133 sweep. | `c3652994` |
| B119 | D-133 sweep investigation **BLOCKED**: B118's "≤ 2 simultaneous scratch" claim holds only for trivial single-load ops (already discharged at d-64/d-66). The 5 remaining bulk handlers (`emitTableFill` / `emitTableCopy` / `emitTableInit` / `emitMemoryInit`) hold ≥ 4 simultaneously-live scratches in their loop bodies that cannot map to {X14, X15} or even {X14..X17}. `emitTableGrow` re-classified — not a D-133 site (uses AAPCS64 args). Three resolution paths enumerated in updated D-133 body (per-handler stack save/restore / pool extension / live-vreg fence) — ADR-required. Lesson at `.dev/lessons/2026-05-20-d133-sweep-pool-size-insufficient.md`. Latent count stays at 55 (no corpus trigger; deferral acceptable). | (debt+lesson only) |
| B120 | ADR-0077 Proposed → **Accepted** (user-confirmed 2026-05-20). Path (c) regalloc op-internal scratch reservation. Spike skeleton `private/spikes/regalloc-live-fence/` scaffolded with hypothesis + setup + 8-step post-spike implementation plan. D-133 row updated to `blocked-by: ADR-0077 implementation`. | `1bc9c09b` |
| B121 | Spike validation. `private/spikes/regalloc-live-fence/fence.zig` (gitignored) — 7-test self-contained harness validates ADR-0077 end-to-end (API shape + walker integration + verifier). All 7 tests green. ADR-0077 needs no amendment. Findings captured at `.dev/lessons/2026-05-20-regalloc-fence-design-validation.md`. | `e6bc9cff` |
| B122 | Regalloc walker fence plumbing. `ScratchReservationFn` type + `forbiddenMaskForVreg` / `slotForbidden` helpers + 4th param on `computeWith` (null = no-op fence). `compile.zig` passes null; bit-for-bit identical to pre-fence path until B125. 4 new tests cover null-fence regression, crossing-vreg force, PC-locality, boundary PC. Mac test-all green. | `1f470ce3` |
| B123 | arm64 op_scratch_reservation_table — `src/engine/codegen/arm64/abi.zig` declares the comptime `[zir_op_count][]const u16` table with bulk-handler reservation {0..4} populated for table.fill/copy/init + memory.init. Exposes `opScratchReservation(op)` as a `ScratchReservationFn`-compatible accessor. Comptime allocatable-range check; 5 unit tests including shape-assignment to shared regalloc's type. NO wire to compile.zig yet (B125). | `d90b22ce` |
| B124 | `validateRegallocOpScratchReservation` shared validator at `shared/regalloc.zig`. arm64/abi.zig replaces inline comptime check with delegated call. Asserts: every reserved slot id < force_spill_threshold, no duplicates within an op's set. 3 happy-path comptime tests. Future x86_64 mirror reuses without duplication. | `bd13e546` |
| B125 | **Load-bearing wire**. compile.zig comptime arch dispatch supplies `&arm64.abi.opScratchReservation` (x86_64 stays null). VerifyError gains `OpScratchOverlap`; `verifyWith` extension keeps `verify`'s back-compat signature stable. test-all green ⟹ no regressions from fence activation. | `cb008ad4` |
| B126 | Sweep 5 D-133 bulk handlers — op_table.zig (emitTableFill/Copy/Init, 44 sites) + op_memory.zig (emitMemoryInit, 11 sites) substitute magic numerals 9..13 with named `sxN` constants referencing `abi.allocatable_caller_saved_scratch_gprs`. `check_invariant_comments.sh` count 55 → 0. No functional change (regalloc fence already guarantees safety since B125). | `1d6e4680` |
| B127 | Boundary fixtures — 4 new fixtures under `test/edge_cases/p9/regalloc/` (one per bulk op). Each pushes V0=42 before the op so V0 strictly crosses; without fence V0 → X9 clobber; with fence returns 42. Edge-case runner: 51 → 55 passed. | `9e63c713` |
| B128 | Strict gate flip — `gate_commit.sh` invokes `check_invariant_comments.sh --strict` between the libc/fallback info checks and `zig build test`. New D-132/D-133-class digit literals now fail pre-commit. | `d8fe353b` |
| B129 | §9.12-C close — D-133 row deleted from `debt.md`; §9.12-C `[ ]` → `[x]` in ROADMAP. ADR-0077 8-step plan complete; the regalloc op-internal scratch fence is fully implemented (substrate + reservation table + validator + production wire + handler sweep + boundary fixtures + strict gate). | `9558e5f7` |
| B130 | §9.12-D first migration — `std.c.munmap` → `std.posix.munmap` in `src/platform/jit_mem.zig` (clean win). Harden `check_libc_boundary.sh` to exclude `.zig-cache/` / `zig-out/` (4 unclassified false positives → 0). File D-151 naming the 6-site Zig 0.16 stdlib gap that blocks §9.12-D's literal exit. | `823f4ad8` |
| B131 | ADR-0070 amendment — reclassify `_exit` / `fork` / `waitpid` / `alarm` from Replaceable → Necessary (empirical: Zig 0.16 std.posix lacks all four; std.process.exit not async-signal-safe). Script's NECESSARY/REPLACEABLE_SYMS arrays updated to match. D-151 deleted (barrier dissolved). Replaceable count 8 → 3. | `8dfe9018` |
| B132 | §9.12-D CLOSE — migrate `std.c.pid_t` → `std.posix.pid_t` + `std.c.kill` → `std.posix.kill catch {}` (EXEMPT-FALLBACK in SIGALRM handler). ADR-0070 §B132 amendment reclassifies `std.c.getenv` Replaceable → Necessary (c_api context: no `std.process.Init` available so `Environ.getPosix` is structurally unavailable). Replaceable count 3 → 0. `check_libc_boundary --gate` returns 0; §9.12-D `[ ]` → `[x]`. | `b098a688` |
| B133 | §9.12-E first chunk — SIMD lane-index validator range check (Wasm SIMD §3.3.6.X). New `Error.InvalidLaneIndex` + `readLaneIdx` helper; 4 handlers (extract_lane / replace_lane / load_lane / store_lane) take a `lane_count` parameter; 20 call sites in `dispatchPrefixFD` pass concrete counts per shape. Discharges lane-index portion of SKIP-VALIDATOR-GAP SIMD (50 total). | `c32f6b0d` |
| B134 | §9.12-E SIMD alignment-immediate validator check (Wasm §3.3.7). `Error.InvalidSimdAlignment` + `readSimdMemarg(max_align_log2)` helper. New per-shape `opSimdLoad` / `opSimdStore` handlers (replace generic `opLoad(.v128)` / `opStore(.v128)` routing). load_lane/store_lane handlers also take `max_align_log2`. 22 dispatch arms updated with concrete max_align per shape. Together with B133 closes SKIP-VALIDATOR-GAP SIMD lane-index + align halves. | `004f29e7` |
| B135 | §9.12-E SIMD discharge measurement. `simd_assert_runner: 13351 passed, 0 failed, 0 skip-impl + 390 skip-adr` — SIMD axis now spec-complete. skip_impl_history.yaml entry added (243 → 193, delta -50). Ratchet baseline advances. | `b6b44ae8` |
| B136 | §9.12-E action-dispatcher prep — new `src/engine/export_lookup.zig` module with `findExportGlobal` helper (mirror of `runner.findExportFunc`). Lands in new file because `runner.zig` was at 1999 of 2000 LOC hard cap. Building block for closing the `exports/manifest.txt` `skip-impl non-invoke-action` site. | `73de3701` |
| B137 | §9.12-E `get-action` manifest format + base runner support. Base runner: DirectiveKind.get_action + parseLine + nullable handle_get_action callback + SKIP-NON-INVOKE-ACTION fallback. regen_spec_2_0_assert.sh emits `get-action <field> <type> <value>` for same-module non-invoke actions. exports manifest regenerated. Non-SIMD callback stays null pending D-152 (compileWasm empty-fn-path globals_offsets fix). Net: skip-impl 193 → 192. | `2184e6df` |
| B138 | §9.12-E D-152 discharge — compileWasm empty-fn-path now populates globals_offsets via new `engine/export_lookup.zig::computeGlobalsLayout` helper (runner.zig under 2000-LOC cap). `nonSimdHandleGetAction` callback re-added: parses body, findExportGlobal + scratch_globals offset read, compares vs expected for i32/i64/f32/f64. Net: passed 25325 → 25326, skip-adr 496 → 495 (genuine PASS for exports.wast `(get "e") = i32.const 42`). | `67e28950` |
| B139 | §9.12-E SKIP-NO-LINK-TYPECHECK scope survey. 26 sites: imports/manifest.txt lines 18-40 (24 sites; imports.12-35, imports.40-59) + linking/manifest.txt lines 3-4 (2 sites). All are function-signature mismatches at instantiation-time. Current runner falls through to Path 3 (compileWasm succeeds, no type-check) → SKIP. Plan: extend `applyAssertUnlinkable` callback to extract each `RegisteredExporter`'s exported types + compare against import declarations via the existing `src/runtime/instance/instantiate.zig::checkImportTypeMatches` pattern. Est. 150-250 LOC in test runner only (no Zone 1/2 changes). Splits into 3 sub-chunks: (a) export-type extraction helper, (b) import-vs-export comparison loop, (c) wiring + manifest re-classification. | `f279f681` |
| B140 | §9.12-E B139 Part (a) — `getExportFuncType` helper in `engine/export_lookup.zig`. Looks up an exported func by name, resolves its `FuncType` via the type section. Handles both defined and imported funcs in the func index space. Caller-owned param/result slices. Unit test covers happy path. | `4a1ada3c` |
| B141 | §9.12-E B139 Part (b) — `hasIncompatibleImportType` helper in `spec_assert_runner_base.zig` + Path 3a wire in assert_unlinkable dispatch. For each func import: importer's expected FuncType vs registered exporter's actual FuncType (via getExportFuncType); any mismatch → PASS. Net: `25326 → 25348 passed` (+22 genuine PASS), skip-adr 496 → 473. skip-impl stays at 192 (ADR-0050 ratchet honored). | `b6861452` |
| B142 | §9.12-E B139 Part (c) — spectest kind-mismatch arm. Func imports targeting `spectest.{global_i32,global_i64,global_f32,global_f64,table,memory}` or literal `spectest.unknown` → PASS. Closes the residual 4 SKIP-NO-LINK-TYPECHECK sites (imports.13/33/34/35). Net: 25348 → 25352 passed (+4), skip-adr 473 → 469. SKIP-NO-LINK-TYPECHECK fully discharged on wasm-2.0 corpus. | `c93b9ea7` |
| B143 | §9.12-E SKIP-CROSS-MODULE-IMPORTS scope survey. ~100 sites across 8 manifests: imports (40-50), linking (30-40), table_* / elem (35-40), memory_grow / data (10-15), globals (10-15), ref_func (3-5). ADR-0066 bridge thunks already implemented (cross-module func calls work in JIT). Plan: 4 chunks — A (func dispatch + link-typecheck, ~25), B (global R/W, ~15), C (table get/set/init/copy, ~35-40), D (memory load/store/grow, ~15-20). Survey at private/notes/p9_12-E-B143-cross-module-imports-survey.md. | `9e49616a` |
| B144 | §9.12-E Chunk A scope re-verification. **Discovery**: 0 manifest `skip-impl` lines in wasm-2.0-assert/ — all 100 SKIP-CROSS-MODULE-IMPORTS sites are RUNTIME emissions from `hasUnbindableImports` returning true in the `.module` dispatch arm. Path #1 (func from non-spectest non-registered) is correctly handled. Path #2 (`.table/.memory/.global => return true` unconditional) is the gap: most 100 SKIPs are `(import "spectest" "global_i32" (global i32))` shapes. | `1d5f65ac` |
| B145 | §9.12-E B143/144 distribution measured: imports=38, elem=19, data=18, linking=16, table_grow=2, global=2, table=1, memory_grow=1. D-153 filed with architectural discharge plan (~400-600 LOC across spec_assert_runner_base.zig + new spectest_catalog module; ADR-grade per ADR-0065 §A4 / ADR-0066 / ADR-0071 §Q5). | `c3359c29` |
| B146 | §9.12-E Chunk B Part 1 — new `test/spec/spectest_catalog.zig` (D-153 Part 1). Static `non_func_exports` array enumerating global_i32/i64/f32/f64 + table(10,20) + memory(1,2) per the reference interpreter's spectest.ml. `findNonFuncExport(name)` lookup helper + 3 unit tests. No behaviour change; subsequent chunks consume the catalog. | `e17b31b5` |
| B147 | §9.12-E Chunk B Part 2 — `isSpectestNonFuncBindable(imp) bool` predicate in `spec_assert_runner_base.zig`. Consults catalog; returns true iff module=spectest + name in catalog + kind matches + (for globals) valtype matches. `hasUnbindableImports` NOT yet changed; predicate sits ready for B148 wire-up. | `06a3c17f` |
| B148 | §9.12-E Chunk B Part 3 — 5 unit tests for `isSpectestNonFuncBindable` (true/false for various module/name/kind/valtype combinations). Test-only commit. Deferred actual `hasUnbindableImports` flip: the JIT's `globals_offsets` is keyed by DEFINED global idx only; imported globals need their own indirection (architectural piece in D-153). | `ae528aac` |
| B149 | §9.12-E Chunk B Part 4 — JIT imported-globals storage architecture survey. Findings: (a) `globals_offsets` in runner.zig:747 is sized by defined-global count only; (b) op_globals.zig:lookupGlobalShape falls back to `idx*8` for imported globals which has no backing storage. **Option A recommended**: extend globals_offsets to `(num_imports + num_defined)` size, pre-populate import slots from spectest catalog at instantiation. Zero JIT hot-path cost; mirrors ADR-0066's pointer-pre-population pattern. Est. 150-200 LOC across runner.zig + spec_assert_runner_base.zig. Survey at private/notes/p9_12-E-B149-jit-imported-globals-survey.md. | `4c101340` |
| B150 | §9.12-E Chunk B Part 5 — `CompiledWasm.num_global_imports: u32` field added + populated by both empty-fn and non-empty-fn paths. Pure data exposure step; `globals_offsets` still keys by defined idx. | `e7af5546` |
| B151 | §9.12-E Chunk B Part 6 — cascade discovery (docs-only). | `8ad3ebf8` |
| B152 | §9.12-E Chunk B Part 7 — `applyDefinedGlobalsInit` + `resolveFuncrefGlobals` signatures take `num_global_imports: u32`. Internal indexing shifts to `[num_global_imports + gi]`; length assertion + early-exit updated. All 6 call sites pass `compiled.num_global_imports`. runner.zig at exactly 2000 LOC. | `218d7c10` |
| B153 | §9.12-E Chunk B Part 8 — `computeGlobalsLayout` walks imports prefix; result indexed by FULL wasm global index space. Empty-fn path now returns `(num_imports + defined)`-sized arrays. | `9b8d9cdb` |
| B154 | §9.12-E Chunk B Part 9 — non-empty-fn path refactored to use `computeGlobalsLayout`. Both compileWasm paths now produce identical shape. runner.zig shrinks 2000 → 1982 LOC. Closes shape inconsistency from B153. Behaviour-preserving on current corpus. | `8747aa9b` |
| B155 | §9.12-E Chunk B Part 10 — `applySpectestGlobalImports` helper in `spec_assert_runner_base.zig`. Not yet wired. | `6b41abf5` |
| B156 | §9.12-E Chunk B Part 11 — flip attempt reverted on 6 regressions. | (revert) |
| B157 | §9.12-E Chunk B Part 12 — survey of B156's 6 regression sites. | `a2bb620a` |
| B158 | §9.12-E Chunk B Part 13 — `validator_globals` includes imports prefix. Walks imports section + prepends each global import's (valtype, mutable) before defined entries. Mirrors B153/B154's globals_offsets shape. Behaviour-preserving on current corpus. Unblocks B156's Errors 1+2 (InvalidGlobalIndex / StackTypeMismatch). runner.zig 1995 LOC. | `<this commit>` |
| **B159** | §9.12-E Chunk B Part 14 — investigate B156's Errors 3+4 (`elem/* table-init: UnsupportedEntrySignature` × 2 + `data/* data-init: UnsupportedEntrySignature` × 2). Likely a different shape: applyTableInit / applyActiveDataSegments may evaluate init-expr `global.get N` and need num_global_imports-aware lookup. Survey first; pick which to fix. | **NEXT** |

## Active state — §9.12-C CLOSED at B129 (ADR-0077 complete); §9.12-D NEXT

**§9.12-C [x] at B129**. The ADR-0077 op-internal scratch reservation
fence is fully implemented; D-133 discharged; strict gate active.
Loop advances to §9.12-D (Q6 libc dependency boundary).

### ADR-0077 8-step plan — COMPLETE

1. ~~**B122**: regalloc walker fence plumbing~~ — DONE.
2. ~~**B123**: arm64 per-arch reservation table~~ — DONE.
3. ~~**B124**: `validateRegallocOpScratchReservation`~~ — DONE.
4. ~~**B125**: load-bearing wire (fence active in production)~~ — DONE.
5. ~~**B126**: 5-handler sweep~~ — DONE (lint 55 → 0).
6. ~~**B127**: 4 boundary fixtures~~ — DONE (edge-case runner 51 → 55).
7. ~~**B128**: strict gate flip~~ — DONE.
8. ~~**B129**: D-133 close + §9.12-C [x]~~ — DONE.

### §9.12-E scope (next active row)

★ **Primary Phase 9 completion exit** (Wasm 2.0 100% — skip-impl
243 → 0 + 4 comprehensive test suites green) per
`archive/phase9/phase9_completion_master_plan.md` §5.3 + §2.2.

Major workstreams:

- SKIP-CROSS-MODULE-IMPORTS 100 (imports/elem/data/linking/
  table*/memory*/global) discharge via relaxed
  `hasUnbindableImports()` reject condition + per-shape resolver.
- SKIP-NO-LINK-TYPECHECK 26 via `Instance.checkImportType()` +
  `applyAssertUnlinkable` callback.
- SKIP-VALIDATOR-GAP SIMD 50 (simd_lane lane-index range +
  simd_align alignment immediate range).
- exports non-invoke-action 1 (action dispatcher `get`/`set`).
- D-079 v128 cross-module imports (ii) via ADR-0052 §3 globals
  extension.

Exit predicate: `spec_assert_runner_non_simd: 0 failed,
0 skip-impl`; `simd_assert_runner: 0 failed, 0 skip-impl`;
Mac+ubuntunote bit-identical; ratchet 0 maintained.

This is genuine multi-chunk feature work likely to span many
B-sequence iterations. Some sub-tasks (e.g. cross-module
binding shapes) may need ADR-grade design touchpoints.

### Spike validation summary (B121)

- 7-test self-contained Zig harness at
  `private/spikes/regalloc-live-fence/fence.zig` validates LIFO
  pool integration, strict-strict PC shape, and verifier
  post-condition. ADR-0077 needs no amendment.
- Findings captured at
  [`.dev/lessons/2026-05-20-regalloc-fence-design-validation.md`](lessons/2026-05-20-regalloc-fence-design-validation.md).

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

PRIMARY: [`archive/phase9/phase9_completion_master_plan.md`](../archive/phase9/phase9_completion_master_plan.md).
Substrate audit doc: [`phase9_completion_substrate_audit.md`](../archive/phase9/phase9_completion_substrate_audit.md)
(§Decisions filled at §9.12 collab close).
Accepted ADRs: [`0070`](decisions/0070_libc_dependency_policy.md) /
[`0071`](decisions/0071_phase9_substrate_audit_resolution.md) /
[`0072`](decisions/0072_comment_as_invariant_rule.md) /
[`0073`](decisions/0073_build_option_dce_substrate.md) /
[`0074`](decisions/0074_per_op_file_zone_split.md);
Proposed (active, B53 will flip): [`0075`](decisions/0075_x86_64_emitctx_ctx_passing_unification.md);
amends [`0023`](decisions/0023_src_directory_structure_normalization.md) §4.5
+ [`0050`](decisions/0050_adr_lifecycle_and_skip_adr_enforcement.md) D-5/D-6.
Enforcement: ~~`scripts/p9_completion_status.sh`~~ (deleted 2026-05-22 per ADR-0104; replaced by `scripts/check_phase9_close_invariants.sh` per `.dev/phase9_close_master.md` §4 Phase C)
+ [`gate_consolidation_study.md`](gate_consolidation_study.md).
Bootstrap framework: [`src/ir/dispatch_collector.zig`](../src/ir/dispatch_collector.zig)
