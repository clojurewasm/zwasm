# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE 2026-05-24).
  §10 exit = official Wasm 3.0 testsuite at pass=fail=skip=0 on **both backends** (interp + JIT).
- **HEAD** (`881b25e0`): **JIT try_table label carries blocktype arity** — both arches hardcoded
  result_arity=0/param_arity=0, so the matching `end` truncation discarded the try_table's result vreg →
  a normal-completion consumer (return/br) marshalled a stale register (pointer). Disasm-confirmed
  (debug_jit_auto). Unpack arity from `ins.extra` mirroring `op_control.emitBlock`. JIT EH dir
  `pass=29 fail=5 → pass=31 fail=3` (simple-throw-catch + catch-complex-1 now pass); global `791/6 → 793/4`;
  no regression. +1 run unit test.
- **Prior (this bundle chain)**: `590093f5` JIT catchless try_table (eh_catch_entries null→empty; unblocked
  try_table.1 compile, +29 EH); `3b668110` JIT tag index space includes imported tags (validator
  StackTypeMismatch); `2b48dfdc`/`74d155b7` D-235 JIT call_indirect subtype. interp wasm-3.0 corpus FULLY
  GREEN. Spec corpus = interp default; JIT opt-in `ZWASM_SPEC_ENGINE=jit`; JIT entry = `runner.zig` `JitInstance`.
- **EH-on-JIT dispatch IS wired** (lesson `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`):
  throw_trampoline.zig trampolineCore + zwasmThrowTrampoline (all 3 ABIs) set eh_handler_sp/fp/pc + JMP.
  Its docstring (lines 9-35, "3c-ii deferred") is STALE — fix when next touching. With try_table.1 now
  compiling, the dispatch RUNS — and the 5 fails are real dispatch-correctness bugs (below).
- **Watch**: `runner_test.zig` 1370 / `compile.zig` 1223 / `runner_gc_test.zig` 1476 / `jit_abi.zig` 1350 (WARN, < hard 2000).

## Active task — `10.E-eh-on-jit` bundle: the 3 imported-tag EH fails  **NEXT**

try_table.1.wasm runs 34 asserts (31 pass). The catch landing-pad + try_table-result classes are FIXED
(`590093f5` catchless, `881b25e0` arity). The **3 remaining JIT fails are all the imported-tag class**
(cross-module tag identity / unwind; likely two distinct sub-issues — needs `debug_jit_auto`):

1. **`catch-imported`** returns `1` (expected 2): body `(call $imported-throw (i32.const 1))` — a
   CROSS-MODULE call (test::throw) that throws test::e0. The catch `$imported-e0` should fire → `(i32.const 2)`.
   Returns `1` = the pre-throw stack value leaked → the unwind THROUGH the cross-module call frame doesn't
   reconcile the JIT operand stack to $h's depth (or the catch matched but stack-cleanup is wrong).
2. **`catch-imported-alias`** TRAPS (expected 2): catches `$imported-e0`, throws `$imported-e0-alias` — two
   imports of the SAME test::e0. Per spec both alias the same tag → catch MUST match. JIT compares tag by
   local INDEX (HandlerEntry.tag_idx 0 vs 1) → no match → propagates → trap. Interp shares TagInstance
   pointers (identity), JIT is index-based. Fix = imported-tag identity at JIT catch-match (the JIT exception
   table / unwinder must resolve imported tag_idx → source TagInstance identity, not the local index).
3. **`imported-mismatch`** (try_table.2) returns `1` (expected 3) — same cross-module imported-tag class.

