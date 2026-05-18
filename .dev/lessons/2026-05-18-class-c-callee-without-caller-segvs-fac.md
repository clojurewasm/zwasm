# Class C callee-only landing SEGVs fac/fac.0.wasm via internal helper func[6]

**Citing**: `<backfill>` (revert / re-scope commit)

## Trigger

Implementing ADR-0069 §Phase 2 chunk (b)-e-1 (arm64 callee
prologue X8 capture + epilogue `*(X8 + i*8)` write) as a
standalone chunk — without the paired chunk (b)-e-2
(caller-side buffer allocate + LEA into X8 before BL) —
deterministically SEGVs the spec_assert runner after
processing `fac/fac.0.wasm`.

## Discovery

`fac.0.wasm` was assumed (by mental survey of the manifest's
exported function list) to contain only single-result
functions: `fac-rec`, `fac-iter`, `fac-rec-named`,
`fac-iter-named`, `fac-opt`, `fac-ssa` — each `(i64) → i64`.

`wasm-objdump -x` shows the module actually has **8**
functions, not 6. Two are non-exported helpers used by
`fac-ssa`:

```
 - func[5] sig=1   ; (i64) -> (i64, i64)
 - func[6] sig=2   ; (i64, i64) -> (i64, i64, i64)
```

`func[6]` returns 3 × i64 = 24 B, past the 16-byte
register-pair budget → MEMORY-class per AAPCS64 §6.8.2.

## Failure mode

The callee-only (b)-e-1 landing modifies `func[6]`'s
prologue to `STR X8, [SP, #slot]` and its epilogue to load
that slot into X16 and write each result via `STR Xn, [X16,
#(i*8)]`. But the JIT-to-JIT caller (`fac-ssa` calling
`func[6]` via the `call` op) emits a normal AAPCS64 BL with
**no X8 setup** — the caller-side allocate / LEA chunk
((b)-e-2) was scheduled separately.

At runtime:
1. `fac-ssa` reaches its `call $func6` instruction.
2. JIT emits `BL func6`. X8 is whatever value it had on
   function entry (uninitialised garbage from the Zig→JIT
   entry frame).
3. `func6`'s prologue stores that garbage to `[SP, #slot]`.
4. `func6`'s epilogue loads garbage back into X16 and
   attempts `STR Xn, [X16, #0]` — fault on the garbage
   address.
5. SEGV. The `γ-4 DIAG` handler reads `last_module_name`,
   reports "after .module fac/fac.0.wasm" (the current
   module).

## Reproducer

A `[D-146 probe]` instrumentation in `op_control.zig::
marshalFunctionReturn`'s MEMORY-class branch (now reverted)
showed a single hit during fac processing with
`func_idx=6 results.len=3` immediately before the SEGV.
Removing the prologue STR X8 + epilogue indirect writes
made fac.0.wasm green again.

## Why mental-survey missed it

The spec corpus is curated to skip multi-result assertions
(`skip-impl multi-result <field>`), so the manifest text
doesn't surface that the *module* internally uses
multi-result helpers. Module-level `wasm-objdump -x` does;
the manifest-level survey does not.

## Discipline / discharge plan

(b)-e-1 and (b)-e-2 (arm64 callee + caller side) MUST land
**together** — landing the callee without the caller is
forbidden by the no-half-finished-implementations rule and
empirically regresses spec_assert on Mac aarch64. The
ADR-0069 §Phase 2 chunk plan splits them for review
clarity, but operationally they're a single
behaviour-preserving unit.

When the bundled chunk lands:
- `op_call.emitCall` (arm64) classifies callee's return
  signature; if MEMORY-class, allocates an N×8-byte slot in
  the outgoing-args region, LEAs `&slot` into X8, emits
  `BL`, reads back from the slot into result vregs.
- The classification must be SYMMETRIC with the callee
  side (`func.sig.results.len > 2` — both sides agree).
- `call_indirect` follows the same logic, but the callee
  signature is determined by the indirect-call type.

Same constraint applies to x86_64 (b)-e-3 vs callee side.

## Related

- ADR-0017 amendment (2026-05-18) — documents the MEMORY-
  class prologue slot design; preserved as forward-looking
  spec for the bundled landing.
- ADR-0069 §Phase 2 — chunked plan that originally split
  (b)-e-1 and (b)-e-2; this lesson clarifies why bundling
  is mandatory in practice.
- `.claude/rules/bug_fix_survey.md` — module-level dump
  beats manifest-level inspection for "what does this
  fixture exercise".
- `.dev/lessons/2026-05-10-fn-end-vs-return-parallel-handlers.md`
  — same family of "must-land-together to keep gate green"
  discipline.
