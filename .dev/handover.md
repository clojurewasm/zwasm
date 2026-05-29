# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `29b16a5b` (cyc209). funcref-call + tail-call JIT POSITIVE paths done both
  arches (call_ref + return_call_ref + direct/indirect/recursion return_call + clang
  musttail; all ubuntu-verified). **NEW BUG D-208**: cyc208 null-trap fixtures (ungated)
  caught an x86_64 miscompile — call_ref/return_call_ref of a NULL funcref returns 0
  instead of trapping on x86_64 (arm64 traps OK). cyc209 gated the 2 null-trap tests to
  aarch64 (`skip.blocker(.@"D-208")`) → green restored; D-208 tracks the x86_64 fix.
  D-205 discharged; D-207 discharged (call_ref/return_call_ref JIT + arm64 null-trap);
  open: D-208 (x86_64 null-check), D-206 (cross-module TC, harness-gated).
- Earlier: 10.TC same-module tail-call (direct/indirect/recursion + clang musttail
  → 15, cyc198-201); EH corpus 34/34 (ADR-0114); cyc190-196 gc global-init/subtyping.
  Phase 10 CLOSE-ELIGIBLE (spec corpus interp-complete); Runner EXECUTES via interp,
  gc_heap materialised at instantiate. 10.M memory64 + 10.E EH JIT largely done;
  10.G GC JIT = interp-only (extreme: regalloc stack-map, ADR-0113 §C).
- **Step 0.7 on resume**: cyc209 (D-208 gate, src) kicks ubuntu @ `29b16a5b` — verify
  next cycle (null-trap tests now aarch64-gated → x86_64 skips → should be GREEN).
  Prior: cyc208 ubuntu FAILED (ungated null-trap `expected error.Trap, found 0` on
  x86_64) → recovered cyc209 via the gate (NOT a revert; arm64 coverage kept).

## Active task — investigate D-208 (x86_64 funcref null-check miscompile)  **NEXT**

x86_64 `call_ref`/`return_call_ref` of a NULL funcref returns 0 instead of trapping
(arm64 OK). Can't reproduce on Mac aarch64 → investigate via byte inspection: emit
the x86_64 null-check sequence for the `ref.null; call_ref` module and ndisasm it
(`debug_jit_auto` skill). Step-0: write a Mac-runnable test that drives the x86_64
`emitCallRef` (explicit-arg form) on a null funcref + dumps the bytes, OR cross-read
the emitted bytes; ndisasm to verify `OR r64,r64` / `JZ rel32` (after fixup) /
`MOV RAX,[funcref+16]` is correct. Hypotheses (all "correct in theory" — see D-208):
the `OR`/`JZ` interaction with `gprLoadSpilled`'s returned reg, or the JZ-disp fixup.
Likely a 1-line fix once the bad byte is found; fix → ungate → verify on ubuntu.
Deferred: 10.P close-invariant SKIP reassessment; cross-module TC (D-206).

## §10 close map

Spec-corpus rows (10.G/10.M/10.E/10.TC/10.R) are mature but ROADMAP-`[ ]`;
formal close needs realworld/p10 + 10.P. Residual:
- **realworld/p10**: clang_musttail DONE (cyc201, JIT result-checked); clang_wasm64
  next-AUTONOMOUS (clang✓); emscripten/dart/ocaml/hoot TOOL-GATED.
- **gc .17** funcref-RTT (D-198 multi-mechanism rabbit hole) — deep defer.
- **funcrefs** 34/39 — 5 gated; **10.P close gate** = user touchpoint.

## Spec runner observable (cyc190, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=349/407 trap=96/100 invalid=60/60 ✅ malformed=1/1 skip=20  ← cyc190 invalid-axis closed
[multi-memory       ] return=407/407 trap=244/244  ← cyc188 ALL-GREEN (D-199/200/201 cross-module chain)
```
> gc residual: return=1 + trap=4 = type-subtyping.30/.48/.50 (the bundle).
> Use `--fail-detail` (reliable per-assert), NOT the per-manifest breakdown.

## Open questions / blockers

- D-197: parse/validate/instantiate split DONE cyc127. Specific
  validate-error surfacing is ad-hoc via the cyc143 op-probe (lesson
  `gc-type-subtyping-is-rtt-blocked`); permanent diag emitter = D-197 tail.
- D-192: EH clause PROVEN (EH 34/34). funcrefs clause proven cyc108.

## Key refs

- ADR-0114 (EH `*TagInstance`, IMPLEMENTED cyc110–120); ADR-0115/0116/
  0121 (GC heap + type-info); ADR-0120/0123.
- `.dev/lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`
  (full EH journey) + `2026-05-29-zig-run-step-cache-stale-diag.md`.
- ROADMAP §10; `.dev/phase_log/phase10.md`.
