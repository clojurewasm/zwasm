# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — re-scoped (ADR-0133)** (Phase 9 = DONE 2026-05-24). §10 exit =
  **interp pass=fail=skip=0 (MET) + JIT 0-real-fail + every JIT skip on the forward-ref'd
  deferred-allowlist** (multi-memory-on-JIT→§14, GC-on-JIT-rooting→§11). Raw "JIT skip=0" (ADR-0128)
  was unreachable in-phase; re-scoped autonomously per ADR-0132.
- **LAST code HEAD** (`4f73d9ee`): **cross-instance EH on JIT WORKS — EH JIT dir 34/0/0 (ADR-0134, Cause B DONE).**
  A module-1 throw now reaches a module-2 catch. Three pieces (cycle 2b): (D1) arm64 bridge thunk gains
  `MOV X29,SP` after the STP so its frame FP-links into the chain (else the FP-walk reaches the caller frame
  carrying a thunk pc; instr 19→20 ate the pad, size 96 unchanged); (registration) the spec runner registers
  each heap-pinned instance's `*JitRuntime` in `eh_registry` (+ unregister at every free site + per-manifest
  reset); (handler-cmap) `trampolineCore` resolves the catching instance's `CodeMap` from `handler_abs_pc`
  (`eh_registry.codeMapForPc`) for the cross-instance SP-restore. **EH dir 32/2 → 34/0/0; global JIT 794/3 →
  796/1; no regression.** Built on D2 (`cb55013e`, unwind machinery: `lookupByIdentity` + `walk` `InstanceResolver`
  + `eh_registry`) + D3 (`16a921a8`, global `tag_ids` u64 cross-module identity) + Cause A (`50e5ecd3`).
- **10.E-eh-on-jit bundle = CLOSED** (`4f73d9ee`, exit 34/0/0 verified). x86_64 EH thunk-parity +
  `cross_module_throw_propagation.wat` fixture = **D-238** (ADR-0134 cycle 3; arch-parity, not Mac-§10-gating).
- **§10-exit audit + determination** (`f507bf33` + subagent; determination this turn, no new code): interp
  100% MET; JIT 0 GENUINE fails MET (memory64 = D-234 harness, 6 proof paths); skips all on the ADR-0133
  allowlist. **Determination (ADR-0133 §4): the 17 module-rejects are in-phase MUST-FIX, not deferrable.**
  First cluster root-cause PINNED → **D-239** (JIT compile.zig doesn't pass the validator's `func_type_indices`
  → `ref.func` abstract not precise → StackTypeMismatch; + emit-dispatch gap). NEXT = fix D-239.
- **Prior**: ADR-0132/0133 (`5447cb10`, autonomous re-sequence + Phase-10 exit re-scope). interp wasm-3.0 corpus
  FULLY GREEN. Spec corpus = interp default; JIT opt-in `ZWASM_SPEC_ENGINE=jit`; entry = `runner.zig` `JitInstance`.
  **GATE TRAP**: corpus exe MUST be picked by mtime (`find … -exec ls -t {} + | head -1`); bare `head -1` = STALE.
- **Watch**: `runner_test.zig` ~1415 / `compile.zig` 1223 / `runner_gc_test.zig` 1476 / `jit_abi.zig` 1350 (WARN, < hard 2000).

## Active task — §10-exit: **fix D-239 (JIT function-references validator + emit)**  **NEXT**

**Determination RESOLVED** (ADR-0133 §4, this turn): the 17 module-compile rejects are §10 **in-phase
must-fix**, NOT deferrable. The deferred-allowlist is ONLY multi-memory→§14 + GC-on-JIT→§11 (both ✓). So
§10 exit = interp 100% (MET) + JIT 0 genuine fails (MET — all memory64 fails are D-234 harness, 6 proof
paths, `f507bf33`) + **clear the 17 rejects**. Concrete fix-list, start with the function-references cluster
(**D-239**, root cause PINNED this turn):
1. **D-239 (NEXT)** — JIT `compile.zig` validate doesn't build/pass the validator's `func_type_indices`
   map → `ref.func N` types as abstract funcref (not precise `(ref func_type_indices[N])`, ADR-0123 D4) →
   StackTypeMismatch (e.g. br_on_null.0 func[4] `(call $nn (ref.func $f))`). FIX (A): build the map in
   `compile.zig` (mirror `instantiate.zig:128-143` imports-first func→typeidx) + thread into the
   function-validate call. FIX (B): wire the 3 emit ops into `arm64/emit.zig` dispatch (handler files exist
   at `ops/wasm_3_0/{br_on_null,br_on_non_null,ref_as_non_null}.zig` — verify real-not-stub). A is primary.
   RED test: a minimal fr module (`ref.func $f` → `(ref $t)` param) via `JitInstance.init` compiles (no
   StackTypeMismatch). Verify corpus: function-references modrej drops. (NOT D-198 — that's interp GC subtyping.)
2. Then the remaining rejects: tail-call return_call_indirect UnsupportedOp (D-210), ref_is_null
   ElemSegmentTypeMismatch + ref_null InvalidGlobalInitExpr + gc i31.6 (likely share D-239 root A — verify),
   UnsupportedEntrySignature ×7 (invoke-path). + **D-234** runner-side harness discharge (so the corpus
   stops false-reporting the 52 mem64 fails — required for the "0-real-fail" count to read clean).

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

THIS turn = cross-instance EH 2b (`4f73d9ee`, code; arm64 thunk + registration + handler-cmap). Mac `test-all` +
lint GREEN; JIT corpus EH dir 34/0/0, global 796/1, no regression. ubuntu `test-all` kicked against the turn HEAD
— Step 0.7 next resume: `tail -3 /tmp/ubuntu.log`, revert the commit pair on FAIL. NOTE: ubuntu (x86_64) runs the
interp+unit gate, NOT the JIT EH corpus (Mac-only); x86_64 EH thunk parity = D-238. (Prior 2a `5e076a6f`
ubuntu-verified OK this turn.) Then → §10-exit endgame (the 1 memory64 return-fail + skip-allowlist audit).

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
