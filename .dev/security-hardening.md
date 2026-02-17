# Security Hardening for v1.0.0

Design document for WASI capability defaults and CLI security UX.
See `private/production_ready/07_security_analysis_report.md` for full analysis.

## Motivation

- `loadWasi()` defaults to `Capabilities.all` (allow everything) — dangerous for embedders
- CLI has good deny-by-default, but no "sandbox" shorthand for edge/production use
- `--allow-env` is all-or-nothing; no per-variable injection

## Tasks

### 43.9: Restrictive library API defaults

**Change `loadWasi()` and `loadCore()` to use `Capabilities.cli_default`** instead of
`Capabilities.all`. The `cli_default` preset already exists in wasi.zig:

```
cli_default = { .allow_stdio, .allow_clock, .allow_random, .allow_proc_exit }
```

Files to modify:
- `src/types.zig` line 382: `Capabilities.all` → `Capabilities.cli_default`
- `src/types.zig` line 177: `WasiOptions.caps` default → `Capabilities.cli_default`
- `src/wasi.zig` line 2035 (test helper): keep `.all` for tests
- `src/cli.zig`: CLI `--allow-*` flags override caps on top of cli_default (already works)

Callers that need full access must use `loadWasiWithOptions(.{ .caps = .all })`.

**ClojureWasm impact**: CW calls `zwasm.WasmModule.loadWasi()` in
`src/wasm/types.zig:82`. Must change to `loadWasiWithOptions(.{ .caps = .all })`.
Note written in `~/ClojureWasm/.dev/memo.md`.

### 43.10: --sandbox CLI flag

Add `--sandbox` flag that sets:
- All capabilities OFF (deny-all)
- Fuel: 1,000,000,000 (1 billion instructions)
- Max memory: 268,435,456 (256 MB)

Individual `--allow-*` flags can be combined with `--sandbox`:
```
zwasm run app.wasm --sandbox --allow-read
```

Implementation: single flag in cli.zig argument parsing.

### 43.11: --env=KEY=VALUE individual env injection

Currently `--allow-env` exposes all host environment variables.
Add `--env=KEY=VALUE` to inject specific variables without exposing others.

When `--env=K=V` is used:
- `allow_env` remains false (host env not exposed)
- Only explicitly injected variables are visible to the guest

Files: `src/cli.zig` (parsing), `src/wasi.zig` (WasiContext needs injected env storage).

## Execution Order

1. **43.9** first (API change, CW note)
2. **43.10** next (--sandbox depends on understanding the cap model)
3. **43.11** last (independent, additive)

## Out of Scope (v1.1+)

- FS preopen / virtual root
- Wall clock timeout
- CapabilitySet builder API
- Feature restriction (per-proposal ON/OFF)
- Clock/random virtualization
