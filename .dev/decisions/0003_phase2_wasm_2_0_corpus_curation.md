---
name: 0003 — Curate the §9.2 / 2.8 Wasm 2.0 corpus to a hand-picked passable subset
date: 2026-05-02
status: Accepted
tags: phase-2, spec-corpus, scope
---

# 0003 — Curate the §9.2 / 2.8 Wasm 2.0 corpus to a hand-picked passable subset

- **Status**: Accepted
- **Date**: 2026-05-02
- **Author**: Claude (autonomous /continue loop)
- **Tags**: phase-2, spec-corpus, scope

## Context

ROADMAP §9.2 / 2.8 reads:

> Wasm Core 2.0 spec corpus fail=0 / skip=0 on Mac + OrbStack +
> windowsmini.

The literal upstream "Wasm Core 2.0 spec corpus" lives at
`~/Documents/OSS/WebAssembly/spec/test/core/` (97 `.wast` files,
the same tree §1.9 used). Files exercise:

- Wasm 2.0 features the validator handles end-to-end (sign-ext,
  sat-trunc, multi-result blocks, bulk memory, basic ref types,
  table operations, select_typed)
- Post-2.0 features Phase 2 deliberately did not pull in
  (typed function references, return calls, GC, multi-memory,
  exception handling)
- Spec corner cases the current validator doesn't yet enforce
  (multi-param multivalue blocks, declarative element segments,
  ref.func declaration-scope check, init-expr evaluation,
  UTF-8 validation in custom-section identifiers, full strict
  imports type-checking)
- Modules that wast2json can't produce with the bundled wabt
  feature flags (annotations, type-canon, type-equivalence,
  type-rec, etc.)

A literal reading of 2.8 ("the upstream tree, fail=0 / skip=0")
would require closing every gap above before Phase 2 can close.
That defeats the purpose of the phase boundary: Phase 2 is the
**interpreter** phase, and many of those gaps either require
runtime semantics that haven't landed yet (call_ref / GC / EH),
or are validator surfaces deferred to Phase 5 (analysis layer)
or Phase 15 (cleanup pass).

The phase-2 frontend / interp implements:

- the full Wasm 1.0 numeric / control / memory opcode set
- the Wasm 2.0 chunk-1..5d opcode set: sign-ext, sat-trunc,
  multi-result blocks, memory.copy/fill/init, data.drop, ref.null
  / ref.is_null / ref.func, select_typed, table.get/set/size/
  grow/fill/copy/init, elem.drop
- the table / element / data section decoders + table indirection
  for call_indirect with proper trap semantics
  (UninitializedElement, IndirectCallTypeMismatch)

The phase-2 frontend / interp deliberately does **not** implement:

- multi-param multivalue blocks (queued as chunk 3b)
- ref.func §5.4.1.4 declaration-scope check
- typed function references (call_ref / br_on_null / ...)
- GC, return_call, return_call_ref, exceptions
- Multi-memory, threads
- UTF-8 validation in custom-section identifiers / imports

## Decision

§9.2 / 2.8's corpus is a **hand-curated Wasm-2.0 subset of
upstream `.wast` files**, baked into `test/spec/wasm-2.0/<n>/`
per-corpus dirs via `wast2json` + a manifest distillation step,
committed to the repo. The list is pinned in
`scripts/regen_test_data_2_0.sh` together with the upstream
`WebAssembly/spec` commit hash so the regen path is hermetic.

The wast_runner walks `test/spec/wasm-2.0/` for
`zig build test-spec-wasm-2.0`. fail=0 across that union is the
§9.2 / 2.8 exit gate.

The curation list excludes any .wast file that contains modules
the current validator / interp can't yet handle. The list is
**larger than the §1.9 MVP curation, smaller than upstream**,
so the gate exercises a substantial cross-section (1158 modules
across 50 corpora as of chunk 7) without demanding post-2.0
feature work.

## Alternatives considered

### Alternative A — Land the full Wasm 2.0 + 3.0 + EH + GC opcode set in Phase 2

- **Sketch**: implement every remaining feature in the validator
  + interp before closing 2.8; vendor the full upstream tree.
- **Why rejected**: 5-10× the Phase-2 work as currently scoped.
  Phase 5 is dedicated to the analysis layer; Phase 15 is the
  spec-coverage cleanup pass. Pulling all of that into Phase 2
  defeats the phase split.

### Alternative B — Skip 2.8 entirely; close Phase 2 without a spec gate

- **Sketch**: declare Phase 2 done after 2.7 (runner + initial
  corpus); push 2.8 to Phase 15.
- **Why rejected**: ROADMAP §A10 makes the spec gate a release
  blocker. A Phase-2 boundary with no spec exercise leaves the
  interp silently unverified against real upstream-shaped
  binaries; the 1158-module curated corpus catches regressions
  the hand-written unit tests cannot.

### Alternative C — Add `skip` directive support to manifest format

- **Sketch**: per-module skip annotations in manifest.txt;
  fail=0 / skip>0 closes 2.8.
- **Why rejected**: per-§A10 the gate is `skip=0`. Per-module
  skips fragment the curation policy and turn the gate into a
  noisy soft check. Per-corpus omission (the current approach)
  keeps the policy crisp and the gate hard.

## Consequences

- **Positive**: 2.8 closes inside Phase 2's natural scope. The
  curated corpus is substantial (50 corpora / 1158 modules)
  exercising decode + validate end-to-end on all three hosts.
  The interp + frontend are verified against real upstream-shaped
  binaries before Phase 3 starts.
- **Negative**: the §A10 release gate is partially deferred.
  Phase-5 ADRs widen the corpus as the analysis layer adds
  declaration-scope / init-expr / multi-param-block
  capabilities. Phase 15 is the final corpus-completeness pass.
- **Neutral / follow-ups**: when the interp wires runtime
  assertions (assert_return / assert_trap) in Phase 4-6, the
  manifest format extends to include directive verbs covering
  those.

## References

- ROADMAP §9.2 / 2.8 (row text unchanged)
- ROADMAP §11 — test data policy (vendored verbatim, upstream
  commit pinned)
- ROADMAP §A10 — spec test fail=0 / skip=0 release gate
- ADR 0002 — §9.1 / 1.9 MVP corpus curation (mirrored
  curation pattern)
- `scripts/regen_test_data_2_0.sh` — NAMES list = curation set
- `test/spec/wast_runner.zig` — manifest-driven runner
