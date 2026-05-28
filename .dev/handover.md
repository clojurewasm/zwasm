# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 95 (`7fbb833c`) — diagnostic probe of 10
  remaining ParseFailed function-refs modules. Lesson
  `2026-05-28-funcrefs-tail-error-classes.md` captures the
  error class inventory (BadBlockType×3, BadValType×1,
  StackTypeMismatch×4, StackUnderflow×1, NotImplemented×3,
  UndeclaredFuncRef×?). Highest-yield fix: subtype-aware
  popExpect (cycle-93 carve-out) addresses 5/12.
- Cycles 91-94 before: ValType pivot to union(enum); parser
  typed-funcref bytes; validator narrowing; bundle 10.R-
  valtype-widen partial-closed at `2f127b96`.
- Cycle 90 (`6e5e7e53` + `510eca36` + `d6b187f8`) before that:
  D-179 baker swap; ADR-0120 Accept + Cycle 1 impl; ADR-0123 Accept
  + Cycle 1 substrate.
- Mac aarch64 test-all + lint green.

## Active bundle

- **Bundle-ID**: 10.R-funcrefs-tail (follow-up to closed
  10.R-valtype-widen; opens at cycle 94 with the structural
  pivot already done).
- **Cycles-remaining**: ~3-5
- **Continuity-memo**: Bundle 10.R-valtype-widen partial-closed
  at `2f127b96`: ValType union(enum); parser typed-funcref bytes;
  validator narrowing on ref.as_non_null + br_on_null; opRefNull
  + lower 0xD0 extended; br_on_null opcode fixed (0xD4→0xD5).
  Gap inventory: 10 function-references modules still ParseFailed
  (br_on_null.0/2, br_on_non_null.0/1/2, ref_as_non_null.0/2,
  ref_is_null.0). Probable causes: more opcode-byte mismatches
  in lower/validator dispatch OR validator type-stack
  interactions. Plus subtype-aware popExpect carve-out from
  cycle 93 (needed for opRefFunc non-null + opBrOnNonNull
  label match).
- **Exit-condition**: function-references return ≥ 30/39 pass
  (currently 0/39 — modules parse but exec path also incomplete).
- **Exit-condition**: function-references spec corpus assert_return
  pass-rate ≥ 30/39 (currently 3/39); call_ref + return_call_ref
  green-baked + validated; 0 ParseFailed for any
  function-references module.

## Active task — cycle 96: subtype-aware popExpect (Cycle 2 of bundle)

Per cycle-95 lesson `2026-05-28-funcrefs-tail-error-classes.md`:
add `popSubtype(expected)` helper in `src/validate/validator.zig`
that accepts `(ref ht)` where `(ref null ht)` is expected (Wasm
3.0 §3.3.4 subtype rules). Migrate the 5+ call sites in
`opRefAsNonNull` / `opBrOnNull` / `opCallRef` / `opReturnCallRef`
/ `popExpect` general path from `.eql`-strict to subtype-aware.

Smallest red test: `test "validator: pop (ref ht) where (ref null
ht) expected succeeds via subtype rule"`.

Expected delta: 5/12 of the remaining function-references
failures clear (4× StackTypeMismatch + 1× StackUnderflow). Bundle
exit-condition advances toward ≥30/39 pass.

After cycle 96 lands, cycles 97+ per lesson:
- Block result typed-ref handling (BadBlockType ×3)
- BadValType non-patched site probe (×1)
- NotImplemented opcode identification (×3)
- UndeclaredFuncRef case-by-case (judgment)

## Larger §10 work (post-bundle)

- **10.E EH payload-prop bundle** (ADR-0120 Cycles 2-5): throw.emit
  pop+STR; try_table.emit catch landing-pad LDR+push; catch_ref
  reification helper; spec corpus runner wiring. ~30 EH directives
  flip to pass.
- **10.G WasmGC ZIR ops** — D-179 unblocked at the bake layer;
  impl distance is large (ZIR op set + heap impl + subtype lattice
  reuse ADR-0123 RefType shape).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-90 baker swap)

```
[memory64           ] return=337(all pass) trap=205(all pass) invalid=83
[tail-call          ] return=71  trap=7    invalid=24(pass=23 fail=1)
[exception-handling ] return=34(fail) trap=2(fail) invalid=7(pass) exception=4(fail)
[function-references] return=39(fail36) trap=4(fail4) invalid=18(pass=18 fail=0)
[gc                 ] return=407(fail=384) trap=100(fail=100) invalid=60(pass) malformed=1(pass)  ← NEW
[multi-memory       ] return=407(pass=371 fail=36) trap=238(pass=237 fail=1) invalid=2 malformed=2 skip=56
[wasm-3.0-assert] total: 71 manifests, 2349 directives
```

## Open questions / blockers

- ADR-0120 / ADR-0123 — both Accepted; impl bundles autonomous.
- D-179 — DISCHARGED.
- D-186 — discharge path unblocked by ADR-0123 D4; awaits cycle 5
  of 10.R-valtype-widen bundle.
- D-195 (function-references corpus gates) — sub-gap (a) unblocked
  by ADR-0123 Cycle 3; sub-gap (b) cross-module register remains.
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0120 (Accepted — EH payload), ADR-0123 (Accepted — typed-ref).
- `.dev/lessons/2026-05-28-spec-corpus-expansion-exhausted.md`
  (cycle-88 survey that surfaced these gates).
- ROADMAP §10; `.dev/phase_log/phase10.md`.
