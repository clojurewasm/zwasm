# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — re-scoped (ADR-0133)** (Phase 9 = DONE 2026-05-24). §10 exit =
  **interp pass=fail=skip=0 (MET) + JIT 0-real-fail + every JIT skip on the forward-ref'd
  deferred-allowlist** (multi-memory-on-JIT→§14, GC-on-JIT-rooting→§11). Raw "JIT skip=0" (ADR-0128)
  was unreachable in-phase; re-scoped autonomously per ADR-0132.
- **LAST code HEAD** (`be5a1a32`): arm64 br_on_null now handles function-return/loop targets (was forward-block
  only → UnsupportedOp on br_on_null.1). Routed through the shared `op_control.branchOnReg` (pop ref → 0/1
  null-flag in a RESERVED scratch W16 — NOT the ref's reg, that clobber was a mid-fix block regression → push
  ref back). br_on_null.1 modrej cleared; function-references 23/0/16 / global 811/1 unchanged (no asserts in
  that module); no regression. **§10 JIT module-rejects cleared this session**: D-239 (precise ref.func +
  null-ref emit dispatch, `faf23f0a`) + ref_null.0 concrete ref.null const-expr (`195856a1`) + br_on_null.1.
  Built on cross-instance EH (`4f73d9ee`, ADR-0134). x86_64 br_on_null function-return parity = D-238 bucket.
- **Cross-instance EH on JIT DONE** (`4f73d9ee`, 10.E-eh-on-jit bundle CLOSED, EH dir 34/0/0; ADR-0134). x86_64
  EH thunk-parity = D-238. Built on D2 (`cb55013e`) + D3 (`16a921a8`) + Cause A (`50e5ecd3`).
- **§10-exit determination** (ADR-0133 §4): interp 100% MET + JIT 0 GENUINE fails MET (memory64 = D-234 harness,
  6 proof paths, `f507bf33`) + the 17 module-rejects are in-phase MUST-FIX (NOT deferrable; allowlist = only
  multi-memory→§14 + GC-on-JIT→§11). Remaining rejects = the Active-task list.
- **Prior**: ADR-0132/0133 (`5447cb10`, autonomous re-sequence + Phase-10 exit re-scope). interp wasm-3.0 corpus
  FULLY GREEN. Spec corpus = interp default; JIT opt-in `ZWASM_SPEC_ENGINE=jit`; entry = `runner.zig` `JitInstance`.
  **GATE TRAP**: corpus exe MUST be picked by mtime (`find … -exec ls -t {} + | head -1`); bare `head -1` = STALE.
- **Watch**: `runner_test.zig` ~1415 / `compile.zig` 1223 / `runner_gc_test.zig` 1476 / `jit_abi.zig` 1350 (WARN, < hard 2000).

## Active task — §10-exit: **clear the remaining JIT module-rejects**  **NEXT**

§10 exit (ADR-0133 §4): interp 100% (MET) + JIT 0 genuine fails (MET — memory64 = D-234 harness) + clear the
module-rejects (in-phase must-fix, NOT deferrable). Progress this session: function-references 8/0/31 → **23/0/16**;
global JIT 796/1 → **811/1**; 7 of 8 fr rejects cleared (D-239 ref.func + emit dispatch, ref_null.0, br_on_null.1).
**UnsupportedEntrySignature ×7 CLASSIFIED** (this turn, read-only): all 7 are in **multi-memory** (linking1.2/.3,
data0.3-.6, imports2.2) → on the ADR-0133 deferred-allowlist (multi-memory→§14 + eligibility-gate), **NOT §10
blockers**. So the must-fix reject set is much smaller than the "17":
1. **`ref_is_null.0` + gc `i31.6`** (ElemSegmentTypeMismatch) → **D-240** (blocked-by): needs JIT typed/abstract-ref
   TABLE runtime (table.init from a reftype elem + table.get/set of typed refs) THEN the compile.zig:257
   eql→`valTypeIsSubtype` flip (loosening alone SEGV'd — proven this session). Probe via `debug_jit_auto`. Bigger.
2. **tail-call** `return_call_indirect.0` UnsupportedOp (D-210) — known multi-cycle TC emit gap.
3. **D-234** runner-side harness discharge (corpus stops false-reporting the 52 mem64 fails; codegen proven correct).
4. Verify the 1 `gc/type-subtyping run` UnsupportedEntrySignature SKIP (GC-on-JIT allowlist or a real gc gap?).

Recommended next: **D-234** (runner-side, unblocks the clean "0-real-fail" count — most §10-critical) OR **D-210**
(TC emit). D-240 is the biggest (typed-ref table runtime feature). Run `scripts/check_phase10_close_invariants.sh`
when the reject count hits 0.

Other tracks: **D-238** (x86_64 EH parity), realworld GC/EH/TC producers.

**§10-scope: RESOLVED** (ADR-0133) — autonomous. Future cross-phase mismatches: re-sequence per ADR-0132 (no stop).

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 stale u32; D-234 (51 OOB assert_trap = harness artifact).
- **10.R** function-references — corpus green; residual = D-198 + br_on_null/cast modrej (StackTypeMismatch).
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + return_call_indirect-in-try + `wasm_of_ocaml`.
- **10.E** EH — JIT EH dir **34/0/0** (cross-instance DONE, `4f73d9ee`); residual = x86_64 parity (D-238) +
  eh_frequency runner (I20), c_api tag accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit COMPLETE; §1 + PHASE C + D-235 DONE; remaining = D-198 + gc_stress (I19) + dart/hoot (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

THIS turn = verified the br_on_null fix-forward is 2-host green (ubuntu `OK (HEAD=2ce27d5b)`) + classified the
7 UnsupportedEntrySignature as multi-memory/allowlisted (read-only). Code state is `2ce27d5b`, ubuntu-verified
OK. The arm64 br_on_null function-return fix (`be5a1a32`) + the arch-pin guard (`24b4b6e5`) held; lesson
`2026-06-03-jitinstance-test-compiles-for-host-arch` filed. NO ubuntu kick needed this turn (handover-only;
code unchanged since the verified 2ce27d5b). Next → D-234 runner discharge (most §10-critical) OR D-210 TC emit.

**Gate hygiene**: Step-5 Mac gate = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert`
(NO bogus `-Dno-run`); **pick the exe by mtime** — `/usr/bin/find .zig-cache/o -name zwasm-spec-wasm-3-0-assert
-type f -exec ls -t {} + | head -1` (bare `head -1` returns a STALE binary → masks the delta; relearned this turn).
`ZWASM_SPEC_ENGINE=jit <exe> test/spec/wasm-3.0-assert --fail-detail >out 2>err` (SPLIT stderr). Per-dir
`JIT: return pass/fail/skip` + `JITval`/`JITfail`/`JITmodrej`.

## Key refs

- ADR-0128 (Phase 10 100%); ADR-0114 (EH design — try_table/landing pads/trampoline); ADR-0119 (naked trampoline);
  ADR-0131/0126 (subtype + canonical ids, D-235). ROADMAP §10.E. `debug_jit_auto` skill for the dispatch fails.
- Debt: **D-234**, D-198 / D-209 / D-210 / D-211 / D-212.
  Lessons: `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`,
  `2026-06-02-jit-corpus-late-phase-is-per-module-blocker-stacks`, `2026-06-03-jit-trampoline-mid-op-clobbers-operands`.
