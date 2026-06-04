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

**§15.4 DONE** (D-246 coverage `1029e5b4` + perf ports measured→folded `ADR-0151`). The regalloc/SIMD perf axis is
now fully assessed (§15.2+§15.3+§15.4 all measured → v2 already competitive); W45 loop-persistence (v1's 78x→10x
lever) carried to §15.P as a loop-isolated measurement.
**NEXT = §15.5 D-245 win64 host→JIT trampoline** (first open `[ ]`). The cross-phase blocker re-scoped past at
§13.P/§14.P (ADR-0144/0145). The host→JIT `@call` seam (`entry.zig invokeAndCheck*`) doesn't preserve the win64
callee-saved set (RBX/RBP/RDI/RSI/R12–R15 + XMM6–15) → `zwasm-spec-simd` exit-3 crash on windows (seed-flaky in
Debug). Build an asm trampoline saving/restoring that set around the seam (return-value + arg'd + win64 variants);
template = arm64 `8eca59e3` / x86_64-SysV `de576a76`. **HARD/REMOTE — best as a deliberate session**: needs
windowsmini (remote Windows SSH) to verify `test-all` deterministic-green; lesson `win64-jit-trampoline-arg-marshal`
+ rule `abi_callee_saved_pinning`. Step 0: survey the seam + the two template commits + D-245 debt. After §15.5:
§15.6 ClojureWasm CI → §15.P parity-vs-v1 close.

## Step 0.7 (next resume)

This turn: **§15.4 CLOSED** — measured the v1 SIMD perf ports (W43 addr-cache / W44 reg-class / W45 loop-persist)
→ all fold to §15.P (ADR-0151): v2 already 0.5–0.8× the comparator median per-op; W44 done (D-036); W45 deferred
to a §15.P loop-isolated measurement. §15.4 `[x]`. Measurement was throwaway/reverted. **DOCS/scope only — NO
src/ change → no ubuntu kick** (code HEAD `aaa267ee`, ubuntu-verified OK). **NOTE** (lesson
`gate-tail-vs-exit-code`): benign `failed command: …--listen=-` / SlotOverflow / `arm64/emit: failing op` next to
a passing run = error-path test noise — EXIT code authoritative.

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
