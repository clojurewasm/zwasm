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

**§15.4 — SIMD perf ports (measure-first); D-246 coverage DONE** (first open `[ ]`; §15.2+§15.3 folded).
✅ **D-246 RESOLVED** (`078ffde5`→`1029e5b4`): arm64 JIT SIMD emit now at full coverage parity with x86_64 — 26
ops closed (dot + 12 extmul + 8 sat-arith + q15mulr + 4 extadd_pairwise), all clang-verified NEON encoders + the
missing `lower_simd` arms (the ops were dead on BOTH arches) + JIT execution fixtures. Debt discharged.
**NEXT = SIMD perf ports** (v1 W43 SIMD-addr-cache / W44 reg-class / W45 SIMD-loop-persistence + W54-class hoist;
Phase-11 gap candidates AVX/CPUID + MOVAPS peephole). **MEASURE-FIRST** (perf-roi lesson + §15.2/§15.3 pattern):
the §11.3 profile (`bench/results/simd_gap_profile_p11_3.md`) already found SIMD competitive (0/12 ops lag >3×) →
headroom likely THIN; probe each port's headroom before building, fold to §15.P aggregate if <gap. Step 0: read
the v1 W43/44/45 sources (read-only v1 clone) + re-profile SIMD bench (steady-state, ≥10× iters — the `--quick`
micro-benches are startup-confounded). After §15.4: **§15.5 D-245 win64** (hard/remote) → §15.6 ClojureWasm →
§15.P parity.

## Step 0.7 (next resume)

This turn: **§15.4/D-246 RESIDUAL DONE → D-246 RESOLVED** — `d4ef48df` 13 encoders + `1029e5b4` 13 ops
(sat-arith/q15mulr/extadd_pairwise; lowering arms + helpers + fixtures); D-246 debt discharged. `zig build
test`/lint/zone green, edge-cases 75/0, x86_64 cross-compile OK. **CODE changed → ubuntu kick
QUEUED** (scope `test`); Step 0.7 next resume verifies (`tail -3 /tmp/ubuntu.log`) — red → revert to `036fc791`.
**NOTE** (lesson `gate-tail-vs-exit-code`): benign `failed command: …--listen=-` / SlotOverflow / `arm64/emit:
failing op` next to a passing run = error-path test noise — EXIT code authoritative.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile = `zig build test
-Dtarget=x86_64-windows-gnu`. windowsmini exec = `run_remote_windows.sh` (phase boundary).

## Deferred / open debt

- **D-258** (NOW) JIT-trampoline GC collect trigger (interp reclaims; JIT alloc path doesn't trigger
  yet — separate `*JitRuntime` root model). **D-211** (blocked-by) precise GcRootMap walker (moving/AOT).
  **D-257** (partial) 10 lesson `Citing` markers. **D-245** win64 host→JIT = §15.5. **D-259** (note)
  spillBytes footprint. **D-255** C-API WASI io (ADR-0143). **D-254** rust 3-OS. **D-253** §13.2 host_info.
  **D-251** WASI in AOT. **D-249** win bench timing. **D-238** x86_64 EH thunk. D-210/234/237/229/231/204/209/213.

## Key refs

- ROADMAP §15 task table (15.1 DONE → 15.2 coalescer → … 15.5 D-245 … 15.6 ClojureWasm). Phase Status
  widget (14 DONE / 15 IN-PROGRESS). ADR-0146/0147/0148 (§15.1 GC); ADR-0128 §2 (non-moving conservative
  rooting); ADR-0036/0037/0038/0040 (coalescer + class-aware substrate); ADR-0135 (GC re-sequence).
