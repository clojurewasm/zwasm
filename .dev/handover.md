# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 15 (Performance parity with v1 + ClojureWasm) IN-PROGRESS.** Phase 14 (CI) / 13 (C API) /
  12 (AOT) DONE.
- **§15.1 GC reclamation + conservative rooting — DONE** (`be4357be`; ADR-0146/0147/0148). The
  mark-sweep collector now collects under heap pressure + FREES/REUSES dead memory:
  - chunk 1a `5de51a69` `stack_limit.nativeStackHigh()`; 1b `b46960db` object-start-validated
    conservative native-stack scan (`scanNativeStackRoots`, `scan_native_stack` flag); 1c `55503da7`
    (ADR-0146) heap-pressure collection trigger (`root_scope.maybeCollect`, wired into interp
    `allocateStruct`/`allocateArray`); 2 `32aaec94` + exit `be4357be` (ADR-0147) external free-list
    reuse → alloc-loop cursor BOUNDED.
  - **Re-scoped at close (ADR-0148 carve-out)**: precise `zir.GcRootMap` stack-map walker + §12.5
    AOT GC-root serialization are NOT needed for a non-moving collector (ADR-0128 §2) → deferred to
    **D-211** (barrier: moving collector OR AOT GC-root serialization). JIT-trampoline collection
    trigger (separate `*JitRuntime` root model) = **D-258**.
- **§15.2 + §15.3 (regalloc-axis perf) — both measured ~0 headroom → CLOSED `[x]`/folded** (ADR-0149/0150).
  §15.2: GPR-spill traffic 2.7–5.6% of instrs → ≥5% unreachable. §15.3: **FP-spill = 0%** (nbody/matrix never
  overflow the 13 V-regs; resolution already class-aware per D-036) → ≥3% unreachable; dual-pool not built;
  `spillBytes()` footprint cleanup = **D-259**. **Pattern: v2's deterministic-slot emit is already efficient
  (low/zero spill) — regalloc-axis optimizations have no headroom. This = v2 likely near v1 parity.** §15.P
  reframed to parity-vs-v1 (not fixed ≥10%). Remaining perf lever = §15.4 (SIMD/compute axis + D-246 emit hole).

## Next task (autonomous)

**§15.4 — D-246 arm64 dot/extmul emit hole** (first open `[ ]`; §15.2+§15.3 folded; user picked ROADMAP-order
continue). CORRECTNESS gap (NOT bench-gated — build regardless). Survey DONE — full recipe:
- **13 missing ops** (arm64 → `UnsupportedOp` at `emit.zig:1771-1783`; x86_64 HAS them): `i32x4.dot_i16x8_s` +
  `{i16x8,i32x4,i64x2}.extmul_{low,high}_*_{s,u}` (12).
- **Emit infra**: `op_simd.emitV128Binop(ctx, encoder)` (pops 2 vregs→Q, calls `encoder(rd,rn,rm)`, stores) —
  use for the 12 extmul (each 1 instr). `dot` needs a custom emit (3 instrs into 1 result w/ 2 scratch Q regs).
  Pattern: new per-op files `arm64/ops/wasm_2_0/<op>.zig` (mirror an existing one) delegating to a helper in
  `op_simd_int_arith.zig`; dispatch auto-registers once `pub fn emit` exists.
- **NEON encoders to ADD** to `inst_neon_arith.zig` (mirror `encMul8H`=`0x4E609C00|rm<<16|rn<<5|rd`). DERIVED
  (VERIFY via spec test — encoding error=miscompile): three-different SMULL/UMULL base `0x0E20C000`; +U(unsigned)
  `|0x20000000`; +Q(high=SMULL2/UMULL2) `|0x40000000`; size `<<22` (00=.8H from 8b, 01=.4S from 16b, 10=.2D from
  32b); `|rm<<16|rn<<5|rd`. ADDP.4S = `0x4EA0BC00|rm<<16|rn<<5|rd`.
- **dot recipe**: SMULL(.4S=.4H*.4H low)→t1, SMULL2(.4S high)→t2, ADDP.4S(rd,t1,t2). **extmul**: low=SMULL/UMULL,
  high=SMULL2/UMULL2, size per result width (i16x8←8b sz00, i32x4←16b sz01, i64x2←32b sz10).
- **Verify**: no spec `.wast` fixture found → CREATE a wat fixture (known in/out per op) + run JIT (currently
  `UnsupportedOp`) → green; cross-check ≥1 encoding vs a reference if possible. Cross-compile x86_64 (unaffected).
  **Chunk plan**: (A) encoders+tests, (B) extmul family (12, same recipe), (C) dot. After §15.4: **§15.5 D-245
  win64** (hard/remote) → §15.6 ClojureWasm → §15.P parity. (Not a phase boundary.) Perf ports W43/44/45 =
  measure-first per [[perf-roi]] lesson, after D-246.

## Step 0.7 (next resume)

This turn: user check-in → chose **ROADMAP-order continue**; recorded perf-measure-first lesson (`43ecd845`) +
memory (user guidance: perf ROI needs measurement, commit/revert liberally). §15.4 D-246 survey DONE (recipe +
derived NEON encodings captured in Next-task above — NEXT turn implements). **DOCS only — NO src/ change → no
ubuntu kick** (code HEAD `45a94348`, ubuntu-verified OK). **NOTE** (lesson `gate-tail-vs-exit-code`): benign
`failed command: …--listen=-` / `arm64/emit: failing op` next to a passing run = error-path noise — EXIT auth.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile = `zig build test
-Dtarget=x86_64-windows-gnu`. windowsmini exec = `run_remote_windows.sh` (phase boundary).

## Deferred / open debt

- **D-258** (NOW) JIT-trampoline GC collect trigger (interp reclaims; JIT alloc path doesn't trigger
  yet — separate `*JitRuntime` root model). **D-211** (blocked-by) precise GcRootMap walker (moving/AOT).
  **D-257** (partial) 10 lesson `Citing` markers. **D-245** win64 host→JIT = §15.5. **D-246** arm64
  dot/extmul = §15.4. **D-255** C-API WASI io (ADR-0143). **D-254** rust 3-OS. **D-253** §13.2 host_info.
  **D-251** WASI in AOT. **D-249** win bench timing. **D-238** x86_64 EH thunk. D-210/234/237/229/231/204/209/213.

## Key refs

- ROADMAP §15 task table (15.1 DONE → 15.2 coalescer → … 15.5 D-245 … 15.6 ClojureWasm). Phase Status
  widget (14 DONE / 15 IN-PROGRESS). ADR-0146/0147/0148 (§15.1 GC); ADR-0128 §2 (non-moving conservative
  rooting); ADR-0036/0037/0038/0040 (coalescer + class-aware substrate); ADR-0135 (GC re-sequence).
