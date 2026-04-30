# zwasm v2

A from-scratch WebAssembly runtime in Zig 0.16.0.

> **Status: Phase 0 (skeleton). Not yet runnable as a Wasm host.**
>
> v2 is a ground-up redesign of [zwasm v1](https://github.com/clojurewasm/zwasm)
> with day-one design for WebAssembly 3.0 (W3C Recommendation 2025-09),
> wasm-c-api conformance, and dual-backend (interpreter + JIT-arm64 +
> JIT-x86) differential testing. Compatibility with v1 is explicitly
> out of scope — the migration guide ships at v0.1.0.

## Goals (v0.1.0 = parity with zwasm v1 + wasm-c-api standardisation)

- Full WebAssembly 3.0 (multi-value, SIMD-128, memory64, GC, EH,
  tail call, function references, extended-const, relaxed-simd)
- WASI 0.1 (preview1) full surface
- C ABI: `wasm.h` (wasm-c-api standard) primary; `zwasm.h`
  extensions (allocator inj, fuel, cancel, fast invoke) subordinate
- Single-pass JIT for both ARM64 and x86_64 sharing one ZIR mid-IR
- Cold-start fast (no SSA optimisation passes); AOT mode via
  `zwasm compile`
- Three-OS first-class: macOS aarch64, Linux x86_64, Windows x86_64

Component Model + WASI 0.2 + threads ship in v0.2.0.

## Layout

```
src/         Zig source (frontend / ir / runtime / feature / interp / jit / wasi / c_api / cli / util / platform)
include/     Public C headers (wasm.h / wasi.h / zwasm.h)
build.zig    Build script with -Dwasm / -Dwasi / -Dengine flags
flake.nix    Nix dev shell pinned to Zig 0.16.0
.dev/        ROADMAP + handover + ADRs + proposal_watch + setup notes
.claude/     Claude Code settings, skills, rules
scripts/     gate, zone_check, file_size_check, bench, run_remote_windows
test/        per-layer suites; unified runner is `zig build test-all`
bench/       benchmark history (append-only)
private/     gitignored agent scratch
```

## Quick start

```sh
# Mac native
zig build              # compile placeholder binary
zig build test         # unit tests
zig build test-all     # all enabled layers (Phase 0: just `test`)

# OrbStack Ubuntu x86_64 (after `.dev/orbstack_setup.md` setup)
orb run -m my-ubuntu-amd64 bash -c 'zig build test-all'

# Windows x86_64 via SSH (after `.dev/windows_ssh_setup.md` setup)
bash scripts/run_remote_windows.sh test-all
```

Nix + direnv is the supported dev environment. After installing
both, `direnv allow` in this directory loads the pinned Zig 0.16.0
and toolchain.

## Build flags (ROADMAP §4.6)

```
-Dwasm=3.0|2.0|1.0          # default 3.0; lower levels omit later proposals
-Dwasi=p1|p2|both|none      # default p1 (v0.1.0)
-Dengine=both|jit|interp    # default both
-Dstrip=true|false          # default false
```

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — authoritative mission, principles, phase plan
- [`.dev/handover.md`](.dev/handover.md) — current session state
- [`.dev/decisions/`](.dev/decisions/) — ADRs (deviations from ROADMAP)
- [`~/zwasm/private/v2-investigation/`](../../zwasm/private/v2-investigation/) — pre-skeleton design surveys

## License

MIT. See `LICENSE`.
