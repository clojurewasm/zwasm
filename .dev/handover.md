# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active rework campaign

(ADR-0153 structural rework campaign — runs AUTONOMOUSLY; "hard gate" = self-enforced ordering, not a user stop.
Read [`REWORK.md`](../.claude/skills/continue/REWORK.md). Bundle mode nests inside a phase for continuity.)

- **Campaign-ID**: regalloc-resident-locals (D-265) — the single-pass baseline 完成形 (keep hot locals
  register-resident, as v1 does; within P3/P6, NOT an optimising tier). This IS the §15.P parity-achievement work.
- **Phase**: **III — design DONE → spike next** (of I→V). I DONE (`s15p_parity_vs_v1.md`). II DONE: 3
  loop-carried-local fixtures (`p9/regalloc/`: 55/30/84) 3-host green = the regression net. III: ADR-0154
  (Option A value-reuse cache) superseded by analysis (~17%, in-body only); **ADR-0155 (Option B) Proposed** —
  **register-homed locals, v1-style single-pass** (locals = mutable register-resident values, loaded once at
  prologue, resident across the back-edge, spilled only at calls/overflow/exit). The D-265 2.3× IS the per-iter
  loop-top reload (locals slot-homed, value crosses back-edge via memory). GcRef locals stay slot-homed for now
  (D-261/D-258; no regression). Re-opens W45 (ADR-0151 folded for v128; bites scalars).
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
- **NEXT — validation spike** (ADR-0155 §"Validation spike"; off-branch `private/spikes/register-homed-locals/`):
  implement **stage 1** (GPR locals register-homed for the no-call straight-line-loop case: regalloc reserves K
  GPR registers for the first K locals; prologue loads them; `local.get`/`set` become reg refs; slot-overflow for
  the rest). Run the 3 Phase-II fixtures (MUST stay green = correctness) + w45_addi (MUST hit ≤1.1× = ROI).
  Resolves the open design choice (local-register pre-reservation vs multi-def vreg). Green+ROI → land stage 1
  on-branch (Phase IV) → stages 2 calls / 3 FP-v128 / 4 x86_64, net green every commit, ubuntu test-all. All autonomous.

## Current state

- **Phase 15 (Performance parity with v1) IN-PROGRESS.** Phases 0-14 DONE. **§15.1** GC reclamation DONE
  (`be4357be`; ADR-0146/0147/0148; carve-outs → D-211/D-258). **§15.2/15.3** regalloc-axis perf — measured-folded
  (ADR-0149/0150) — but the "~0 headroom" claim is being REVISED (D-265: real headroom on loop-locals). **§15.4**
  SIMD coverage+ports DONE (D-246 `1029e5b4`; ADR-0151). **§15.5** D-245 win64 trampoline DONE (`510ffce9` +
  D-260 fix `3a778080`, test-all 3-host green). **§15.6** ClojureWasm CI ⏸ DEFERRED (ADR-0152 → D-264; cw is its
  own in-progress v1 redesign). **§15.P** parity MEASURED (`s15p_parity_vs_v1.md`) → the remaining work = the
  **D-265 rework campaign** (`## Active rework campaign` above). Runs fully autonomously per the philosophy.

## Step 0.7 (next resume)

D-265 campaign **Phase III design DONE (ADR-0155 Option B = register-homed locals)** → next = the off-branch
validation spike (stage 1: GPR locals register-homed, no-call case; Phase-II fixtures green + w45_addi ≤1.1×).
All docs-only since the fixtures → no on-branch code, no new ubuntu kick; Phase-II fixtures already x86_64-green
(`/tmp/ubuntu.log`, 55/30/84). (`510ffce9`/`3a778080` validated; do NOT revert.) **NOTE** (lesson
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
