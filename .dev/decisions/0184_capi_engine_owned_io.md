# ADR-0184 — C-API: engine-owned `std.Io` for WASI preopens / inherit-env

> **Doc-state**: ACTIVE
> Status: Proposed (autonomous draft for the D-255 carry; user review
> requested before implementation — this re-adds REMOVED public C-API
> surface, an ADR-0143 reversal)

## Context

Zig 0.16 is capability-I/O: filesystem and process access flow through a
`std.Io` token. The CLI threads `std.process.Init.io` from `main`; a
C-ABI library export has no such token, so the C-API WASI config
builders `preopen_dir` / `inherit_env` / `inherit_argv` were deferred
and their declarations REMOVED from `include/wasi.h` (ADR-0143; carried
as D-255). Embedders today must use explicit `set_args` / `set_envs`
and have NO preopen path at all from C — a real gap vs wasmtime's C API
(`wasi_config_preopen_dir` is standard surface and cw-class consumers
expect it).

The component path already shows the shape that works: tests construct
`std.Io.Threaded` and assign `host.io`; `Host.io: ?std.Io` is the
established seam everything downstream (preopens, P2 host, sockets)
already consumes.

## Decision (proposed)

**The C-API `zwasm_engine_t` constructs and OWNS a `std.Io.Threaded`
instance at `zwasm_engine_new`, exposed internally as `engine.io()`.**

- `Engine.init` (Zig facade) stays io-free — the NATIVE Zig surface
  keeps strict capability-passing (the embedder hands `host.io` itself,
  as today). Only the C-ABI boundary, which cannot receive a Zig token,
  manufactures one. The divergence is the C boundary's nature, not a
  policy change: a C embedder's ambient authority is the process itself
  (same trust model as wasmtime's C API).
- `zwasm_wasi_config_*` re-adds, in order:
  1. `preopen_dir(cfg, host_path, guest_path)` — opens via the engine
     io at INSTANTIATION (not config) time, so config stays allocation-
     light and errors surface where wasm-c-api reports them.
  2. `inherit_env(cfg)` — snapshot via `std.process.Environ` over the
     engine io; no new libc surface (stays within ADR-0070).
  3. `inherit_argv(cfg)` — LAST; needs a vetted cross-platform
     process-args helper; may stay deferred if Zig 0.16 offers no
     library path (document as not-supported rather than shipping a
     platform-conditional half).
- Threading: `std.Io.Threaded` per engine; engines are already the
  C-API's unit of isolation. `zwasm_engine_delete` deinits it.

## Alternatives rejected

- **`zwasm_engine_set_io(void*)`** — no C-ABI representation of
  `std.Io` exists; an opaque pass-through helps no real C embedder.
- **Lazy global io (process singleton)** — hidden global state violates
  the allocator/capability strict-pass discipline more than an
  engine-scoped instance does, and breaks multi-engine isolation.
- **Keep the gap (status quo)** — fails the 完成形 "industry-standard
  usage" bar: wasmtime/wasmer C embedders expect preopens; cw v1
  consumers hit it on first real WASI use from C.

## Consequences

- D-255 discharges (preopen_dir + inherit_env; inherit_argv per its own
  bullet). `include/wasi.h` declarations return (ADR-0143 Revision).
- The engine grows a small owned runtime (Threaded init/deinit); lean
  builds unaffected (no component dependency).
- Tests: C-API smoke gains a preopen round-trip (open a temp dir from C,
  guest reads a file through it) on all 3 hosts.

## Revisions

- (none yet)
