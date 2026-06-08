# zwasm v1 — contributor PR / issue history

> **Scope**: this records the *community* contribution history of **zwasm v1**
> (the published `clojurewasm/zwasm` repository, releases `v1.0.0` → `v1.11.0`),
> as groundwork for the v2 release. v1 = `$MY/zwasm`; v2 = `$MY/zwasm_from_scratch`.
>
> **Method (anti-hallucination)**: every entry below was pulled from the GitHub
> API via `gh` against `clojurewasm/zwasm` (PR/issue numbers, authors, merge
> state, merge commits, and the maintainer's own resolution comments). Numbers
> and commit SHAs are quoted verbatim from that source, not from memory.
>
> Totals at survey time: **81 PRs** (68 merged), **24 issues**. Of the PRs, 52
> are the maintainer (`chaploud`), 17 are `github-actions[bot]`, and **12 are
> from external contributors** — the subject of this document.

## Contributors at a glance

| Contributor   | PRs | Issues | Headline contribution(s)                                                                                  |
|---------------|-----|--------|-----------------------------------------------------------------------------------------------------------|
| `jtakakura`   | 7   | 10     | Rust FFI, const-correct C API, execution cancellation, Config-based loading API, OOM/UAF safety hardening |
| `DeanoC`      | 2   | 0      | Timeout-trap support; **first-class Windows support** (big)                                               |
| `notxorand`   | 1   | 0      | Kicked off the Zig 0.15 → 0.16 migration                                                                 |
| `matthargett` | 1   | 0      | `aarch64-watchos-ilp32` (Apple Watch) build enablement                                                    |
| `jordibc`     | 1   | 0      | README link fix                                                                                           |

The 14 `github-actions[bot]` issues are all **automated** `SpecTec changes
detected (YYYY-Wnn)` reports from a scheduled spec-watch workflow (weeks
2026-W10 … W23) — not human contributions; listed here only so the count
reconciles.

## Maintainer integration pattern (observed across the merges)

The maintainer's handling is consistent and worth recording, because it shapes
how each contribution actually landed:

1. **Contributor commit preserved as the base** of a dedicated merge/feature
   branch, with maintainer refinements *stacked on top* (rather than rewriting
   the contributor's commit). Stated explicitly on #28, #32, #40.
2. **Separate "Merge PR #N … + refinements" PRs** were used to land several
   contributions (e.g. #43 for #28, #44 for #40, #57 for issue #42).
3. **Full Commit Gate re-run on Mac + Ubuntu** (and Windows where relevant)
   before merge, with the results pasted into the PR thread.
4. **Credit care**: when notxorand's #41 was superseded by the maintainer's #45,
   a follow-up empty commit (`bd14773`, via #50) added a `Co-authored-by:`
   trailer so the contributor appeared on the Contributors graph without
   rewriting the `v1.10.0` tag — accompanied by an explicit apology in-thread.

## External pull requests (chronological)

### #2 — README link fix · `jordibc` · **merged** (`074b06f4`)
Minor fix to the ClojureWasm link in `README.md`. First outside contribution.

### #6 — Add timeout trap support · `DeanoC` · **merged** (`c4b9196e`)
Added a `TimeoutExceeded` trap/error for deadline-based interruption, threaded
timeout reporting into the CLI error formatter, and added the `--timeout` CLI
flag with deadline-aware JIT suppression + tests. Motivated by embedded
"Spider" WASM execution limits. The contributor rebased their
`feature/timeout-support` work into the PR head (`2412b97`) during review.

### #8 — First-class Windows support · `DeanoC` · **merged** (`4f8963a6`)
The single largest external contribution (34 files, +2351/−1185). Added Windows
runtime support across **executable memory, guard pages, JIT, cache paths, and
WASI host integration**; made the spec / e2e / real-world test runners
cross-platform; added Windows CI, release packaging, and PowerShell install
support; and introduced **guest path aliases for preopened directories** so
Windows WASI compat tests use stable guest-visible mount points. Delivered as a
cleaned squash of a fork-side validation PR (`DeanoC/zwasm#1`) that had passed
CI on Linux/macOS/Windows. The maintainer reviewed all 26-file diff, re-ran the
gate on macOS + Ubuntu, and pushed follow-up fixes (e.g. restoring
`SYMLINK_NOFOLLOW` in the path layer).

### #12 — Rust FFI example · `jtakakura` · **merged** (`775224ce`)
Added `examples/rust/` — a minimal Rust FFI example over the zwasm C API via
`extern "C"`, mirroring the C and Python examples. Flagged a known x86_64 C-API
segfault (issue #11, same as the Python example; aarch64 worked). Maintainer
follow-up `b25f7c7` scoped the `.gitignore`, added a book quickstart (EN/JA),
and a CI step to build+run the Rust example.

### #16 — `const`-correct `zwasm_module_invoke` args · `jtakakura` · **merged** (`4bd71e3e`)
Made the `args` parameter read-only across the stack (Zig `?[*]u64` →
`?[*]const u64`, regenerated C header to `const uint64_t *`, updated the Rust
example). Removed the need for Rust callers to cast immutable slices to mutable
pointers. Fixes issue #15. Results buffer kept mutable.

### #28 — Explicit cancellation of Wasm execution · `jtakakura` · **merged** (`48b3f53d`, shipped **v1.9.0** via #43)
Added a thread-safe `cancelled: std.atomic.Value(bool)` to the `Vm`, a
`Vm.cancel()` plus `reset()`-clears-it lifecycle, a check wired into
`consumeInstructionBudget()` (≈ every 1024 instructions) and into the JIT
fuel-check path (`jitFuelCheckHelper`), and a public cancellation API. Resolves
issue #27. The three contributor commits were preserved verbatim as the feature
branch base; the maintainer added six refinement commits (e.g. kept `loadLinked`
signature stable, FFI thread-safety tests).

### #30 — Config-based module-loading API · `jtakakura` · **merged** (`cc87f598`)
Consolidated the many specialized `load*` functions into a single
`WasmModule.Config` + `loadWithOptions` entrypoint (`src/types.zig`), applied VM
resource limits (fuel / timeout / memory) **before** the start function runs,
and added `zwasm_config_t` setter functions to the C API. Resolves issue #29.
Maintainer ran the full gate on both platforms plus a downstream-embedder
regression check before merging.

### #32 — Preserve `force_interpreter` after `invokeInterpreterOnly` · `jtakakura` · **merged** (`742362e1`)
Fixed a bug where the `force_interpreter` option was lost after a debug
`invokeInterpreterOnly` call (a subtle `defer`-reset). Moved to persistent
per-module settings. Closes issue #31. Maintainer stacked `b99f19b` to handle a
backward-compat regression the fix surfaced; contributor recorded as co-author.

### #40 — OOM-safe VM pointer in `loadLinked` · `jtakakura` · **closed**, shipped **v1.9.1** via #44
Guarded against an uninitialized `vm` field when `allocator.create(Vm)` fails
under OOM (which could crash in `deinit`); `vm` is set `null` on OOM and accesses
are guarded, with `invoke` returning `error.ModuleNotFullyLoaded`. Resolves issue
#39. Although the PR itself was closed (not merged), the maintainer picked the
contributor commit up "too useful to leave in draft," rebased it, and shipped it
as **v1.9.1** via #44 with the commit at the branch base for credit.

### #41 — Zig 0.15 → 0.16 migration · `notxorand` · **closed**, superseded by **v1.10.0** (#45)
Started the 0.16.0 migration. It was sequenced behind #28 (overlapping files),
then **superseded by the maintainer's #45** because 0.16 turned out to touch many
more surfaces (new `std.Io` interface, `link_libc` for WASI on Linux, Windows
`std.c.fd_t == HANDLE` breaking WASI compat, size-guard accommodation,
cancellation-test timespec on Windows). #45 shipped as **v1.10.0** with all CI
green (macOS / Ubuntu / Windows). Credit corrected post-hoc via #50 (`bd14773`,
`Co-authored-by:`). The migration "followed the path notxorand opened."

### #56 — Heap-allocate `FailingAllocator` in OOM test · `jtakakura` · **merged** (`dd7b43a7`)
Fixed a use-after-free in an OOM test: sub-structures store a copy of the
`Allocator` interface (pointer back to the stack-allocated `FailingAllocator`),
which dangled across loop iterations. Heap-allocating it stabilizes the address
through `WasmModule.deinit()`. Resolves issue #55.

### #97 — `aarch64-watchos-ilp32` (Apple Watch) build · `matthargett` · **closed**, re-landed via #98
Made `zig build static-lib -Dtarget=aarch64-watchos-ilp32 -Djit=false` produce a
working `libzwasm.a` for the Apple Watch SE/SE2/S4–S8 ILP32 device class
(32-bit pointers, aarch64 ISA), all gated on `@sizeOf(usize) < 8` so it is a
comptime no-op on 64-bit targets. Motivated by a 6-runtime pure-interpreter
benchmark across Apple's platform set. Because GitHub rejected the
maintainer-modify push to the contributor's fork (org-side 403), the maintainer
opened **#98** (contributor commit `3d563237` untouched + six cleanup commits:
`std.debug.no_panic` swap, 64-bit-scoped `single_threaded`, `error.MissingIo`
guard for WASI/timeout on ILP32, docs, build-only CI smoke), closing #97.

## Issues from contributors (`jtakakura`, 10) and their resolutions

| Issue | Title (abridged)                                            | Resolved by                                                                                                  |
|-------|-------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| #11   | Python ctypes example SIGSEGV with shared lib               | `86cb5ae` — GPA → `c_allocator` (Zig 0.15 PIC codegen crash in Debug shared libs on Linux x86_64)          |
| #15   | C header uses mutable `args` in `zwasm_module_invoke`       | PR #16 (const-correct args)                                                                                  |
| #17   | FD-based WASI stdio/preopen config in the C API             | PR #20 — `zwasm_wasi_config_set_stdio_fd()` / `zwasm_wasi_config_preopen_fd()` (borrow/own, cross-platform) |
| #23   | PIC + compiler-rt build options for the static lib          | PR #24 — `-Dpic=true -Dcompiler-rt=true` (fixes `__zig_probe_stack`, `fmaf`)                                |
| #27   | Explicit cancellation of Wasm execution                     | PR #28 → v1.9.0                                                                                             |
| #29   | Centralize `WasmModule` params into a `Config` struct       | PR #30                                                                                                       |
| #31   | `force_interpreter` lost after `invokeInterpreterOnly`      | PR #32                                                                                                       |
| #39   | `loadLinked` returns partially-initialized module on OOM    | PR #40 → v1.9.1 (#44)                                                                                       |
| #42   | `loadCore` leaks `export_fns`/`cached_fns` when start traps | PR #57 — symmetric `errdefer` chain                                                                         |
| #55   | UAF: dangling `FailingAllocator` pointer in sub-structures  | PR #56                                                                                                       |

## Release timeline (from `gh release list`)

`v1.0.0` (2026-02-17) · `v1.1.0` · `v1.2.0` · `v1.3.0` · `v1.5.0` · `v1.6.0`
(2026-03-15) · `v1.6.1` · `v1.7.0` · `v1.7.1` · `v1.7.2` · `v1.8.0` (2026-04-21)
· `v1.9.0` (cancellation, #28) · `v1.9.1` (OOM-safe load, #40) · `v1.10.0`
(Zig 0.16 migration, #45) · `v1.11.0` (2026-04-26, latest).

## Themes the community pushed on (signal for v2)

- **C-API ergonomics & FFI safety** (jtakakura): const-correctness, FD-based
  WASI config, PIC/compiler-rt static-lib linking, Config-based loading,
  Rust/Python binding viability. These are the surfaces external embedders hit
  first — worth treating as first-class in v2's C-API audit.
- **Memory-safety correctness on error paths** (jtakakura): OOM partial-init,
  leak-on-trap, use-after-free in tests. v2 should keep these covered.
- **Platform reach** (DeanoC, matthargett): Windows first-class support and
  ILP32/Apple-Watch interpreter-only builds.
- **Toolchain currency** (notxorand): the Zig 0.15 → 0.16 migration.
