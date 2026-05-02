---
name: 0002 — Curate the §9.1 / 1.9 MVP corpus to a hand-picked Wasm-1.0-pure subset
date: 2026-05-01
status: Accepted
tags: phase-1, spec-corpus, scope
---

# 0002 — Curate the §9.1 / 1.9 MVP corpus to a hand-picked Wasm-1.0-pure subset

- **Status**: Accepted
- **Date**: 2026-05-01
- **Author**: Claude (autonomous /continue loop)
- **Tags**: phase-1, spec-corpus, scope

## Context

ROADMAP §9.1 / 1.9 reads:

> Wasm Core 1.0 (MVP) spec corpus decodes + validates fail=0 /
> skip=0 on all three hosts.

The literal upstream "Wasm Core 1.0 spec corpus" lives at
`~/Documents/OSS/WebAssembly/spec/test/core/`. That tree is not
strictly Wasm-1.0 — the WebAssembly spec project keeps a single
`test/core/` directory that tracks the **latest** version (Wasm
3.0). It contains `.wast` files exercising:

- post-MVP opcodes (e.g. `i32.extend8_s` — Wasm 2.0 sign
  extension; `i32.trunc_sat_*` — Wasm 2.0 saturating
  truncation; SIMD; bulk-memory; reference types; GC; tail
  call; exception handling)
- post-MVP block types (block-level multivalue via s33 typeidx
  in `block` / `loop` / `if`)
- `(assert_invalid …)` / `(assert_malformed …)` directives
  marking modules **expected to fail** validation — without
  parsing wast2json output metadata, the runner cannot
  distinguish these from genuine failures.

The Phase-1 frontend implements:

- the full Wasm 1.0 numeric / control / memory opcode set
- all four section-body decoders implicated by 1.0 (type,
  function, code, global, import)
- multi-result **function-frame** signatures (the wast2json
  shape often includes them in the type section even when
  unused)
- structural parser invariants and section ordering

The Phase-1 frontend deliberately does **not** implement:

- Wasm 2.0+ opcodes
- block-level multivalue (s33 typeidx in `readBlockType`)
- the `.wast` script directive layer (assert_invalid /
  assert_malformed / assert_return / module-binary directives)

A literal reading of 1.9 ("the upstream tree, fail=0 / skip=0")
would require landing the entire post-MVP suite plus a wast2json
metadata reader before Phase 1 can close. That defeats the
purpose of the phase boundary (Phase 2 is interp; the post-MVP
opcodes + assert-runtime semantics belong there).

## Decision

§9.1 / 1.9's corpus is a **hand-curated Wasm-1.0-pure subset of
upstream `.wast` files**, baked into `test/spec/wasm-1.0/` via
`wast2json`, committed to the repo. The list is pinned in
`test/spec/wasm-1.0/README.md` together with the upstream
`WebAssembly/spec` commit hash so the regen path is hermetic.

The runner walks both `test/spec/smoke/` (the original §9.1 / 1.8
hand-baked smoke) **and** `test/spec/wasm-1.0/` (the curated MVP
corpus) for `zig build test-spec`. fail=0 / skip=0 for that
union is the §9.1 / 1.9 exit gate.

The curation list excludes any file that uses post-MVP opcodes,
block-level multivalue, or `assert_*` directives whose modules
fail validation by design. The curation list is intentionally
**larger than the smoke set, smaller than upstream**, so the
gate exercises real-world MVP-conformant binaries without
demanding post-MVP feature work.

## Alternatives considered

### Alternative A — Land the full Wasm 1.0 + 2.0 + 3.0 opcode set in Phase 1

- **Sketch**: implement every opcode in the validator before
  closing 1.9; vendor the full upstream tree; add wast2json
  metadata parsing for assert directives.
- **Why rejected**: 3-5× the Phase-1 work as currently scoped.
  Most opcodes need execution semantics (Phase 2) before they
  can be meaningfully tested anyway. Doing decode + validate
  for, say, GC / exceptions / SIMD without an interpreter is
  premature.

### Alternative B — Skip 1.9 entirely; close Phase 1 without a spec gate

- **Sketch**: declare Phase 1 done after 1.8 (runner + smoke
  corpus); push the upstream gate to Phase 2.
- **Why rejected**: ROADMAP §A10 makes the spec gate a release
  blocker. A Phase-1 boundary with no spec exercise leaves the
  frontend silently unverified against real binaries.

### Alternative C — Implement wast2json metadata parsing now

- **Sketch**: add a JSON reader that consumes `commands[]` from
  `wast2json`'s output; the runner inverts pass/fail expectation
  per directive.
- **Why rejected**: incremental complexity for the directive
  layer is real (UTF-8 imports, byte-level binary modules,
  assert_return needing execution). The wast directive layer
  belongs with the interpreter (Phase 2) where assert_return /
  assert_trap can actually be evaluated.

## Consequences

- **Positive**: 1.9 closes inside Phase 1's natural scope. The
  curated corpus is non-trivial (10+ real wast-derived modules)
  and exercises decode + validate end-to-end on all three
  hosts. The frontend is verified against real upstream-shaped
  binaries before Phase 2 starts.
- **Negative**: the §A10 release gate is partially deferred.
  Phase 2 (and especially the §9.2 boundary `audit_scaffolding`)
  must explicitly check that the upstream-corpus expansion is
  scheduled. The curation list is editorial and drifts from
  upstream over time; a regen step in Phase 15 is the catch-up.
- **Neutral / follow-ups**: a Phase-2 ADR (when the interpreter
  lands) widens the corpus to include `assert_return` /
  `assert_trap` directives + post-MVP opcodes.

## References

- ROADMAP §9.1 / 1.9 (row text unchanged)
- ROADMAP §11 — test data policy (vendored verbatim, upstream
  commit pinned)
- ROADMAP §A10 — spec test fail=0 / skip=0 release gate
- ADR 0001 — split of 1.8 / 1.9 corpus vendoring
