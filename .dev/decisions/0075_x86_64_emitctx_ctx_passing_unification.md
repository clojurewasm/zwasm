# 0075 — Mirror arm64's `(*EmitCtx, *const ZirInstr)` shape on x86_64 per-op handlers

- **Status**: Accepted
- **Date**: 2026-05-19
- **Author**: Shota Kudo
- **Tags**: phase9, substrate, dispatcher, zone2

## Context

§9.12-B drove per-op file migration for 374 of 581 ZirOp tags (arm64 348 / x86_64 314). The remaining ~207 ops on x86_64 cannot be migrated through the current per-arch dispatcher signature because the x86_64 Zone 2 wire signature is positional and varies per op:

- Baseline pure arith: `(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, op)` (7-arg)
- Memory / table / globals: + `bounds_fixups`, `func_idx`, `tableidx`, `globals_offsets`, `globals_valtypes` (10+ args)
- SIMD const-fixup ops (popcnt, fp truncsat zero variants, convert_low_u): + `simd_const_fixups`, `extra_consts` (9-arg)
- Const / load_store / call: + payload / extra access via `ins.payload` / `ins.extra` (varies)

arm64 has the right shape from §9.7 onward: every emit fn is `(ctx: *EmitCtx, ins: *const ZirInstr) Error!void`. All state — buf, alloc, pushed_vregs, next_vreg, spill_base_off, bounds_fixups, payload access, func/table indices — is reached through `ctx` or `ins`. That symmetry is what makes the per-op file pattern in arm64 a clean delegate (`pub fn emit(ctx, ins) { return op_X.emitY(ctx, ins); }`).

The §9.12-B substrate plan (ADR-0073 / ADR-0074) assumed both arches would converge to this shape. The arm64 side did; the x86_64 side never did because the early-phase code grew positional args ad-hoc as each new op class was added.

ROADMAP §4 (architecture / Zone / ZirOp), ROADMAP §11 (layers), and ADR-0074 (Zone 2 per-arch split) all hinge on the per-arch handler being a uniform `emit(ctx, ins)` interface. The current x86_64 divergence is the load-bearing barrier blocking §9.12-B exit.

## Decision

**Adopt the arm64 shape on x86_64**: every x86_64 per-op emit fn in `src/engine/codegen/x86_64/op_*.zig` migrates to the signature

```zig
pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void
```

All currently-positional dispatcher state (`allocator`, `buf`, `alloc`, `pushed_vregs`, `next_vreg`, `spill_base_off`, `bounds_fixups`, `simd_const_fixups`, `extra_consts`, `func_idx`, `globals_offsets`, `globals_valtypes`, …) moves into `x86_64/ctx.zig::EmitCtx` as explicit fields. Per-op handlers reach state via `ctx.*`; immediate operands via `ins.payload` / `ins.extra` / `ins.op`.

The per-op file Zone 2 wrapper collapses to:

```zig
pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_int.emitI32Add(ctx, ins);
}
```

identical in shape to the arm64 wrapper. The per-arch dispatcher signature in `src/engine/codegen/dispatch_collector.zig::ArchAxis = .x86_64` simplifies from the current 7-arg positional form to the 2-arg `(ctx, ins)` form.

## Alternatives considered

### Alternative A — Widen positional dispatcher signature ad-hoc

- **Sketch**: Keep x86_64's positional sig; add the missing args (`bounds_fixups`, `simd_const_fixups`, `extra_consts`, payload-access closure) to the dispatcher tuple. Per-op handler still discards what it doesn't need.
- **Why rejected**: Defers the cleanup; positional bloat grows further with each new op class (Wasm 3.0 GC + EH will add more positional args still). Doesn't fix the asymmetry with arm64. Quality < effort tradeoff — exactly what ROADMAP §2 / "labor over quality is forbidden" rules out.

### Alternative B — Per-op fn pointer table with heterogeneous signatures

