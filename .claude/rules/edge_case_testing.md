---
paths:
  - "src/**/*.zig"
  - "test/**/*.zig"
  - "test/edge_cases/**"
---

# Edge-case test culture: 気付いたら即追加

Auto-loaded when editing Zig source or test fixtures. Codifies
the discipline established by ADR-0020: whenever code touches a
semantic boundary (numeric edge, special FP value, off-by-one,
spec-defined trap condition, etc.), **the boundary fixture is
added in the same commit** unless one already exists.

## Why

Two failure modes the project must avoid:

1. **Boundary regressions hide in aggregate spec-test counts.**
   The wasm-1.0 + wasm-2.0 testsuites cover most boundaries
   generically, but they don't exercise zwasm-specific
   implementation choices (e.g. our particular FP-bound
   constants in sub-h3a/3b). When an internal refactor regresses
   a boundary, generic spec tests may pass with the regression
   silent.
2. **Optimisation phases (Phase 8 + Phase 15) need a safety
   net.** Every refactor either keeps the boundary fixture green
   or fails it loudly. Without a fixture, the regression
   surfaces only when a downstream system breaks.

## The 気付いたら即追加 trigger

While editing code, you cross a "boundary" when any of:

- Encoding a numeric op handler that has IEEE-754 corner cases
  (NaN, +Inf, -Inf, ±0, denormal, exact-integer FP edge).
- Implementing or modifying a comparison whose strictness
  matters (e.g. `<` vs `<=`, signed vs unsigned vs ordered).
- Touching a spec-defined trap condition (memory bounds, table
  bounds, sig mismatch, integer overflow on trapping ops).
- Adding a new ZIR op or modifying an existing op's semantics
  (especially Wasm 2.0+ proposals where edge cases are subtle).
- Refactoring a regalloc / spill / ABI invariant whose violation
  is silent at the type system but crashes at runtime.

When you cross a boundary AND no existing fixture covers it:
**add a fixture in the same commit**. Don't defer.

## Where fixtures live

```
test/edge_cases/p<N>/<concept>/<case>.wat       ← source (WAT)
test/edge_cases/p<N>/<concept>/<case>.wasm      ← compiled artifact
test/edge_cases/p<N>/<concept>/<case>.expect    ← expected outputs
```

`<N>` = phase number where the boundary was first encountered.
`<concept>` = the op group or feature (e.g. `trunc_f32_s`,
`call_indirect_sig`, `memory_bounds`). `<case>` = a short slug
(e.g. `at_int_min`, `nan_input`, `idx_eq_size_minus_one`).

A fixture's WAT file SHOULD lead with a comment block citing
provenance (spec testsuite + assertion line, or "internally
derived from sub-X.Y boundary at commit `<sha>`"). Provenance
makes future maintainers' lives easier.

## What goes in `.expect`

For trap-expecting cases:
```
trap: <reason>
```
where `<reason>` is one of the canonical Wasm trap reasons
(integer overflow, integer divide by zero, invalid conversion to
integer, out of bounds memory access, undefined element,
indirect call signature mismatch, etc.).

For value-returning cases (one line per result):
```
i32: <decimal>
i64: <decimal>
f32: <hex bits>
f64: <hex bits>
```

The runner harness parses `.expect` and asserts equality. WAT
fixtures + `.expect` give a complete spec; the runner is
mechanical.

## Extraction patterns

### From spec testsuite

The wasm-1.0 / wasm-2.0 spec `.wast` files are dense; extracting
a single boundary requires:

1. Cite the original `.wast` + assertion line range in the WAT
   comment.
2. Trim to the **minimal** Wasm module exhibiting the boundary
   (single function, single op, single assertion).
3. Convert assertion to `.expect` format.

### From wasmtime-misc / realworld

Same pattern; provenance comment names the fixture's source.

### Internally derived

When sub-X.Y's implementation choice surfaces a boundary not
present in upstream corpora (e.g. our specific
`Slot.spill` allocation strategy), the WAT comment cites the
commit + ADR.

## Reviewer checklist

When reviewing code that touches a semantic boundary:

- [ ] Did the diff add a fixture under `test/edge_cases/p<N>/`?
- [ ] If no fixture, is it because one already exists? Cite
      the existing fixture path.
- [ ] If no fixture and no existing one: was the omission
      deliberate? Document in `private/notes/p<N>-edge-case
      -rationale.md` (gitignored — surface only as feedback).

## When NOT to add a fixture

Boundary fixtures are not for:

- **Type-system-enforced invariants** — Zig's `comptime` checks
  catch these at build; a runtime fixture adds noise.
- **Trivially-mechanical encodings** — if the encoding has been
  clang-verified + otool-inspected, that's already proof.
- **Implementation details that aren't observable from Wasm**
  — e.g. "the prologue uses MOV X19, X0" is internal; if it
  breaks, the test of an existing function that uses calls
  surfaces the regression.

The rule targets **observable spec-defined boundaries**, not
internal mechanism.

## Anti-patterns

- **"We'll add the fixture later when the runner harness exists."**
  Add the WAT fixture today; the runner wires up later. The
  fixture is the spec; the runner is execution.
- **"This boundary is too obvious to need a fixture."** The
  fixtures' value is regression detection, not initial
  verification. Adding a fixture for an "obvious" boundary
  protects against future re-derivations going wrong.
- **"Just one more boundary; we'll batch them at the next
  audit."** Defeats the trigger's purpose. The same-commit
  discipline matters because Phase boundaries are months apart;
  fixture coverage atrophies during the gap.

## Stale-ness

Fixtures can stale when implementation choices legitimately
change (e.g. a spec proposal updates a trap reason). When that
happens:

1. Update the `.expect` to match the new behavior.
2. Add a comment in the WAT file referencing the spec change.
3. Don't delete the fixture unless the boundary is genuinely
   gone from the spec.

`audit_scaffolding` §I (per ADR-0020) periodically verifies
that each fixture's `.wasm` artifact matches its `.wat` source.
