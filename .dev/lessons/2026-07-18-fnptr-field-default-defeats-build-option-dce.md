# A fn-pointer struct-field DEFAULT takes the helper's address unconditionally — defeating build-option DCE

- **Date**: 2026-07-18
- **Area**: engine/codegen/shared/jit_abi.zig; build-option DCE (ADR-0073 / ADR-0203 D1)
- **Trigger**: `main` CI `check_build_dce` FAIL — `instruction.wasm_3_0.ref_test_ops.gcRefMatchesNonNullCore`
  present in every `-Dwasm=v1_0` and `-Dwasm=v2_0` binary (all 6 rows).

## Observation

ADR-0203 D1 (D-516, position-independence) added GC / subtyping JIT
helpers as `JitRuntime` fn-pointer FIELDS with the real helper as the
field DEFAULT (so a reloaded `.cwasm` resolves the address in the
running process — no setup wiring):

```zig
gc_ref_test_fn: *const fn (...) callconv(.c) u32 = jitGcRefTest,
```

A field default `= jitGcRefTest` takes the helper's ADDRESS, and
`JitRuntime` is instantiated in every build. So `jitGcRefTest` (and its
callee `gcRefMatchesNonNullCore`, plus the whole `feature/gc/*` reach of
`jitGcAlloc`/`jitGcArray*`/`jitCallIndirectResolve`) stayed live even in a
v1_0 build. Only the one symbol whose namespace path contains `wasm_3_0`
tripped `check_build_dce`'s `nm`-grep, but the entire GC cohort leaked.

The regression shipped 2026-07-09 (ADR-0203) yet surfaced only 2026-07-17:
`check_build_dce` runs in the push-to-main EXTENDED leg, and every
intervening main push was doc-only (heavy legs auto-skipped) or
concurrency-cancelled — so the gate never actually completed until #149.

## Why (re-derivable)

The emit sites read the helper via `@offsetOf(JitRuntime, "..._fn")`
(`call_indirect_resolve_fn_off`) — an OFFSET, not an address — and are
themselves comptime-fenced behind the wasm_3_0 op dispatch, so they DCE
fine. The *only* always-live address-taker is the struct field default.
`if (comptime false) { ... }` blocks are never analysed for codegen, so a
comptime build-level guard as the first statement makes the helper a bare
`@panic` stub in sub-v3 builds — its GC references vanish and DCE reclaims
them. v3 builds are unaffected (`wasm_v3_plus` comptime-true → guard is
`if (comptime false)` → real body runs; ADR-0203 D1 intact). Sub-v3 builds
can never emit a GC / subtyping op (the validator rejects them), so the
stub is unreachable — `@panic` is the correct default (mirrors
`defaultReifyExnref`).

## Rule

- Before giving a `*const fn` struct FIELD a real-helper DEFAULT, check
  whether that helper (transitively) reaches build-option-gated code
  (`feature/gc/*`, `instruction/wasm_3_0/*`, SIMD, WASI-P2/P3). If so, the
  default is an unconditional address-take that defeats DCE — guard the
  helper body with `if (comptime !wasm_v3_plus) @panic(...)` (or the
  matching feature axis) so the sub-level default is a reference-free stub.
- A pattern-based DCE gate (`nm | grep`) only flags the callee whose SYMBOL
  NAME matches; the real leak can be a whole cohort. After a fix, `nm`-grep
  the WHOLE `feature/*` reach, not just the flagged pattern.
- A gate that runs only on push-to-main extended can stay silently broken
  across a run of doc-only / cancelled pushes. `[x]`-flip and doc PRs are
  exactly when a codegen regression hides.
