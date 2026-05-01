---
name: 0005 — Hand-author include/wasi.h instead of vendoring upstream
date: 2026-05-02
status: Accepted
tags: phase-4, c-api, wasi, vendoring
---

# 0005 — Hand-author `include/wasi.h` instead of vendoring upstream

- **Status**: Accepted
- **Date**: 2026-05-02
- **Author**: Claude (autonomous /continue loop)
- **Tags**: phase-4, c-api, wasi, vendoring

## Context

ROADMAP §9.4 / 4.0 reads:

> Vendor `wasi.h` (WASI snapshot-1 C header) verbatim from
> upstream + pin commit (ADR).

This intentionally mirrors §9.3 / 3.0's vendor-pin discipline
for `wasm.h`, but the analogy breaks: the WASI ecosystem has
no single canonical "upstream `wasi.h`" to vendor.

The closest candidates and why each is unsuitable:

1. **`WebAssembly/wasm-c-api`** — does not ship a `wasi.h`.
   Their `wasm.h` deliberately leaves WASI hosting outside the
   spec.
2. **`WebAssembly/WASI`** — defines the snapshot-1 surface in
   `.witx`, not C. Bindgen output is per-language.
3. **`WebAssembly/wasi-libc`'s `wasi/api.h`** — describes the
   *guest-side* syscall numbers, not the *host-side* embedding
   API the §9.4 / 4.7 binding needs.
4. **`wasmtime/crates/c-api/include/wasi.h`** — runtime-specific
   (`wasmtime/conf.h` dependency, `WASMTIME_FEATURE_WASI`
   guards). Vendoring "verbatim" would import wasmtime-private
   shapes; scrubbing them produces something that is no longer
   verbatim.
5. **WAMR / wasmer** — each ships its own host-side WASI C API,
   shaped to that runtime's Engine / Store / Module model.

The host-side WASI embedding API is therefore *project-shaped
by design*. A C host that wires WASI on top of zwasm needs to
configure preopens / args / environ on the binding's
`wasm_store_t` (or zwasm-specific extension), and these
setters live in `wasi.h`-like surface that the project itself
authors.

## Decision

§9.4 / 4.0 changes from "vendor `wasi.h` verbatim from upstream
+ pin commit" to:

> Hand-author `include/wasi.h` declaring the zwasm-specific
> WASI 0.1 host-setup C API. Document the authorship strategy
> + the API's growth contract in this ADR. No upstream pin
> exists; bumps to the header live in the same commit as the
> binding work that motivates them.

The header's initial scope mirrors what wasmtime's wasi.h
exposes for snapshot-1, but the names use the `zwasm_` prefix
(matching the existing `zwasm_instance_get_func` extension) so
the surface is unambiguously project-extension territory:

- `zwasm_wasi_config_t` — opaque host-setup handle.
- `zwasm_wasi_config_new` / `_delete`.
- `zwasm_wasi_config_inherit_argv` / `_inherit_env` /
  `_inherit_stdio` — pull from the host's argv / environ /
  stdio.
- `zwasm_wasi_config_set_args(*config, size, const char**)` —
  explicit argv override.
- `zwasm_wasi_config_set_envs(*config, size, const char**, const char**)` — envs.
- `zwasm_wasi_config_preopen_dir(*config, const char* host, const char* guest)` — preopens.
- `zwasm_store_set_wasi(*store, own zwasm_wasi_config_t*)` —
  installs the WASI setup on a Store. Must be called before
  `wasm_instance_new` consumes a module that imports
  `wasi_snapshot_preview1` exports; subsequent
  `wasm_instance_new` calls resolve those imports against the
  configured WASI host.

The `wasi_snapshot_preview1.*` *Wasm-side* import names (e.g.
`fd_write`, `proc_exit`, `args_get`) are not declared in this
C header — they're Wasm import strings the C host does not
manipulate, only chooses to enable via the
`zwasm_store_set_wasi` call.

## Consequences

- §9.4 / 4.0 lands as a hand-authored stub `include/wasi.h`
  alongside an `include/README.md` update describing
  the dual-policy (`wasm.h` vendored under ADR-0004,
  `wasi.h` hand-authored under ADR-0005).
- §9.4 / 4.1 onward populates the corresponding Zig
  implementation behind those C-side declarations.
- A future ADR can re-introduce upstream-pin vendoring if
  WASI standardises a host-side C API (no concrete signal
  this is coming, but the door stays open).
- The `zwasm_` prefix on the WASI host-config functions
  signals to C hosts that these are project extensions, not
  cross-runtime portable. Hosts targeting "any wasm runtime"
  will still link only against `wasm.h`; WASI is opt-in.

## Alternatives considered

### Alternative A — Vendor wasmtime's `wasi.h`

- **Sketch**: vendor `wasmtime/crates/c-api/include/wasi.h`
  verbatim, scrub the wasmtime-specific includes.
- **Why rejected**: scrubbed-verbatim is an oxymoron — once we
  edit it, we own it. ADR-0004's pin rationale (deterministic,
  lockstep with upstream) does not apply when the vendored
  file is not a faithful upstream reproduction.

### Alternative B — Skip a header entirely; expose WASI through Zig only

- **Sketch**: drive WASI configuration via `src/wasi/host.zig`
  Zig API; C hosts cannot use WASI.
- **Why rejected**: contradicts ROADMAP §9.4 exit criterion
  ("`zwasm run hello.wasm` works on all 3 OS"). A C host
  embedding zwasm must be able to enable WASI; no header
  surface means no C-host WASI.

### Alternative C — Vendor wasi-libc's `wasi/api.h`

- **Sketch**: vendor the guest-side syscall-number header at
  `include/wasi/api.h`.
- **Why rejected**: that header describes Wasm-side imports,
  not the host-side embedding surface §9.4 needs. It would
  ship dead bytes from the C host's perspective.

## References

- ROADMAP §9.4 (Phase 4 — WASI 0.1 minimal).
- ADR-0004 (vendor `wasm.h` upstream pin) — the contrasting
  pattern this ADR diverges from.
- `wasmtime/crates/c-api/include/wasi.h` — design inspiration
  for the surface shape; not vendored.
