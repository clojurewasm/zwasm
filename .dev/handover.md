# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 107 (`590578e1`) — baked `register M` into the
  ref_func manifest (was stale `skip-impl directive-register`). D-192
  register infra was already complete (baker emits register; runner
  binds func exports via defineCrossModuleFunc); only the manifest was
  stale. ref_func.1's `(import "M" "f")` now RESOLVES — UnknownImport →
  **InstantiateFailed** (the next, deeper runtime gap). No regression
  (invalid 18, return pass 24).
- Prior: 106 scoping/pivot (`e0766509`, funcrefs return-rate gated on
  D-192); 105 element ref.func func-family + ParseFailed→0 (`6e58b534`);
  104 unreachable-poly (`8304714d`); 103 typed table/elem decode
  (`d24ad2da`); 102 ref.func typed (`7b9218c2`); 100-101 Gate 4 + 0xD4.
- Mac test + lint green. ubuntu: cycle-105 HEAD green (`a0692437`);
  cycle 106 docs-only; cycle-107 kick backgrounded (manifest change —
  zig build test unaffected, but kicked for consistency).

## Active bundle

- **Bundle-ID**: 10.X-D192-register (cross-module `register` directive;
  shared by func-refs ref_func.1 + EH try_table)
- **Cycles-remaining**: ~3
- **Continuity-memo**: cycle 107 closed the register-manifest gap
  (`register M` baked); the register INFRA was already complete. ref_
  func.1 import now resolves → the blocker is now **InstantiateFailed**
  (ref_func.1 AND ref_func.3, the latter self-contained = clean red
  test). ref_func.3 = `(global funcref (ref.func 0))` + active +
  declarative elem segments (`(elem (ref.func N))`). Likely a runtime
  instantiate-time gap: `ref.func` in a GLOBAL init expr, or element-
  segment table init with ref.func, not handled by the instantiate
  evaluator. Once instantiate works, ref_func.1 (+register M) runs its
  8 asserts → return 24→~32. **Corpus-drift caveat**: a full re-bake
  churns ref_func.2.wasm → invalid-accepted under wast2json 1.0.39 (the
  committed .wasm predate it); re-bake .wasm only with that managed.
- **Exit-condition**: ref_func.1 instantiates + its 8 assert_returns
  pass (function-references return ≥ 32/39) AND try_table.1 (EH)
  instantiates against try_table.0's registered tag/func.

## Active task — cycle 108: ref_func.3 InstantiateFailed (runtime ref.func global/elem init)

ref_func.3 is self-contained (no imports) but InstantiateFailed —
clean red test for the instantiate-time gap that also blocks ref_func.1.
**Step 0**: isolate the instantiate failure (a focused test compiling +
instantiating ref_func.3 via Engine+Linker, mirroring the runner; OR
stage-tag the `instantiateRuntime` / global-init-eval / element-init
path in `runtime/instance/instantiate.zig` + `instance.zig`). ref_func.3
has `(global funcref (ref.func 0))` + `(elem (i32.const 0) func 2)` +
`(elem (ref.func 3))` (declarative/funcref expr). Likely
`evalConstExprValue` / element-init doesn't handle `ref.func` →
InstantiateFailed. Smallest red test per the localized op (an
instantiate unit test or edge_cases fixture). Then ref_func.1 (+register)
unblocks.

## Larger §10 work (later bundles)

- **10.E EH spec corpus (Gate 1 / D-192)** — try_table.1.wasm imports
  `test::e0` tag + `test::throw` func from try_table.0.wasm; runner
  registry needs tag + func cross-module binding. Gate 2 (exnref byte
  `0x69` standalone + `ValType.exnref` pub-const) folds in here.
- **10.G WasmGC** — corpus baked (568 directives) but impl=0%; ZIR ops
  + heap impl + subtype lattice. NOTE: `valTypeIsSubtypeFree`'s
  `(ref $concrete) <: func` rule assumes pre-GC (all concrete = func
  type); 10.G must refine once struct/array heads enter module_types.
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-105)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass) exception=4(fail4)
[function-references] return=39(pass=24 fail=15) trap=4(pass=4) invalid=18(pass) ParseFailed=0 (10→7→6→3→1→0)
[gc                 ] return=407(fail) trap=100(fail) invalid=60(pass=55 fail=5) malformed=1(pass)
[multi-memory       ] return=407(pass=371 fail=36) trap=238(pass=237 fail=1)
```

## Open questions / blockers

- ADR-0120 / ADR-0123: Accepted; impl autonomous. ADR-0123 D4
  (ref.func typed) landed cycle 102.
- D-192: cross-module register substrate. New bundle after
  10.R-funcrefs-tail-2 closes.
- D-186 (return_call_ref): discharge predicate met by ADR-0123 D4 +
  cycle-102 opRefFunc typed push.

## Key refs

- ADR-0120 (Accepted — EH payload), ADR-0123 (Accepted — typed-ref;
  D4 ref.func typed landed cycle 102).
- `.dev/lessons/2026-05-28-funcrefs-tail-error-classes.md` (gate
  inventory + cycle-101/102 re-probe maps).
- ROADMAP §10; `.dev/phase_log/phase10.md`.
