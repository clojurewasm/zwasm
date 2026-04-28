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
- Binary stripped: Mac 1.20 MB, Linux 1.56 MB (ceiling 1.60 MB; tightened from 1.80 MB in W48 Phase 1). Memory: ~3.5 MB RSS.
- Platforms: macOS ARM64, Linux x86_64/ARM64, Windows x86_64.
- **main = stable**. v1.10.0 released; post-release work on delib / W46 merged
  via PRs #47 (1a/1b pre-cursor), #48 (1b), #49 (1c/1d/1e/1f + C-API libc fix).
- link_libc = false across lib / cli / tests / examples / e2e / bench / fuzz.
  C-API targets (shared-lib, static-lib, c-test) keep link_libc = true because
  `src/c_api.zig` uses `std.heap.c_allocator`.

## Current Task

**Plan A + Plan B sub-1+2 + Plan C alpha shipped (2026-04-29).** PRs #60,
#61, #62, #64, #65 merged. main is green on all three OS matrix entries.
Detailed state, hard-won facts, residual work, and the per-session
autonomy rules live in **`@./.dev/resume-guide.md`** — read that first
on a new session.

Quick orientation if continuing:

```bash
git log --oneline origin/main -8        # confirm what's on main
cat .dev/resume-guide.md                # full plan, gotchas, stop rules
bash scripts/sync-versions.sh           # toolchain pin sanity (instant)
bash scripts/gate-commit.sh --only=tests # smoke test
```

The guide has three pickable work areas:
**Plan C** (remaining seven `if: runner.os != 'Windows'` guards),
**Plan B sub-3** (CI Nix-ify), **doc drift** (README / book /
setup-orbstack.md).

When all three are exhausted, delete `.dev/resume-guide.md` and this
"Current Task" pointer.

## Previous Task

**Overnight 2026-04-28 → 2026-04-29.** Five PRs to main:

- #60 — `flake.nix` made SSoT, `versions.lock` mirror, WASI SDK 25→30,
  D136 in decisions.md, `.dev/environment.md` initial.
- #61 — `scripts/gate-commit.sh`, `gate-merge.sh`, `run-bench.sh`,
  `sync-versions.sh`, `lib/versions.sh`, `windows/install-tools.ps1`.
- #62 — CI `versions-lock-sync` job (Merge Gate item #9 mechanised).
- #64 — Windows memory check via PowerShell (1 of 8 Windows guards down).
- #65 — `HYPERFINE_VERSION` sourced from versions.lock.

Pre-overnight: **W48 Phase 1 — DONE (2026-04-25).** Trimmed Linux
binary 1.64 → 1.56 MB (-83 KB) and Mac 1.38 → 1.20 MB (-180 KB) via
three changes in `src/cli.zig`: `pub const panic =
std.debug.simple_panic`, `std_options.enable_segfault_handler = false`
(zwasm has its own SIGSEGV handler), and `main` returning `u8` instead
of `!void`. Remaining 62 KB to target 1.50 MB (W48 Phase 2,
non-blocking — `std.Io.Threaded` ~115 KB and `debug.*` 81 KB are the
biggest contributors; lever is `std_options_debug_io` override with a
minimal direct-stderr Io instance).

**W46 Phase 2 — DONE (2026-04-25 via PR #52).** Routed remaining
`std.c.*` direct calls in `wasi.zig` through `platform.zig` helpers.
Size-neutral on Linux because the `std.c.*` sites were already inside
comptime-pruned `else` arms; pure consistency refactor.

### W46 earlier phases

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
- **Linux is already libc-free even when `std.c.*` appears in source.**
  Inside a `switch (comptime builtin.os.tag)`, the `.linux =>` and
  `else =>` arms are comptime-pruned; the Linux build never references
  `std.c.*` bindings even if they appear textually. This is why W46 Phase 2
  was size-neutral on Linux — the refactor only cleans up Mac/BSD code
  paths.

## References

- `@./.dev/roadmap.md` — phase roadmap + long-term direction
- `@./.dev/checklist.md` — open work items (W##) + resolved summary
- `@./.dev/decisions.md` — architectural decisions (D100+)
- `@./.dev/references/ubuntu-testing-guide.md` — OrbStack-driven Ubuntu gates
- External impls to cross-read when debugging / designing:
  `~/Documents/OSS/wasmtime/` (cranelift codegen), `~/Documents/OSS/zware/`
  (Zig idioms).
