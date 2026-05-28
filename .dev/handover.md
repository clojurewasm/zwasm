# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 103 (`d24ad2da`) — typed-ref table + element reftype
  decode (`decodeTables`/`decodeElement` via `init_expr.readRefType`)
  + concrete-index bound check in `preDecodeSectionBodies` (ref.4/ref.5
  stay assert_invalid). Foundation for typed-ref tables/elems.
- Bundle 10.R-funcrefs-tail CLOSED cycle 102 (`7b9218c2`, return 0→7,
  ParseFailed 6→3). Cycle 100 Gate 4 (`2fa216b9`); 101 ref.as_non_null
  0xD4 (`c82e8124`); 102 ref.func typed `(ref $sig)` (`7b9218c2`).
- Mac aarch64 test + lint green (cycle 103). ubuntu x86_64 SSH gate:
  cycle-102 HEAD confirmed green; cycle-103 kick backgrounded —
  Step 0.7 next resume verifies.

## Active bundle

- **Bundle-ID**: 10.R-funcrefs-tail-2 (follow-up; cycles 104+)
- **Cycles-remaining**: ~2
- **Continuity-memo**: cycle 103 landed the typed-table/elem decode +
  bound-check FOUNDATION (ref_is_null.0's `(table (ref null 0))` +
  typed elem now decode). The 3 remaining ParseFailed all now fail IN
  func bodies (re-probed cycle 103 via temp `frontendValidate` per-func
  print):
  - `ref_is_null.0` → **func#0 BadValType** — ANOMALOUS: func 0 is
    `(func (type 0))` (empty body), which shouldn't BadValType. Next
    cycle MUST print func#0's body bytes (the per-func probe attributes
    by code-section index; verify the attribution + dump body) before
    assuming the op. Candidate: a typed-`select` / typed-`ref.null`
    site, OR a mis-decoded code entry.
  - `br_on_non_null.0`, `ref_as_non_null.0` → **StackTypeMismatch**
    (per-func, concrete typed ref `(ref 0)` flowing through
    `block (result (ref 0))`/`br_on_non_null`/`call_ref`).
- **Exit-condition**: function-references ParseFailed = 0 (all 15
  modules across the 7 manifests compile) — currently 3.

## Active task — cycle 104: br_on_non_null.0 / ref_as_non_null.0 StackTypeMismatch (per-func typed-ref)

Highest-yield clean target (2 modules, same class). **Step 0**: re-add
the per-func probe (instantiate.zig per-func validate `catch` print) to
get the exact failing op, OR bisect via a `validateFunctionWithMemIdx-
AndTags` body test replicating the `block (result (ref 0))` +
`br_on_non_null` + `call_ref` shape. Likely a concrete-typed-ref
subtype/equality gap in `opBrOnNonNull` / block-end type check / the
`call_ref` callee-type match. Smallest red test per the localized op.

Parallel: `ref_is_null.0` func#0 BadValType is anomalous — dump the
code-section func#0 body bytes (re-probe with body slice print) to
confirm WHICH op/site fails before fixing. After ParseFailed = 0:
raise the function-references return pass-rate (currently 7/39).

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

## Spec runner observable (post-cycle-103; ParseFailed/return unchanged from 102 — cycle 103 = decode foundation)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass) exception=4(fail4)
[function-references] return=39(pass=7 fail=26) trap=4(pass=1 fail=3) invalid=18(pass) ParseFailed=3 (10→7→6→3)
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
