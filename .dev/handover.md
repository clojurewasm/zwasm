# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 100 (`2fa216b9`) — Gate 4 BadBlockType closed.
  Typed-ref blocktype (`0x63`/`0x64`) now accepted in
  `readBlockType` + `readBlockArity`, with concrete heap-type
  index bound-check (ref.9/ref.10 stay assert_invalid).
- Mac aarch64 test + lint green (cycle 100). ubuntu x86_64 SSH
  gate: cycle-99 HEAD confirmed green; cycle-100 kick is
  backgrounded — Step 0.7 next resume verifies.
- Session 81→99: D-179 discharged; ADR-0120 + ADR-0123 accepted;
  ValType pivoted to union(enum); GC corpus unlocked (+568
  directives baked).

## Active bundle

- **Bundle-ID**: 10.R-funcrefs-tail (cycles 101-103 ahead)
- **Cycles-remaining**: ~3
- **Continuity-memo**: cycle 100 cleared Gate 4 — function-references
  ParseFailed **10 → 7** (the 3 BadBlockType modules now parse; delta
  in `2fa216b9` body). Remaining 7 ParseFailed are the null-class ops
  (br_on_null, ref_is_null, br_on_non_null, ref_as_non_null) — these
  now surface their *next* per-function error (StackTypeMismatch /
  NotImplemented / opRefFunc-nullability per the cycle-95 inventory).
  Reuse lesson: the validator must bound-check concrete heap-type
  indices itself — `init_expr.readTypedRef` is index-free (serves
  init-expr contexts), so the blocktype decoder owns the check.
- **Exit-condition**: function-references return pass-rate ≥ 5/39
  (currently 0/39) AND corpus ParseFailed < 5 (currently 7) — at
  least half the remaining ParseFailed modules clear via cycles
  101-102.

## Active task — cycle 101: Gate 3 (opRefFunc non-null push)

Per cycle-99 dependency-order analysis +
`lessons/2026-05-28-funcrefs-tail-error-classes.md`. **Step 0
(re-probe first)**: BadBlockType is cleared, so the 7 remaining
ParseFailed modules now fail at a later function/op — wire the
cycle-95-style diagnostic (`frontendValidate` per-func error print)
to confirm the now-leading class before fixing. Cycle-99 hypothesis:
`ref.func N` should push NON-nullable `(ref func)` per ADR-0123 D4,
not the legacy nullable funcref; non-null contexts (ref_as_non_null,
br_on_non_null result match) reject otherwise. Site: opRefFunc in
`src/validate/validator.zig` (+ lower/interp push if it tracks
nullability). Smallest red test: a body requiring the non-null
funcref result to type-check.

After cycle 101: cycle 102 = Gate 2 (exnref byte `0x69` standalone +
`ValType.exnref` pub-const); cycle 103 = bundle close + open
follow-up bundle for Gate 1 (D-192).

## Larger §10 work (later cycles after bundle close)

- **10.E EH spec corpus (Gate 1 / D-192)** — try_table.1.wasm
  imports `test::e0` tag + `test::throw` func from try_table.0.wasm;
  runner registry needs tag + func cross-module binding. New bundle
  at 103+ retarget.
- **10.G WasmGC** — corpus baked (568 directives) but impl=0%; ZIR
  ops + heap impl + subtype lattice all still in scope.
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-100)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass) exception=4(fail4)
[function-references] return=39(fail33) trap=4(fail4) invalid=18(pass) ParseFailed=7 (was 10 pre-cycle-100)
[gc                 ] return=407(fail) trap=100(fail) invalid=60(pass=55 fail=5) malformed=1(pass)
[multi-memory       ] return=407(pass=371 fail=36) trap=238(pass=237 fail=1)
```

## Open questions / blockers

- ADR-0120 / ADR-0123: Accepted; impl autonomous.
- D-192: cross-module register substrate. Cycles 103+ open new
  bundle when 10.R-funcrefs-tail closes.
- D-186 (return_call_ref): discharge predicate met by ADR-0123 D4 +
  Gate 3 (opRefFunc non-null) once cycle 101 lands.

## Key refs

- ADR-0120 (Accepted — EH payload), ADR-0123 (Accepted — typed-ref).
- `.dev/lessons/2026-05-28-funcrefs-tail-error-classes.md` (cycle 95
  diagnostic probe — gate inventory; Gate 4 closed cycle 100).
- `.dev/lessons/2026-05-28-yield-taper-pacing.md` (0-delta-cycle
  detection that triggered the cycle-99 pivot).
- ROADMAP §10; `.dev/phase_log/phase10.md`.
