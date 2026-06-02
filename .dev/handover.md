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

try_table.1.wasm runs 34 asserts (31 pass). Catch landing-pad + try_table-result classes FIXED (`590093f5`
catchless, `881b25e0` arity). The **3 remaining fails split into TWO root causes** (subagent disasm/read
diagnosis; the JIT matches tags by LOCAL INDEX — `HandlerEntry.tag_idx == throw_tag_idx`, exception_table.zig:87
— and `JitRuntime` has NO `tags: []*TagInstance` table, unlike interp `rt.tags` via instantiate.zig:1244-1281):

- **CAUSE A — aliased same-module import (fixes #2 `catch-imported-alias` trap; partial #3).** In module 2 the
  tag space is `[0]=$imported-e0, [1]=$imported-e0-alias` (both bind test::e0 = same TagInstance). catch idx 0,
  throw marshals idx 1 → `0==1` false → no match → uncaught → trap. **DO THIS FIRST (tractable).** Fix: give the
  JIT a tag-IDENTITY/canonical table — add `JitRuntime.tags_*` (jit_abi.zig ~381 cohort) populated in
  `engine/setup.zig` (~910, beside eh_table_entries) from the resolved imports (imports binding the same source
  tag → same identity/canonical id); throw marshals + `exception_table.lookup` matches by identity not raw idx
  (mirror interp `catchTagMatches` mvp.zig:814-818). Needs imported-tag resolution at the JIT runner/setup path
  (analog of jitResolveFuncImports — may not exist for tags yet; check). A canonical-u32 id (like ADR-0126 type
  ids) avoids a pointer-layout change.
- **CAUSE B — cross-INSTANCE throw (fixes #1 `catch-imported`; partial #3). DEEPER.** `catch-imported` calls
  test::throw (module 1) via the bridge thunk, which swaps runtime_ptr to module 1's `*JitRuntime` → the throw
  runs against module 1's EMPTY exception table → uncaught → thunk RETs normally → module 2 resumes past the
  call with `i32.const 1` leaked → returns 1 (the catch NEVER fires; not a landing-pad reconciliation bug).
  `unwind.zig:26-31` explicitly defers per-frame-instance dispatch. Fix: resolve the thrown tag to its identity
  at the throw site (throwing instance's tags), then FP-walk frames matching identity against EACH frame's OWN
  instance exception table (per-frame-instance dispatch). In §10.E scope ("cross-module exception propagation").

Cause A is the next chunk. Cause B is a deeper multi-cycle sub-arc (per-frame-instance unwind) — same bundle.

Other non-gated tracks (after EH): **D-234** (memory64 assert_trap harness artifact), **D-198**, **D-209**,
**D-210** (return_call_indirect-in-try = func[36], TC+EH gap). Realworld GC/EH/TC producers.

**USER-GATED (non-stop — only surface):** **§10-scope** → `.dev/phase10_scope_reassessment.md` (multi-memory's
407 JIT skips ⇒ JIT skip=0 unreachable as written; ADR-0128-amendment / user-flip). Non-gated work exists → do NOT stop.

## Active bundle

- **Bundle-ID**: `10.E-eh-on-jit` (opened `3b668110`).  **Cycles-remaining**: ~2-3.
- **Continuity-memo**: try_table.1.wasm COMPILES + RUNS, 31/34. ✅ func[6] validate (tag index space —
  `3b668110`) → ✅ func[24] catchless try_table (`590093f5`, +29) → ✅ try_table-result-arity drop (`881b25e0`,
  +2) → ❌ **3 imported-tag fails, diagnosed into Cause A (aliased-import identity, tractable, NEXT) + Cause B
  (cross-INSTANCE throw via bridge thunk, deeper)** — full fix plan + loci in Active task above. Root: JIT
  matches tags by local index; no `JitRuntime.tags` identity table. func[36] return_call_indirect-in-try =
  separate TC+EH gap (D-210 family).
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

LAST code turn = try_table-arity fix (`881b25e0`) — ubuntu **verified OK (HEAD=e0a502aa**, which includes
`881b25e0`; the whole EH chain 3b668110→e0a502aa is 2-host green). The most-recent re-invocation was a
READ-ONLY diagnosis of the 3 imported-tag fails (subagent; Cause A/B split above) — NO code commit, NO new
ubuntu kick. So next resume Step 0.7 has nothing new to verify (e0a502aa already OK); go straight to Cause A
implementation. Mac aarch64; ubuntu = x86_64.

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