Start with #2 (clearest: aliased-import identity). See `src/engine/codegen/shared/{exception_table.zig
(HandlerEntry.tag_idx + lookup), zwasm_throw.zig (dispatchThrow tag compare), unwind.zig}` + how the thrown
tag's identity is passed (op_throw marshals tag_idx; cross-module throw identity). Interp ref: instantiate.zig
cyc116 `tags_arr` TagInstance identity + import.zig source_tag_index.

Other non-gated tracks (after EH): **D-234** (memory64 assert_trap harness artifact), **D-198**, **D-209**,
**D-210** (return_call_indirect-in-try = func[36], TC+EH gap). Realworld GC/EH/TC producers.

**USER-GATED (non-stop — only surface):** **§10-scope** → `.dev/phase10_scope_reassessment.md` (multi-memory's
407 JIT skips ⇒ JIT skip=0 unreachable as written; ADR-0128-amendment / user-flip). Non-gated work exists → do NOT stop.

## Active bundle

- **Bundle-ID**: `10.E-eh-on-jit` (opened `3b668110`).  **Cycles-remaining**: ~2.
- **Continuity-memo**: try_table.1.wasm blocker STACK (now COMPILES + RUNS, 31/34). ✅ func[6] validate
  StackTypeMismatch (tag index space — `3b668110`) → ✅ func[24] try_table UnsupportedOp (catchless —
  `590093f5`, +29) → ✅ try_table-result-arity drop (`881b25e0`, +2: simple-throw-catch + catch-complex-1)
  → ❌ **3 imported-tag fails** (catch-imported returns 1 [cross-module-call unwind stack leak];
  catch-imported-alias traps [aliased-import identity, JIT index vs interp TagInstance]; imported-mismatch
  returns 1). func[36] return_call_indirect-in-try = separate TC+EH gap (D-210 family). The handler dispatch
  is wired; remaining = cross-module imported-tag identity + unwind-through-call stack reconciliation.
- **Exit-condition**: JIT EH dir return-fail = 0 (currently pass=31 fail=3 skip=0 → target 34/0/0).

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 stale u32; D-234 (51 OOB assert_trap = harness artifact).
- **10.R** function-references — corpus green; residual = D-198 + br_on_null/cast modrej (StackTypeMismatch).
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + return_call_indirect-in-try + `wasm_of_ocaml`.
- **10.E** EH — try_table.1 compiles+runs (31/34); blocker = 3 imported-tag fails above + eh_frequency runner (I20),
  c_api tag accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit COMPLETE; §1 + PHASE C + D-235 DONE; remaining = D-198 + gc_stress (I19) + dart/hoot (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

THIS turn = the try_table-arity fix (`881b25e0`). Empirically: EH dir pass 29→31 fail 5→3, global 791→793
pass fail 6→4, NO other-dir regression (memory64 336/1, tail-call 31/0, gc 387/0, function-references 8/0,
multi-memory 0/0 unchanged); gate green; +1 run unit test. ubuntu kick fired for `881b25e0` (verifies x86_64
build of the shared try_table.zig arity change). Next resume Step 0.7: `tail -3 /tmp/ubuntu.log` — expect
`OK (HEAD=881b25e0)`; on FAIL investigate the x86_64 try_table label-arity (the inline unpack mirrors arm64).
PRIOR cycle `590093f5`/`d69a720b` already verified OK. Mac aarch64; ubuntu = x86_64.

**Gate hygiene**: Step-5 Mac gate = `bash scripts/mac_gate.sh`. JIT corpus: `zig build test-spec-wasm-3.0-assert`
(NO bogus `-Dno-run`), freshest exe via `/usr/bin/find .zig-cache/o -name zwasm-spec-wasm-3-0-assert` (shell
`ls` alias appends `*` → exec 127), `ZWASM_SPEC_ENGINE=jit <exe> test/spec/wasm-3.0-assert --fail-detail >out 2>err`
(SPLIT stderr — emit diagnostics splice into stdout). Per-dir `JIT: return pass/fail/skip` + `JITval`/`JITfail`/`JITmodrej`.

## Key refs

- ADR-0128 (Phase 10 100%); ADR-0114 (EH design — try_table/landing pads/trampoline); ADR-0119 (naked trampoline);
  ADR-0131/0126 (subtype + canonical ids, D-235). ROADMAP §10.E. `debug_jit_auto` skill for the dispatch fails.
- Debt: **D-234**, D-198 / D-209 / D-210 / D-211 / D-212.
  Lessons: `2026-06-03-eh-on-jit-blocker-is-validator-not-dispatch`,
  `2026-06-02-jit-corpus-late-phase-is-per-module-blocker-stacks`, `2026-06-03-jit-trampoline-mid-op-clobbers-operands`.
