# Phase 10 spec-corpus expansion: ADR-independent candidates exhausted

**Date**: 2026-05-28
**Cycle**: 10.TC cycle 88 survey
**Citing**: (handover retarget commit; spec runner observable unchanged)

## What was tried

Cycle-88 candidate (1) per cycle-87 handover: "Function-references /
10.R spec corpus extension — survey whether any ADR-0123-independent
.wast modules remain un-baked in the upstream `function-references/`
corpus."

## What was learned

**No autonomous corpus-expansion candidates remain** across any of
the §10 corpora (function-references / multi-memory / tail-call /
exception-handling / wasm 1.0 / wasm 2.0 / GC).

### Per-corpus survey

**function-references** (8 modules baked; corpus state =
`return=39(pass=3 fail=36) trap=4(fail4) invalid=18(pass=18)`):

- Currently baked: `br_on_non_null`, `br_on_null`, `ref`,
  `ref_as_non_null`, `ref_func`, `ref_is_null`, `ref_null`, `raw/`.
- Upstream function-references-specific .wast modules NOT baked:
  `call_ref.wast`, `return_call_ref.wast`, `type-equivalence.wast`.
- All 3 bake successfully under wast2json `--enable-all`. **BUT**
  the resulting .wasm modules use typed-funcref bytes `0x63` / `0x64`
  in their type sections, which the v2 parser rejects under
  ValType (D-195 sub-gap a; ADR-0123 Proposed). Baking would add
  ~10 more `ParseFailed`-class fails to the runner output, not
  progress.
- The remaining upstream .wast files (`block.wast`, `br.wast`, etc.)
  are general-core tests duplicated across proposal directories;
  baking them under function-references provides no extra signal
  over the wasm-2.0-assert coverage that already passes them.

**wasm-2.0-assert** (84 modules baked):

Comprehensive coverage of the upstream wasm-2.0 spec testsuite.
Spot-check against `~/Documents/OSS/WebAssembly/testsuite/*.wast`:
no obvious gap. Pass-rate already at `assert_return pass=790
assert_trap pass=449 assert_invalid pass=134`.

**wasm-1.0-assert** (11 modules; mostly handcrafted):

Limited intentionally — `forward/`, `int_literals/`, `local_get/`,
`local_set/`, `unreachable/` are upstream ports; the 6
`handcrafted_*/` dirs are zwasm-authored. Expanding to upstream
parity would duplicate wasm-2.0-assert (Wasm 1.0 ⊂ 2.0 at semantics
level); the wasm-1.0-assert harness's value is the **1.0-only
validator path** which rejects 2.0 features — handcrafted fixtures
suffice for that.

**multi-memory** / **tail-call**: see §10 phase log; both at
maximum autonomous coverage (37 + 5 manifests, all pass except the
named cross-module-register gaps tracked in D-192 / D-196).

**exception-handling**: 1 manifest baked (try_table). Expansion
gated on ADR-0120 Accept (exnref ValType).

**GC**: 0 manifests baked. Gated on D-179 (wabt 1.0.41+).

## Why we tried

Cycle-87 handover named function-references corpus extension as
the highest-yield cycle-88 candidate. The expectation was that
**some** function-references-specific .wast might be ADR-
independent. The survey refuted that.

## How to apply

The forward edge of §10's autonomous yield is **provably
exhausted within the ADR-independent envelope**. Remaining work
is structurally gated:

- **ADR-0120** Accept flip → unblocks ~30 EH spec directives +
  exnref ValType.
- **ADR-0123** Accept flip → unblocks call_ref / return_call_ref
  / typed-funcref parser + the 3 remaining function-references
  modules above + the 36 currently-failing function-references
  return directives.
- **D-179** wabt 1.0.41+ → unblocks GC corpus baking +
  `clang_wasm64` realworld.

Until one of those flips, /continue's autonomous candidates are
limited to **infrastructure / bookkeeping / audit** cycles
(cycle-82 audit-cohort follow-through covers most of these
through cycle 87).

Future surveys should grep this lesson before re-running the
function-references bake-extension exercise.

## Related

- D-179, D-192, D-195, D-196 (debt rows tracking the four gates)
- ADR-0120, ADR-0123 (Proposed; user touchpoints)
- ROADMAP §10 row 10.R / 10.E / 10.G