- **Sketch**: Each per-op file declares its own `emit` with whatever signature it needs; dispatcher uses a comptime tagged-union or per-op fn pointer table to call them.
- **Why rejected**: Overengineering — comptime tagged-union dispatcher is harder to read / debug than uniform signature, and arm64 has already proven the uniform shape works. No technical benefit over Alternative C (this ADR's choice).

### Alternative C — Adopt arm64 shape on x86_64 (chosen)

See Decision above.

## Consequences

- **Positive**:
  - x86_64 and arm64 per-arch handlers become structurally identical (mirror per `ADR-0074 §A1`).
  - Per-op file Zone 2 wrapper is uniformly a one-line delegate on both arches.
  - Future Wasm 3.0 / GC / EH op classes need no dispatcher-signature changes — new positional args become EmitCtx fields, transparent to per-op files.
  - §9.12-B exit unblocks: the remaining ~207 ops all migrate through the same B30..B52-style cohort chunks once the EmitCtx extension lands.
  - §9.12-E (Wasm 2.0 literal 100%) becomes reachable — skip-impl discharge can be done by editing per-op files directly, not by surgery on the giant emit.zig switch.

- **Negative**:
  - EmitCtx struct grows substantially (~10 new fields). Manageable; this is exactly the role of EmitCtx ("Zone 2 architectural backbone" per ADR-0074 §A1).
  - One-time cascade migration of all existing x86_64 emit fns (~70+ fns currently positional). The fns themselves don't change behaviour, only their parameter list. Mechanical refactor.
  - Touches `src/engine/codegen/x86_64/emit.zig` heavily because every dispatch arm in the giant switch also needs the new call shape. That file is ~1968 lines and has WARN soft-cap status already.

- **Neutral / follow-ups**:
  - Inline-switch dispatcher cutover (originally §9.12-B's Q3 C target per ADR-0073) becomes a clean follow-up chunk after this ADR lands: replace the giant switch in `arm64/emit.zig` + `x86_64/emit.zig` with a comptime-generated dispatch over `collected_arm64_ops` / `collected_x86_64_ops`. Tracking debt: D-NEW-1.
  - **FILE-SIZE-EXEMPT extension — uniform-shape declaration catalogs** (2026-05-21 amendment, D-160). The original §9.12-B exemption wording (the marker precedent on `op_simd_int_cmp_lane.zig`) referenced "uniform `(ctx, ins)` adapter catalogs". The same structural property — homogeneous N-line declarations with no per-decl logic — also covers **pure-encoder catalogs** (`inst_neon_arith.zig` 114 NEON `encXxx` fns; `inst_sse_packed.zig` 96 SSE `encXxx` fns). Both file classes are exempt from the soft-cap split obligation under §9.12-B, since the WARN signal (reviewer eye-glaze risk) is already addressed by the structural homogeneity: any single encoder is a 5-line transliteration of the underlying ISA encoding table, and grouping by encoding family (NEON arith / SSE packed) is the canonical taxonomy. The exemption covers both `(ctx, ins)` adapter catalogs and pure-encoder catalogs; the unifying criterion is "uniform-shape declaration catalog without per-decl logic".
  - x86_64 `op_simd.zig` / `op_simd_int_cmp_lane.zig` SIMD const-fixup helpers (popcnt + 3 fp ops in the deferred list at B45) become migratable once `ctx.simd_const_fixups` / `ctx.extra_consts` fields exist.
  - arm64 deferred backlog (sat arith + extmul + extadd_pairwise + dot + q15mulr = 26 ops) is orthogonal — those need new arm64 NEON emit fns, not dispatcher changes. Tracked separately as `now` debt rows.

## Implementation plan (post-acceptance; B53..B6x sequence)

- **B53** — EmitCtx extension. Add `bounds_fixups`, `simd_const_fixups`, `extra_consts`, `func_idx`, `globals_offsets`, `globals_valtypes`, etc. as fields on `x86_64/ctx.zig::EmitCtx`. Initialise at the top of `x86_64/emit.zig::emitFunction`. No behaviour change. 2-host green expected.
- **B54** — PoC: migrate one op (recommend `i32.div_s` since it exercises `bounds_fixups`) end-to-end:
  - `op_alu_int.emitI32DivS(ctx, ins)` new signature.
  - x86_64 dispatch arm at the giant switch calls the new shape: `try op_alu_int.emitI32DivS(&ctx, &ins);`
  - Existing per-op file `x86_64/ops/wasm_1_0/i32_div_s.zig` (if exists; else create) delegates `return op_alu_int.emitI32DivS(ctx, ins);`.
  - Update `dispatch_collector.zig::collected_x86_64_ops` count + test.
  - 2-host green.
- **B55..B6x** — bulk migrate the remaining ~70 x86_64 emit fns in cohorts (5–15 ops/chunk per LOOP.md granularity). Same pattern as B11..B12 was for arm64 i32.add.
- **B6x+1** — inline-switch dispatcher cutover for both arches per ADR-0073. The giant switch in emit.zig is replaced by `inline for (collected_X_ops) |op_mod| { if (op_mod.op_tag == ins.op) return op_mod.emit(ctx, ins); }`. This is the moment per-op files become load-bearing.

## References

- ROADMAP §4 (architecture / Zone / ZirOp), §11 (layers)
- ADR-0023 §4.5 amend (per-op file pattern)
- ADR-0074 (Zone 2 per-arch split — this ADR refines §A1 invariant)
- ADR-0073 (build-option DCE substrate — inline-switch cutover sequencing)
- ROADMAP §9.12-B (Q3 C adoption — exit criterion served by this ADR)
- `src/engine/codegen/arm64/ctx.zig` — reference shape
- `src/engine/codegen/x86_64/ctx.zig` — target of extension

## Revision history

| Date       | SHA          | Note                                                            |
|------------|--------------|-----------------------------------------------------------------|
| 2026-05-19 | `4a6303d2`   | Initial proposed version (docs wire-up commit).                 |
| 2026-05-19 | `952e1a33` | Accepted at §9.12-B / B53 — EmitCtx struct + init landed.       |
| 2026-05-21 | `799b9b10` | Consequences amended — FILE-SIZE-EXEMPT extension to cover pure-encoder catalogs (D-160 discharge). |
