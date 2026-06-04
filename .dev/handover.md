# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active bundle

- **Bundle-ID**: 15.5-d245-win64-trampoline (host→JIT callee-saved preservation — correctness-critical ABI,
  W54-class, seed-flaky)
- **Cycles-remaining**: ~3–5 (survey → arg'd/i32/v128 SysV+arm64 variants → win64 variant → 3-host verify)
- **Continuity-memo**: **windowsmini IS REACHABLE** (`ssh windowsmini` rc=0 — so the win64 exit is achievable
  autonomously, NOT blocked). D-245 = host→JIT `@call` seam in `entry.zig` doesn't preserve host callee-saved
  regs → ReleaseSafe heap-corruption SEGV (Debug-safe). **DONE**: no-arg void path asm-saved (arm64 `8eca59e3`
  stp/ldp X19-X28; x86_64-SysV `de576a76` push/pop RBX/R12-R15) + ReleaseSafe gate (`0c42e913`). **REMAINING**:
  (a) **win64** host→JIT entry still `@call` — adapt the SysV asm-save to the win64 callee-saved set
  (RBX/RBP/RDI/RSI/R12-R15 + **XMM6-15**, the latter need 16B stack slots); verify windowsmini `test-all`
  deterministic-green (the §15.5 exit). (b) the **arg'd/i32/v128 `invokeAndCheck*` variants** (`entry.zig:162/172`
  generic + `:240` arg'd void) still `@call` — same asm-save fix, verifiable on Mac(arm64)+ubuntu(x86_64-SysV).
  Lesson `win64-jit-trampoline-arg-marshal` + rule `abi_callee_saved_pinning`.
- **PROGRESS**: survey + **DESIGN REFINED to a much simpler unified fix (this turn)** — drop the per-arg in-asm
  marshaling; use a **non-inline clobber-trampoline**. Two enabling insights: (1) `entry.zig:116-117` — **the JIT
  prologue ALREADY preserves win64 XMM6-15** (non-volatile), so NO manual XMM `movaps` is needed; only the GPR
  cohort the JIT clobbers (arm64 X19-X28; x86_64 RBX/R12-R15, **same for SysV AND win64** since the JIT regalloc
  pool is GPR-uniform). (2) A `@call(.never_inline, jitTrampoline, .{R,f,rt,args})` to a fn that does
  `r=@call(.auto,f,.{rt}++args); asm volatile("":::jit_cohort_clobbers); return r;` forces THAT fn's
  prologue/epilogue to save/restore the cohort (masking the JIT's clobber) — uniform across ALL arg counts/types +
  both x86_64 ABIs, no marshaling, no `callconv(.c)` (Zig default callconv passes the `args` tuple fine). The
  inline no-arg manual-asm path's "clobber over-constrains regalloc" objection (`:194`) does NOT apply — the
  constraint is local to the tiny trampoline, not the host. `invokeAndCheck` (`:162`, the RESULT path) is CURRENTLY
  FULLY UNFIXED (always plain `@call`) → net-additive, no regression risk. Plan: add `jit_cohort_clobbers` const
  (X19-X28 / RBX,R12-R15) + `jitTrampoline`/`jitTrampolineVoid`; route `invokeAndCheck` + `invokeAndCheckVoid`
  else-branch through them (keep the working no-arg manual asm; unify later if robust).
  **VERIFY (the open infra)**: need a ReleaseSafe ARG'D-JIT oracle — `check_jit_releasesafe.sh` only runs no-arg
  `_start`. Build it: a ReleaseSafe `ZWASM_SPEC_ENGINE=jit` spec-runner run OR extend `check_jit_releasesafe.sh`
  with a `--invoke <fn> <args>` arg'd export. RED = that probe crashes on current HEAD (arg'd @call), GREEN =
  trampoline fixes it. Then ubuntu `run_remote_ubuntu test-all` + windowsmini `run_remote_windows test-all` (the
  win64 EXIT). **NEXT (fresh context)**: build the ReleaseSafe arg'd oracle (RED) → implement the trampoline
  (GREEN) → 3-host verify.
- **Exit-condition**: all host→JIT invoke variants asm-save the host callee-saved set; ReleaseSafe gate green on
  Mac+ubuntu; windowsmini `test-all` deterministic-green (the win64 `@call` SEGV gone).

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

This turn: **§15.5 design REFINED** — found a much simpler unified fix (non-inline clobber-trampoline; win64
XMM6-15 already JIT-preserved; no per-arg asm marshaling) that de-risks the whole task; captured in the bundle.
NEXT = build a ReleaseSafe arg'd-JIT oracle (RED) → implement → verify. **DOCS/scope only — NO src/ change → no
ubuntu kick** (code HEAD `aaa267ee`, ubuntu-verified OK).
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
