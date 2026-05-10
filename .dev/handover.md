# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.7 row — Phase 9 active.
3. `.dev/debt.md` — D-055 / D-057 + 10 `blocked-by:` rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: simd ops, x86_64 SSE/SSE4.1/SSE4.2, ADR-0041 §5).
5. `.dev/decisions/0041_simd_128_design.md` (SSE4.2 baseline post-9.7-m
   amendment).

## Current state — Phase 9 / §9.9 in-flight; **9.9-d-4 NEXT — investigate `(i32)→v128` runtime miscompile + close residual ARM64 emit gaps**

9.9-d-3 (`a4a1b032`): bundle 12 ARM64 v128 mem ops sharing
`v128MemPrologue`. 4 new LD1R encoders in `inst_neon.zig`
(verified via clang-as). Shared scaffolding helper
`emitV128LoadFamily(ctx, ins, access_size, emit_tail)` in
`op_simd.zig`. Tail shapes: load_zero → LDR S/D; load_splat
→ ADD X16,X28,X16 + LD1R; load_extend → LDR D + SXTL/UXTL.
Compile-stage UnsupportedOp count 14 → 3.

**Mac aarch64 simd_assert_runner totals after 9.9-d-3**:
62 PASS / 200 FAIL / 296 SKIP. Residual:
- 3 compile UnsupportedOp — select_v128 (simd_select.0) +
  v128.load_lane / v128.store_lane (8 ops).
- 26 simd_address runtime mismatches: `(i32)→v128` returns
  bytes that look like a `[]const u32` slice header with
  `len=12` matching `simd_address.0.wasm`'s func count,
  hinting X28 is being routed to func_offsets metadata
  rather than vm_base under this calling shape. Either a
  runner-side data-segment gap (runner doesn't call
  setupRuntime — only memset's scratch_memory) OR a
  JIT-prologue routing issue. Needs spike investigation.
- ~158 simd_const value-mismatches — FP NaN canonicalization
  / specific lane encodings (deferred to 9.9-d-N FP-cluster).
- 1 BadBlockType / 1 BadValType / 1 NotImplemented — small
  validator surfaces.

**Next — 9.9-d-4**: spike on the `(i32)→v128` runtime issue
first (cheap to discriminate runner-side vs JIT-side: write a
minimal i32-arg test against the existing v128 entry helper +
print rt.vm_base before/after the call). Then either fix the
runner (apply data segments via setupRuntime) or fix the JIT
(if X28 routing under this shape is broken).

After 9.9-d-4 spike: bundle select_v128 + load_lane + store_lane
(9 ops in one chunk; all small). After that, 9.9-d-5 attacks
the simd_const FP cluster.

Subsequent §9.9 chunks per ADR-0045:
- 9.9-e: v128 PARAM marshal per ADR-0046 (unblocks multi-arg
  spec assertions like simd_select).
- 9.9-f: scale to FP arith + compares (heavy 9k+ files).
- 9.9-g: aggregate `test-spec-simd` into `test-all`; flip §9.9 [x].

After §9.9: §9.10 (smoke benches + gap analysis), §9.11
(audit + SHA backfill), §9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-055** (x86_64 prologue inject) — blocked-by D-052 prologue
  extract.
- **D-057** (op_simd.zig hard-cap, now ~4070 LOC) — blocked-by
  ADR for source-split landing. Discharge requires ADR mirror
  of ADR-0030; deferred until §9.7 row close.
- 10 `blocked-by:` rows: D-007/D-010/D-016/D-018/D-020/D-021/
  D-022/D-026/D-028/D-052 — barriers all hold this resume.

Closed Phase 8b artefacts (preserved for Phase 12 + Phase 15)
live in git: ADRs 0035-0040, lessons in `.dev/lessons/INDEX.md`,
code in `src/ir/coalesce/`, regalloc.zig LIFO free-pool,
`src/engine/codegen/aot/`. `git log` is authoritative.

**Phase**: Phase 9 (SIMD-128, ADR-0041 — SSE4.2 baseline).
§9.5 [x] (ARM64 NEON pt 1), §9.6 [x] (ARM64 NEON pt 2),
§9.7 [x] (x86_64 SSE4.1+SSE4.2; 9.7-a..bb landed),
§9.8 [x] (scope absorbed per ADR-0044),
§9.9 in-flight (9.9-a..c + 9.9-d-1..3 landed; 9.9-d-4 NEXT —
spike (i32)→v128 runtime miscompile, then close residual emit gaps).
**Branch**: `zwasm-from-scratch`。
