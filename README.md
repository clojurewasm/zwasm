# zwasm v2

A from-scratch WebAssembly runtime in Zig 0.16.0.

> **Status: Phase 9 in progress.** Wasm 1.0 + 2.0 (incl. SIMD-128)
> reach 100% spec compliance on Mac aarch64 + Linux x86_64. Windows
> x86_64 reconcile (§9.13-0) ongoing. v0.1.0 release follows Phase
> 10–14.

v2 is a ground-up redesign of [zwasm v1](https://github.com/clojurewasm/zwasm)
with day-one design for WebAssembly 3.0, wasm-c-api conformance, and
dual-backend (interpreter + JIT-arm64 + JIT-x86) differential testing.
v1 ABI compatibility is out of scope; migration guide ships at v0.1.0.

## Supported platforms (verified hosts)

| Role         | Machine                 | OS                                          | Arch    | CPU                     | RAM   |
|--------------|-------------------------|---------------------------------------------|---------|-------------------------|-------|
| Development  | MacBook Pro (Mac16,8)   | macOS                                       | aarch64 | Apple M4 Pro            | 48 GB |
| Linux gate   | `ubuntunote` (mini PC)  | Ubuntu (Determinate Nix + flake-pinned Zig) | x86_64  | Intel i7-1195G7 (4C/8T) | 32 GB |
| Windows gate | `windowsmini` (mini PC) | Windows 11 Pro (native, MSVC ABI)           | x86_64  | Intel N100 (4C/4T)      | 16 GB |

These are the only machines on which CI/dev runs are verified. Windows
ARM64, Linux aarch64, and 2nd-Windows-machine cross-validation are
out of scope for v0.1.0.

## Coverage

### Wasm versions

| Spec                                                                                                                            | Status                  | Notes                                                                            |
|---------------------------------------------------------------------------------------------------------------------------------|-------------------------|----------------------------------------------------------------------------------|
| Wasm 1.0                                                                                                                        | ✅ 100%                 | spec testsuite green on Mac aarch64 + ubuntunote x86_64                          |
| Wasm 2.0 (multi-value, SIMD-128, bulk-memory, reference-types, non-trapping FP-int conversion, sign-extension, mutable globals) | ✅ 100%                 | §9.12-E ★ DONE; `skip-impl == 0`; 4 testsuites green; bit-identical Mac+ubuntu |
| Wasm 2.0 — Windows reconcile                                                                                                   | 🟡 in progress           | §9.13-0 D-022 / D-084 / D-136 / D-028                                           |
| Wasm 3.0 (GC, EH, tail-call, memory64, multi-memory, typed func refs, extended-const, relaxed-simd)                             | 📋 deferred to Phase 10+ | Day-1 design slots reserved per ADR-0061                                         |

### WASI versions

| Spec                                 | Status               | Notes                                                |
|--------------------------------------|----------------------|------------------------------------------------------|
| WASI 0.1 (preview1)                  | 🟡 partial            | scope of v0.1.0; full surface lands across Phase 11+ |
| WASI 0.2 (preview2, Component Model) | 📋 deferred to v0.2.0 |                                                      |

### JIT backends

| Arch                                | Status                   |
|-------------------------------------|--------------------------|
| ARM64 (AAPCS64)                     | ✅ functional            |
| x86_64 SysV (Linux/macOS-pre-arm64) | ✅ functional            |
| x86_64 Win64 (MSVC ABI)             | 🟡 in progress (§9.13-0) |

## CLI

```sh
zwasm                           # print version + build options
zwasm run <path.wasm> [args]    # WASI-driven exec; exits with guest's
                                # proc_exit code
zwasm run --invoke <name> \     # invoke a named export (zero-args)
    <path.wasm>                 # instead of _start / main
zwasm compile <path.wasm> \     # produce a .cwasm v0.1 AOT artifact
    -o <out.cwasm>              # (loader lands in Phase 12)
```

Runtime env vars:

- `ZWASM_DEBUG=<categories>` — dbg.zig category filter
- `ZWASM_DIAG=<channels>` — diagnostic trace ringbuffer drain channels

Subcommands planned for later phases (per ROADMAP §10): `validate`,
`inspect`, `features`, `wat`, `wasm`.

## Build flags

```
-Dwasm=3.0|2.0|1.0          # default 3.0; lower levels omit later proposals
-Dwasi=p1|p2|both|none      # default p1 (v0.1.0)
-Dengine=both|jit|interp    # default both
-Dstrip=true|false          # default false
```

## Quick start

```sh
# Mac native
zig build              # compile zwasm binary
zig build test         # unit tests
zig build test-all     # all enabled layers

# Cross-compile sanity check from Mac (catches Win64 compile errors in ~3s)
zig build -Dtarget=x86_64-windows-gnu

# Linux x86_64 via SSH (see .dev/ubuntunote_setup.md)
bash scripts/run_remote_ubuntu.sh test-all

# Windows x86_64 via SSH (see .dev/windows_ssh_setup.md;
# tools provisioned by scripts/windows/install_tools.ps1)
bash scripts/run_remote_windows.sh test-all
```

Nix + direnv is the supported dev environment. `direnv allow` loads
the pinned Zig 0.16.0 and tool surface (`flake.nix`: hyperfine,
wasm-tools, wasmtime, wabt, yq-go, lldb, nasm).

## Layout

```
src/         Zig sources (parse/ validate/ ir/ runtime/ instruction/ feature/
             engine/ interp/ wasi/ api/ cli/ diagnostic/ support/ platform/)
include/     Public C headers (wasm.h / wasi.h / zwasm.h)
build.zig    Build script
flake.nix    Nix dev shell pinned to Zig 0.16.0
.dev/        ROADMAP + handover + ADRs + lessons + setup notes
.claude/     Claude Code settings, skills, rules (auto-loaded)
scripts/     gate_commit, zone_check, file_size_check, bench, run_remote_*
test/        per-layer suites; unified `zig build test-all`
bench/       benchmark history (append-only)
private/     gitignored agent scratch
```

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — mission, principles, phase plan
- [`.dev/handover.md`](.dev/handover.md) — current session state
- [`.dev/decisions/`](.dev/decisions/) — ADRs (deviations from ROADMAP)
- [`.dev/lessons/`](.dev/lessons/) — observational learnings (re-derivable)

## License

MIT. See `LICENSE`.
