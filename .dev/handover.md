# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active rework campaign

(ADR-0153 structural rework campaign — runs AUTONOMOUSLY; "hard gate" = self-enforced ordering, not a user stop.
Read [`REWORK.md`](../.claude/skills/continue/REWORK.md). Bundle mode nests inside a phase for continuity.)

- **Campaign-ID**: regalloc-resident-locals (D-265) — the single-pass baseline 完成形 (keep hot locals
  register-resident, as v1 does; within P3/P6, NOT an optimising tier). This IS the §15.P parity-achievement work.
- **Phase**: **IV — implementation. ✅ STAGE 1 LANDED** (`a64c72a1`). I/II/III DONE (ADR-0155 register-homed
  locals, fix A = APPEND pseudo-vregs at highest ids → no renumbering → no break of liveness block/br arithmetic;
  the prior-spike prepend bug). New SSOT `src/ir/analysis/local_homing.zig` (every pass re-derives the plan →
  can't drift). **ROI: w45_addi 2.30× → 0.97× (parity, target ≤1.1× MET)**; all gates green (test-edge-cases 0
  failed incl. the NEW clang-O0 `homed_local_membase_loop` fixture that repro'd the spike's arr_sum/fp_sum
  miscompile; `zig build test` exit 0; test-spec 9/0; lint + x86_64 cross-compile clean). Stage-1 gates: aarch64
  only / declared i32-i64 locals only (params+fp+v128+GcRef slot-homed) / no-call fns only / cap 6.
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
- **NEXT — Phase IV stage 2 (call-site spill/reload)**. Stage 1 homes locals only in CALL-FREE functions (a homed
  local in a caller-saved reg would be clobbered across a call). Stage 2: at each call site, spill homed locals
  that live in caller-saved registers to their `local_base_off` slots, reload after — then drop the no-call gate
  in `local_homing.zig isCallLike`. Survey v1's call-site local spill (`jit.zig:1705-1719`) + v2's ABI
  cohort/caller-saved set. Add a Phase-II fixture: a homed local read across a call (correctness). Then stage 3
  (FP/v128 homes, V16-V28 class) / stage 4 (x86_64 parity, P7 — the big one, gated K=0 today). Each: net green
  every commit + ubuntu test-all. **ubuntu test-all kicked this turn** against stage 1 (x86_64 K=0-gated → expect
  no behavior change; Step 0.7 verifies). All autonomous per the philosophy.

## Current state

- **Phase 15 (Performance parity with v1) IN-PROGRESS.** Phases 0-14 DONE. **§15.1** GC reclamation DONE
  (`be4357be`; ADR-0146/0147/0148; carve-outs → D-211/D-258). **§15.2/15.3** regalloc-axis perf — measured-folded
  (ADR-0149/0150) — but the "~0 headroom" claim is being REVISED (D-265: real headroom on loop-locals). **§15.4**
  SIMD coverage+ports DONE (D-246 `1029e5b4`; ADR-0151). **§15.5** D-245 win64 trampoline DONE (`510ffce9` +
  D-260 fix `3a778080`, test-all 3-host green). **§15.6** ClojureWasm CI ⏸ DEFERRED (ADR-0152 → D-264; cw is its
  own in-progress v1 redesign). **§15.P** parity MEASURED (`s15p_parity_vs_v1.md`) → the remaining work = the
  **D-265 rework campaign** (`## Active rework campaign` above). Runs fully autonomously per the philosophy.

## Step 0.7 (next resume)

D-265 STAGE 1 LANDED (`a64c72a1`) + **Step-0.7 x86_64 fix** (`7152021c`): ubuntu caught 3 host-fragile emit
unit-tests (asserted the homed layout but ran un-homed on the x86_64 host — homing gates on host arch; the
x86_64 CODEGEN was correct/unchanged) → comptime-arch-gated them (NOT a codegen revert; ROI win stands). **ubuntu
test-all RE-KICKED against `7152021c`** → Step 0.7 next resume verifies green (the 3 tests now skip on x86_64).
Next = stage 2 (call-site spill). (`510ffce9`/`3a778080` validated; do NOT revert.) **NOTE** (lesson
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
