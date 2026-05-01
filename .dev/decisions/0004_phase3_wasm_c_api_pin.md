---
name: 0004 — Pin upstream wasm-c-api commit for vendored include/wasm.h
date: 2026-05-02
status: Accepted
tags: phase-3, c-api, vendoring
---

# 0004 — Pin upstream wasm-c-api commit for vendored include/wasm.h

- **Status**: Accepted
- **Date**: 2026-05-02
- **Author**: Claude (autonomous /continue loop)
- **Tags**: phase-3, c-api, vendoring

## Context

ROADMAP §9.3 / 3.0 — 3.1 ships `include/wasm.h` from the upstream
[`WebAssembly/wasm-c-api`](https://github.com/WebAssembly/wasm-c-api)
repository as the C ABI surface zwasm v2 implements. ROADMAP §1.1
makes wasm-c-api conformance load-bearing for v0.1.0:

> wasm-c-api conformance: `wasm.h` is the primary C ABI;
> `zwasm.h` extensions are subordinate.

The upstream tree is a single header file (~737 lines) that
defines the engine / store / module / instance / func / vec /
trap shapes the §9.3 build wraps. Upstream is informally
maintained; the file has been near-stable since 2020 but
occasionally takes editorial commits. We need a deterministic
pin so the §9.3 / 3.4 – 3.7 binding work targets a single
upstream snapshot, and so a future ADR is required to bump the
pin (i.e. drift cannot happen by accident).

## Decision

Pin the vendored `include/wasm.h` at upstream commit
`9d6b93764ac96cdd9db51081c363e09d2d488b4d` (current `main` as of
2026-05-02). The pin lives in three places:

1. `scripts/fetch_wasm_c_api.sh` — `WASM_C_API_PIN_DEFAULT`
   constant. The script extracts `include/wasm.h` from this
   commit verbatim, refusing to run if the commit is missing
   from the resolved upstream clone.
2. This ADR — load-bearing record per ROADMAP §18.
3. The vendored `include/wasm.h` itself — its byte-for-byte
   content is the runtime surface.

Bumping the pin requires:

- A new ADR (or a status amendment to this one) summarising
  why the bump is needed (e.g. an upstream fix relevant to
  wasi.h ecosystem semantics; a new wasm.h shape that the
  C-API binding work needs).
- Updating `WASM_C_API_PIN_DEFAULT` in the script.
- Re-running `bash scripts/fetch_wasm_c_api.sh`.
- A single commit landing the new `include/wasm.h` + the ADR
  reference, message
  `chore(p3): bump wasm-c-api pin to <newhash> (ADR-NNNN)`.

The script's `WASM_C_API_PIN` env override exists for the
bump workflow only; CI / local builds run with the default.

## Alternatives considered

### Alternative A — Track upstream `main`

- **Sketch**: fetch `wasm.h` from `main` on each build; no pin.
- **Why rejected**: builds become non-reproducible. An upstream
  commit between two local builds could silently change ABI
  shapes the binding work depends on; this is the exact
  failure mode v1 hit when its early `wasm.h` ingestion drifted
  against a moving upstream.

### Alternative B — Fork + maintain a local tree

- **Sketch**: maintain a `wasm-c-api`-shaped Zig module with
  hand-written shapes that mirror upstream.
- **Why rejected**: violates the "wasm-c-api conformance" goal in
  ROADMAP §1.1 — the moment our local shape drifts from upstream,
  third-party C hosts that target `wasm.h` lose interop. Vendor
  + pin keeps the surface identical to the spec C API.

### Alternative C — Pin via git-submodule

- **Sketch**: add `wasm-c-api` as a submodule; build references
  the submodule's header.
- **Why rejected**: submodules make first-clone friction sharper
  (extra `git submodule update --init` step) and complicate
  windowsmini's `reset --hard` sync path. A vendored single file
  is simpler.

## Consequences

- **Positive**: deterministic ABI surface; an `audit_scaffolding`
  pass can detect drift by comparing `include/wasm.h` against the
  pin via this script. The bump workflow is explicit and
  ADR-gated, so an accidental upstream-tracking change is hard
  to land.
- **Negative**: when upstream changes, we have to do an explicit
  bump; absent updates linger. Mitigated by the quarterly
  `proposal_watch` cadence (extending coverage to wasm-c-api).
- **Neutral / follow-ups**: §9.3 / 3.4 – 3.7 binding work is
  permitted to introduce zwasm-specific helper types in
  `include/zwasm.h` (per ROADMAP §1.1 — "`zwasm.h` extensions
  are subordinate"), but `include/wasm.h` stays byte-for-byte
  upstream.

## References

- ROADMAP §1.1 — wasm-c-api conformance is load-bearing for
  v0.1.0
- ROADMAP §9.3 / 3.0 — script + pin lands here
- ROADMAP §11 — vendor policy (verbatim, upstream commit
  pinned)
- ROADMAP §18 — amendment policy (this ADR + script pin are
  the load-bearing pair)
- `scripts/fetch_wasm_c_api.sh` — the regenerator
- Upstream:
  https://github.com/WebAssembly/wasm-c-api/commit/9d6b93764ac96cdd9db51081c363e09d2d488b4d
