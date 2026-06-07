# 0173 — `Caller.data` host-context seam for `Linker` host fns

- **Status**: Accepted 2026-06-07
- **Date**: 2026-06-07
- **Author**: claude (autonomous loop, CM campaign chunk D1-2)
- **Extends**: ADR-0109 (Native Zig API: Engine + Linker + TypedFunc) §3.2

## Context

`Linker.defineFunc` (ADR-0109 §3.2) registers a host fn as a bare
`*const Sig` whose only execution context is `*Caller` — which, before
this ADR, exposed just the *importing instance's* runtime (guest memory
+ allocator). That is enough for self-contained host fns, but the WASI
Preview 2 → P1 trampolines (CM campaign chunk D1-2) need **host-side**
state that does not live in the guest runtime: the `wasi.Host` (fd
table + stdout capture) and a per-run output-stream `ResourceTable`
(handle → fd). There was no way to thread that into a `defineFunc` host
fn — the comptime marshaler dropped any ctx pointer.

The D1-2 bundle memo assumed `defineFunc` would suffice; it does not.

## Decision

Add a host-context seam mirroring wasmtime's `Caller::data`:

- `Caller` gains `host_data: ?*anyopaque` + `fn data(comptime T) *T`.
- `Linker.defineFuncCtx(module, name, host_data, Sig, user_fn)` registers
  a host fn AND an opaque ctx; the marshaler threads `host_data` into the
  `Caller` it builds per call. `defineFunc` is unchanged (ctx = null) —
  both now route through a shared private `defineFuncImpl`.
- `host_data` lifetime = the Linker's (same contract as the existing
  cross-module `CallCtx` note in `linker.zig`'s header).

Rejected alternatives:

- **Raw thunk registration** (`defineHostThunk` surfacing the internal
  `host_func` payload): smaller blast radius but forfeits the comptime
  signature derivation + the ergonomic `*Caller`-first host fns; every
  trampoline would hand-pop operands. The campaign will add many P2
  trampolines (D2/D3) — the ergonomic path pays off.
- **Globals / thread-locals** for the ctx: not re-entrant, not clean.

## Consequences

- Additive: no existing caller changes; `defineFunc` semantics intact.
- The WASI-P2 trampolines (`api/component.zig` `WasiP2Ctx` +
  `p2GetStdout`/`p2OutStreamWrite`/`p2OutStreamDrop`) recover their ctx
  via `caller.data(WasiP2Ctx)`.
- Calling `Caller.data` from a `defineFunc` host fn (ctx = null) is a
  programmer error (asserts on the null unwrap).
