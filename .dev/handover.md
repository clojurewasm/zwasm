# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active rework campaign

(ADR-0153 structural rework campaign — runs AUTONOMOUSLY; "hard gate" = self-enforced ordering, not a user stop.
Read [`REWORK.md`](../.claude/skills/continue/REWORK.md). Bundle mode nests inside a phase for continuity.)

- **Campaign-ID**: regalloc-resident-locals (D-265) — the single-pass baseline 完成形 (keep hot locals
  register-resident, as v1 does; within P3/P6, NOT an optimising tier). This IS the §15.P parity-achievement work.
- **Phase**: **IV — implementation. ✅ STAGES 1+2 (arm64) + 4 (x86_64) LANDED** — register-homing now on BOTH
  backends for declared i32/i64 locals (the D-265 fix). 1=`a64c72a1` (arm64 call-free, w45_addi **2.30×→0.97×**),
  2=`5d1dd221` (arm64 across-calls, caller-saved spill at op_call), 4=`f31affa1` (x86_64 port: op_locals reg→reg
  MOV + prologue seed + ctx wiring; gate dropped to aarch64|x86_64; ARCH-AWARE max_homed arm64=6/x86_64=2 to not
  starve temps; x86_64 allocatable GPRs all callee-saved → op_call spill is a no-op). SSOT `local_homing.plan`
  drives all passes both arches. arm64 byte-identical post-stage-4. **x86_64 RUN correctness = ubuntu (kicked)** —
  Mac only cross-compiles x86_64. Remaining gates: declared i32/i64 only; GcRef/fp/v128 slot-homed; GC-trampolines
  off (stage 2b). Net (3-host green): `homed_local_membase_loop` + `homed_local_across_call` + the 3 stage-1.
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
- **NEXT — verify x86_64 homing (ubuntu, Step 0.7) → measure x86_64 ROI → Phase V (close the campaign)**.
  Step 0.7 next resume: confirm the ubuntu test-all against `f31affa1` is GREEN (the existing fixtures
  loop_carried/membase/across_call/arr_sum/fp_sum now run HOMED on x86_64 there — the real x86_64 correctness
  gate; revert stage 4 on red). Then **measure the x86_64 ROI**: run a w45_addi-style bench on ubuntu (x86_64
  homed vs un-homed/v1) to confirm the gap closed on x86_64 too (Mac can't measure x86_64). If green + ROI →
  **campaign exit MET** (register-homed i32/i64 locals on both backends; D-265 gap closed) → **Phase V
  retrospective**: ADR-0149/0150 Revision note (regalloc headroom real on loop-locals) + ADR-0151 W45 note
  (loop-persistence matters for scalars) + close the campaign + §15.P + flip the ROADMAP. **Deferred** (measure-
  first / scope): stage 3 (fp/v128, thin ROI per W45) + stage 2b (GC trampolines, D-258/D-261). All autonomous.

## Current state

- **Phase 15 (Performance parity with v1) IN-PROGRESS.** Phases 0-14 DONE. **§15.1** GC reclamation DONE
  (`be4357be`; ADR-0146/0147/0148; carve-outs → D-211/D-258). **§15.2/15.3** regalloc-axis perf — measured-folded
  (ADR-0149/0150) — but the "~0 headroom" claim is being REVISED (D-265: real headroom on loop-locals). **§15.4**
  SIMD coverage+ports DONE (D-246 `1029e5b4`; ADR-0151). **§15.5** D-245 win64 trampoline DONE (`510ffce9` +
  D-260 fix `3a778080`, test-all 3-host green). **§15.6** ClojureWasm CI ⏸ DEFERRED (ADR-0152 → D-264; cw is its
  own in-progress v1 redesign). **§15.P** parity MEASURED (`s15p_parity_vs_v1.md`) → the remaining work = the
  **D-265 rework campaign** (`## Active rework campaign` above). Runs fully autonomously per the philosophy.

## Step 0.7 (next resume)

D-265 STAGE 4 (x86_64 homing) LANDED `f31affa1` — Mac gates green (test-edge-cases 80/0 arm64 unaffected; x86_64
cross-compile clean = 0 source errors). **ubuntu test-all kicked against `f31affa1` = the REAL x86_64 RUN gate**
(the fixtures now run HOMED on x86_64 there; Mac can't run x86_64). Step 0.7 next resume: verify ubuntu GREEN
(revert stage-4 `f31affa1` on red — x86_64 miscompile would surface ONLY here). Stages 1+2 already 2-host green.
(`a64c72a1`/`5d1dd221`/`7152021c`/`f31affa1` validated on Mac; x86_64 pending ubuntu.) **NOTE** (lesson
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
