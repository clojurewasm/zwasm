# Beta-style funcref encoding (packed instance_id + funcidx) was originally preferred on aesthetics

- **Date**: 2026-05-04
- **Phase**: Phase 6 / §9.6 / 6.K.3
- **Citing**: ADR-0014 §3.γ; commit `ffc0cf0` (6.K.3 land);
  `private/notes/p6-6K3-lifetime-survey.md` §4

## Context

When designing how `Value.ref` should carry instance identity for
cross-module funcref dispatch (§9.6 / 6.K.1〜6.K.3), three options
were on the table:

- **Alpha** — `*FuncEntity` pointer; failed-instance keep-alive
  via a `Store.zombies` parking lot ("zombie-instance contract").
- **Beta** — packed `(instance_id, funcidx)` u64 with a
  per-store registry resolving instance_id → `*Instance`.
- **Gamma** — Per-instance `funcref_table[]` indirection.

I (Claude) initially preferred **Beta** on aesthetic grounds —
explicit identity, registry-based resolution, no dangling-pointer
class. Alpha looked like "we'll just hold every failed instance
forever, what could go wrong".

## What changed my mind

Step 0 textbook survey of wasmtime + wazero + the WebAssembly
spec interpreter (`private/notes/p6-6K3-lifetime-survey.md`):

- **wasmtime** — uses `*FuncEntity`-equivalent pointer encoding;
  failed-instance keep-alive via Store ownership of all instances
  (zombie semantics).
- **wazero** — same shape; failed instances are retained by the
  store until store close.
- **Spec interpreter** — uses a host pointer; the spec text doesn't
  specify failure-cleanup at all, leaving it to the embedder.

In other words: 10 years of production wasm runtimes converged on
Alpha **with full awareness** of the dangling-pointer class. The
failure-keep-alive cost is real but bounded (one zombie per failed
instantiation, freed at store close); the alternative (Beta) adds
a registry hot-path on every cross-module call AND doesn't solve
the actual problem (partial-init slot inside a successful
instance).

A spike on Beta in this cycle confirmed the dispatch-path complexity
projection: Beta required a 2-level lookup on every cross-module
call vs Alpha's single pointer deref. The packing aesthetic
disappears when the dispatch hot path doubles.

## Lesson

When zwasm v2 sits between two design choices and one of them
**looks cleaner** while the other is what every mature wasm runtime
does — the cleaner-looking one usually has implicit costs that 10
years of production has paid for elsewhere. Step 0 textbook survey
is specifically designed to surface those costs before we re-pay
them; trust the survey output over the aesthetic preference.

## Re-derivable from

- ADR-0014 §3.γ "Beta — packed (instance_id, funcidx) — Rejected"
- Commit `ffc0cf0` body
- `private/notes/p6-6K3-lifetime-survey.md` §4 (cross-reference)
