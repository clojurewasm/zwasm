# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Zig toolchain**: 0.16.0 (migrated 2026-04-24).
- Stages 0-46 + Phase 1, 3, 5, 8, 10, 11, 13, 15, 19, 20 complete.
- Spec: 62,263/62,263 Mac+Ubuntu (100.0%, 0 skip).
- E2E: 796/796 Mac+Ubuntu, 0 fail.
- Real-world: Mac 50/50, Ubuntu 50/50, Windows 46/46, 0 crash.
- FFI: 80/80 Mac+Ubuntu.
- JIT: Register IR + ARM64/x86_64 + SIMD (NEON 253/256, SSE 244/256).
- HOT_THRESHOLD=3 (lowered from 10 in W38).
- Binary stripped: Mac 1.38 MB, Linux 1.65 MB (ceiling 1.80 MB). Memory: ~3.5 MB RSS.
- Platforms: macOS ARM64, Linux x86_64/ARM64, Windows x86_64.
- **main = stable**. v1.10.0 released; post-release work on delib / W46 merged
  via PRs #47 (1a/1b pre-cursor), #48 (1b), #49 (1c/1d/1e/1f + C-API libc fix).
- link_libc = false across lib / cli / tests / examples / e2e / bench / fuzz.
  C-API targets (shared-lib, static-lib, c-test) keep link_libc = true because
  `src/c_api.zig` uses `std.heap.c_allocator`.

## Current Task

**W46 Phase 1 — DONE (2026-04-25).** PR #49 merged (`30a3680`). See
`.dev/checklist.md` Resolved section for details. Next candidate work:

- **W47**: `tgo_strops_cached` +24% regression investigation (single-benchmark,
  low priority). See checklist.
- **W45**: SIMD loop persistence — skip Q-cache eviction at loop headers
  (requires back-edge detection in `scanBranchTargets`).
- **W46 Phase 2 (optional)**: migrate `fd_read`/`fd_write` onto `std.Io`.
  Not blocking. Would help return binary size to 1.50 MB target and improve
  Windows I/O correctness further; pick up when `std.Io` stdlib APIs stabilize.

## Previous Task

**W46 Phase 1c/1d/1e/1f — DONE (2026-04-25 via PR #49).**

Routed test-site and trace-site `std.c.*` calls through new platform helpers
(`pfdDup2`, `pfdPipe`, `pfdSleepNs` added alongside existing `pfd*` family),
then flipped `.link_libc = false` across every module in `build.zig` except
the three C-API targets. CI-green on all four runners (Mac/Ubuntu/Windows/
size-matrix). Fix commit `c11a947` routed `std.c.{pipe,dup,dup2,read,
nanosleep}` in wasi.zig+vm.zig tests; `04ac19d` kept link_libc=true on
C-API targets after the first push revealed `std.heap.c_allocator` needs libc.

### Hard-won nuggets (reuse later)

- **Do NOT wrap in `nix develop --command` inside this repo.** direnv +
  claude-direnv has already loaded the flake devshell AND unset
  DEVELOPER_DIR/SDKROOT. Re-entering nix shell re-sets SDKROOT and breaks
  `/usr/bin/git`. See `memory/nix_devshell_tools.md`.
- **e2e_runner uses `init.io`, NOT a locally constructed Threaded io**.
  A fresh `std.Io.Threaded.init(allocator, .{}).io()` inside user main
  crashes with `0xaa…` in `Io.Timestamp.now` when iterating many files.
- **C-API targets must keep `link_libc = true`.** `src/c_api.zig` uses
  `std.heap.c_allocator`. Mac masks this via libSystem auto-link; Linux and
  Windows fail with "C allocator is only available when linking against libc".
- **Cross-compile sanity trick.** `zig build test -Dtarget=x86_64-linux-gnu`
  and `-Dtarget=x86_64-windows-gnu` compile cleanly on Mac even though the
  test binaries can't execute — the compile success alone catches link-time
  symbol-resolution issues before pushing to CI.

## References

- `@./.dev/roadmap.md` — phase roadmap + long-term direction
- `@./.dev/checklist.md` — open work items (W##) + resolved summary
- `@./.dev/decisions.md` — architectural decisions (D100+)
- `@./.dev/references/ubuntu-testing-guide.md` — OrbStack-driven Ubuntu gates
- External impls to cross-read when debugging / designing:
  `~/Documents/OSS/wasmtime/` (cranelift codegen), `~/Documents/OSS/zware/`
  (Zig idioms).
