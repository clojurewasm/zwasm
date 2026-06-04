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
- **§15.4 SIMD coverage + perf ports — DONE** (D-246 `1029e5b4` + perf ports measured→folded ADR-0151). 26 ops
  closed both arches; v2 already 0.5–0.8× the comparator median (0/12 lag >3×). W45 loop-persistence → §15.P.
- **§15.5 D-245 win64 host→JIT trampoline — DONE** (`510ffce9`, clobber-trampoline). **test-all 3-host GREEN**:
  Mac + ubuntu x86_64 + windowsmini win64 (rc=0, no SEGV). D-260 x86_64 SIMD bugs (q15mulr/extadd) surfaced by the
  win64 run + FIXED `3a778080`, also 3-host green. Root fix D-210 NOT taken (per-seam patch; see structural risks).

## Next task (autonomous)

**NEXT = §15.6 ClojureWasm CI green** (first open `[ ]`). Point ClojureWasm's `zwasm` dep at a local `build.zig.zon`
`path = …` to `zwasm_from_scratch/` (NO ClojureWasm-side commits needed for v2-experimental validation). Repo is at
`~/Documents/MyProducts/ClojureWasmFromScratch` (read-only reference clone — do NOT edit/commit there; validate the
build against zwasm v2 LOCALLY first, e.g. a throwaway `private/spikes/` consumer or a local clone). Step 0: survey
its current `build.zig.zon` dep shape + how it invokes zwasm (CLI? C-API? AOT?). After §15.6: **§15.P parity-vs-v1
close** — the load-bearing un-done perf work (D-263): v2-vs-v1 bench (no unexplained regression) + the W45
loop-isolated measurement (≥50M-iter v128-local loop, baseline-subtracted, per ADR-0151) + widget 15 → DONE.

## Step 0.7 (next resume)

§15.5 CLOSED this turn: D-245 (`510ffce9`) + D-260 (`3a778080`) both **3-host test-all GREEN** (Mac + ubuntu
x86_64 + windowsmini win64 rc=0, no SEGV/FAIL). Next resume = **§15.6 ClojureWasm CI** — a fresh `[ ]`, no prior
ubuntu kick to verify against (§15.6 Step 0 is a local-build survey, not a code chunk). The §15.6 first code chunk
will kick ubuntu per normal. (`510ffce9`/`3a778080` already validated; do NOT revert.) **NOTE** (lesson
`gate-tail-vs-exit-code`): benign `failed command: …--listen=-` / SlotOverflow / `arm64/emit: failing op` next to
a passing run = error-path noise — EXIT authoritative. **D-262 process fix**: any NEW per-arch emit chunk → run
`run_remote_ubuntu test-all` (NOT narrow `test`) before discharge (cross-compile ≠ cross-run).

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile = `zig build test
-Dtarget=x86_64-windows-gnu`. windowsmini exec = `run_remote_windows.sh` (phase boundary).

## Deferred / open debt

- **STRUCTURAL RISKS (2026-06-04 retrospective, hub: lesson `session-retrospective-structural-risks`)** —
  the highest-stakes/most-orphan-prone: **D-261** (NOW, top stakes) GC-on-JIT conservative rooting has NO
  adversarial test → latent UAF (+ D-258). **D-262** (NOW) x86_64/win64 emit under-verified by the gate
  topology (cross-compile≠cross-run; D-260 symptom). **D-263** (NOW) "v2≈v1 parity" never measured vs v1 →
  hard §15.P gate. **D-210** (blocked-by) cohort root fix recurring at 4 seams (D-142/206/210/245) — decide
  root-vs-patch.
- **D-258** (NOW) JIT-trampoline GC collect trigger. **D-211** (blocked-by) precise GcRootMap (moving/AOT).
  **D-257** (partial) 10 lesson `Citing`. **D-259** (note) spillBytes footprint. **D-255** C-API WASI io.
  **D-254** rust 3-OS. **D-253** §13.2 host_info. **D-251** WASI in AOT. **D-249** win bench. **D-238** x86_64
  EH thunk. D-234/237/229/231/204/209/213.

## Key refs

- ROADMAP §15 task table (15.1 DONE → 15.2 coalescer → … 15.5 D-245 … 15.6 ClojureWasm). Phase Status
  widget (14 DONE / 15 IN-PROGRESS). ADR-0146/0147/0148 (§15.1 GC); ADR-0128 §2 (non-moving conservative
  rooting); ADR-0036/0037/0038/0040 (coalescer + class-aware substrate); ADR-0135 (GC re-sequence).
