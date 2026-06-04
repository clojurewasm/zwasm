# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active rework campaign

(ADR-0153 structural rework campaign — runs AUTONOMOUSLY; "hard gate" = self-enforced ordering, not a user stop.
Read [`REWORK.md`](../.claude/skills/continue/REWORK.md). Bundle mode nests inside a phase for continuity.)

- **Campaign-ID**: regalloc-resident-locals (D-265) — the single-pass baseline 完成形 (keep hot locals
  register-resident, as v1 does; within P3/P6, NOT an optimising tier). This IS the §15.P parity-achievement work.
- **Phase**: **III — design DONE → spike next** (of I→V). I DONE (`s15p_parity_vs_v1.md`). II DONE: 3
  loop-carried-local fixtures (`test/edge_cases/p9/regalloc/`: 55/30/84) 3-host green = the regression net;
  GcRef-in-register adversarial test deferred to D-258 (→ design constraint instead). III DONE: **ADR-0154
  Proposed** — value-reuse cache in liveness (`liveness.zig`) + reuse-metadata consumed by both emit backends;
  regalloc unchanged; invariants = set/tee/merge invalidate + GcRef never cached; exit = w45_addi 2.3×→≤1.1×.
- **Phase I result**: D-265 = v2-jit ~2.3× slower than v1 when a loop body reads a loop-carried local (A/B:
  `a=a+i` 2.30× vs `a=a+CONST` 0.96×; not memory/ALU — confounded earlier). MECHANISM (`emit.zig:910-968`): every
  `local.get` = `next_vreg++` + `LDR [SP,#local_off]`; no residency cache. ROI ceiling = v1 parity (known
  achievable). Blast-radius = ZIR-lowering + `ir/liveness.zig` + `shared/regalloc.zig` + arm64+x86_64 emit
  (`alloc.slots` indexed by a pre-emit vreg stream → reuse must be modelled in the regalloc pass). W45 folded
  (v128 loop 2× faster). Repro: `private/spikes/s15p-parity/`.
- **ROI target**: w45_addi 2.3× → ≤1.1× vs v1; full test net + the Phase-II adversarial net green.
- **Correctness net** (test-only chunks; NO redesign code until green): ✅ stale-register-after-`local.set` +
  loop-carried-local + multi-local-pressure (the 3 landed fixtures). **GcRef-in-register-at-collection (D-261)**:
  the JIT path can't trigger GC yet (D-258 open; conservative scan = native stack only, not JIT regs) → the JIT
  adversarial test is **D-258-blocked**; it converts to a **Phase III DESIGN CONSTRAINT** (rework MUST keep
  GcRefs slot-resident across any potential collection point — register-residency for non-ref locals, ref-locals
  spill at collection sites), with the JIT adversarial test deferred to when D-258 lands.
- **NEXT — validation spike** (ADR-0154 §"Validation spike"; off-branch `private/spikes/regalloc-local-cache/`,
  spike_discipline): implement the liveness local-value-reuse cache + arm64 reuse-emit minimally; run the 3
  Phase-II fixtures (MUST stay green = correctness) + w45_addi (MUST approach v1 = ROI). Green+ROI → Phase IV
  on-branch migration (liveness plumbing → arm64 consume → x86_64 consume; net green EVERY commit; ubuntu
  test-all). Thin/broken → revise ADR-0154 before any on-branch code. Then V (ADR-0149/0150 Revision note).
  All autonomous per the philosophy.

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

**§15.6 ClojureWasm CI — ⏸ DEFERRED** (ADR-0152 → D-264, user-confirmed). `ClojureWasmFromScratch` is itself a
from-scratch v1 redesign IN PROGRESS (branch `cw-from-scratch`, v0.0.0, deps=zlinter only, no `zwasm` dep, no CI);
stable cw = v0.5.0 on `main`. Its zwasm-v2 consumer is cw's OWN future phase → nothing to validate today. v2
package-consumability already proven by `examples/zig_host/` (ADR-0109). Barrier (D-264) dissolves when cw-v1 lands
committed `@import("zwasm")` source.
**See `## Active rework campaign` above** (ADR-0153) — §15.P parity is MEASURED; the remaining §15.P work =
**achieve** parity via the D-265 regalloc-resident-locals campaign (Phase II next: build the correctness/adversarial
net incl. D-261 GC-rooting). Runs fully autonomously — decide every step per the philosophy, do NOT stop to ask.
§15.6 deferred (ADR-0152 → D-264); §15.5 + 3-host reconcile DONE.

## Step 0.7 (next resume)

D-265 campaign at **Phase III design DONE (ADR-0154 Proposed)** → next = the off-branch validation spike. Phase-II
fixtures VERIFIED on x86_64 JIT this prior cycle (`/tmp/ubuntu.log` green, 55/30/84). The spike is off-branch
(`private/spikes/`) → no on-branch code, no ubuntu kick until Phase IV on-branch migration. (`510ffce9`/`3a778080`
validated; do NOT revert.) **NOTE** (lesson
`gate-tail-vs-exit-code`): benign `failed command: …--listen=-` / SlotOverflow / `arm64/emit: failing op` next to
a passing run = error-path noise — EXIT authoritative. **D-262 process fix**: any NEW per-arch emit chunk → run
`run_remote_ubuntu test-all` (NOT narrow `test`) before discharge (cross-compile ≠ cross-run).

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile = `zig build test
-Dtarget=x86_64-windows-gnu`. windowsmini exec = `run_remote_windows.sh` (phase boundary).

## Deferred / open debt

- **STRUCTURAL RISKS (2026-06-04 retrospective, hub: lesson `session-retrospective-structural-risks`)** —
  the highest-stakes/most-orphan-prone: **D-261** (NOW, top stakes) GC-on-JIT conservative rooting has NO
  adversarial test → latent UAF (+ D-258). **D-262** (NOW) x86_64/win64 emit under-verified by the gate
  topology (cross-compile≠cross-run; D-260 symptom). **D-263** (NOW) parity-vs-v1 — MEASURED at §15.P
  (`bench/results/s15p_parity_vs_v1.md`); surfaced **D-265**. **D-210** (blocked-by) cohort root fix recurring at
  4 seams (D-142/206/210/245) — decide root-vs-patch.
- **D-265** (NOW, §15.P bundle) v2-jit ~2.3× slower when a loop body reads a loop-carried local (regalloc
  spill; bisected; contradicts §15.2/15.3 folds) — confirm mechanism + measure fix. **D-258** (NOW)
  JIT-trampoline GC collect trigger. **D-211** (blocked-by) precise GcRootMap.
  **D-257** (partial) 10 lesson `Citing`. **D-259** (note) spillBytes footprint. **D-255** C-API WASI io.
  **D-254** rust 3-OS. **D-253** §13.2 host_info. **D-251** WASI in AOT. **D-249** win bench. **D-238** x86_64
  EH thunk. D-234/237/229/231/204/209/213.

## Key refs

- ROADMAP §15 task table (15.1 DONE → 15.2 coalescer → … 15.5 D-245 … 15.6 ClojureWasm). Phase Status
  widget (14 DONE / 15 IN-PROGRESS). ADR-0146/0147/0148 (§15.1 GC); ADR-0128 §2 (non-moving conservative
  rooting); ADR-0036/0037/0038/0040 (coalescer + class-aware substrate); ADR-0135 (GC re-sequence).
