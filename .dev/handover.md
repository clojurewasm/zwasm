# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 110 (`447c1048`) — EH cross-module step 1:
  `ImportKind.tag` (0x04) + `ImportPayload.tag_typeidx` + decode arm +
  the exhaustive-switch cascade (7 files, step-1 stub arms). Observable
  stage move: **exception-handling/try_table.1 + .5 go from compile
  FAIL:ParseFailed → parse+compile+INSTANTIATE** (surprise: they
  instantiate without the step-2 tag binding — the remaining 0/34 is
  execution-side, not instantiate).
- Prior: 109 EH survey + bundle re-scope (`06473742`); 108 ref.func
  global-init → funcrefs return 24→32 (`e3a22ec2`); 107 register M
  (`590578e1`); 100-106 funcrefs parse+return chain.
- Mac test + lint green (cycle 110). ubuntu: cycle-108 HEAD green
  (`622a7027`); cycle 109 docs-only; cycle-110 kick backgrounded.

## Active bundle

- **Bundle-ID**: 10.E-xmodule-tags (EH cross-module tag imports per
  ADR-0114; D-192 register's funcrefs clause CLOSED cycle 108)
- **Cycles-remaining**: ~5
- **Continuity-memo**: D-192 register substrate PROVEN (funcrefs
  return 24→32 cyc100-108). EH clause = a MAJOR designed-but-unimpl
  substrate (ADR-0114) — full scope + the 5-step plan in
  `lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`.
  try_table.1 imports `test::e0` (TAG ×2) + `test::throw` (func) from
  try_table.0. Gaps: ImportKind has no `.tag` (parser rejects 0x04);
  tag exports filtered at decode (`sections.zig:606`); no
  `ImportBinding.tag` / Linker tag API; tag identity index-based
  (`exception.zig` tag_idx) not ADR-0114 `*TagInstance` → cross-module
  throw/catch can't match. Plan: parser(1)→instantiate(2)→TagInstance
  storage(3)→identity match(4)→JIT(5). Steps 1-2 are 0-corpus-delta;
  frame each cycle's observable as the STAGE move (parse→instantiate→
  match), not corpus count, until step 4.
- **Exit-condition**: exception-handling try_table corpus return pass
  ≥ 5/34 (currently 0/34) — i.e. cross-module throw/catch matches via
  `*TagInstance` for at least the simple-throw-catch cases.

## Active task — cycle 111: probe WHY try_table.1's asserts fail (now that it instantiates)

Step 1 (cycle 110) un-blocked parse+instantiate for try_table.1/.5, so
the 5-step plan re-orders: instantiate-binding (old step 2) is NOT the
blocker (try_table.1 instantiates with the unbound tag — the throw func
import `test::throw` resolves via the runner's register func-binding;
the tag import apparently doesn't block instantiate). **Step 0 (probe)**:
instrument the wasm_3_0 runner's assert_return/assert_exception path (or
a focused test) to find WHY try_table.1's `simple-throw-catch` etc.
fail — distinguish (a) **JIT throw/throw_ref emit incomplete**
(`arm64/emit.zig:1172` per the lesson — the runner may JIT-compile the
EH funcs), (b) **tag-identity mismatch** (cross-module throw tag_idx ≠
catch import tag_idx; ADR-0114 *TagInstance, step 4), or (c) interp
EH path. The probe picks which of steps 3-5 to do next. Smallest red
test per the localized execution gap. NOTE: tag-export un-filter +
Linker tag binding (old step 2) deferred — only do if a fixture proves
they're needed (try_table.1 instantiates without them).

## Larger §10 work (later bundles)

- **10.E EH spec corpus (Gate 1 / D-192)** — try_table.1.wasm imports
  `test::e0` tag + `test::throw` func from try_table.0.wasm; runner
  registry needs tag + func cross-module binding. Gate 2 (exnref byte
  `0x69` standalone + `ValType.exnref` pub-const) folds in here.
- **10.G WasmGC** — corpus baked (568) impl=0%; ZIR ops + heap +
  subtype lattice (10.G refines `valTypeIsSubtypeFree`'s pre-GC
  `(ref $concrete) <: func` assumption).
- **Deferred funcrefs gaps** (post-D-192-EH): engine/cli_run
  `resolveFuncrefGlobals` unwired (ref.func globals null in cli_run);
  externref-elem (runner externref invoke-arg parsing). Both real but
  off the spec-corpus path.
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-108)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass) exception=4(fail4)
[function-references] return=39(pass=32 fail=1) trap=4(pass=4) invalid=18(pass) ParseFailed=0  (return 0→7→12→24→32 cyc100-108; only externref-elem left)
[gc                 ] return=407(fail) trap=100(fail) invalid=60(pass=55 fail=5) malformed=1(pass)
[multi-memory       ] return=407(pass=371 fail=36) trap=238(pass=237 fail=1)
```

## Open questions / blockers

- ADR-0120 / ADR-0123: Accepted; impl autonomous. ADR-0123 D4
  (ref.func typed) landed cycle 102.
- D-192: register substrate PROVEN (funcrefs). EH clause = active
  bundle 10.E-xmodule-tags (ADR-0114 *TagInstance impl).
- D-186 (return_call_ref): discharge predicate met by ADR-0123 D4 +
  cycle-102 opRefFunc typed push.

## Key refs

- ADR-0120 (Accepted — EH payload), ADR-0123 (Accepted — typed-ref;
  D4 ref.func typed landed cycle 102).
- `.dev/lessons/2026-05-28-funcrefs-tail-error-classes.md` (gate
  inventory + cycle-101/102 re-probe maps).
- ROADMAP §10; `.dev/phase_log/phase10.md`.
