---
name: release
description: Full release process for tagging zwasm and updating ClojureWasm downstream
disable-model-invocation: true
---

# Release: zwasm + ClojureWasm

Full release process. Only run when explicitly instructed by the user.
Version argument: `/release v1.2.0`

**Failure policy**: Stop at the failed phase, report to user.
Fix the issue (new commit on zwasm or CW), then re-run from the failed phase.
Never tag or push until all prior phases pass.

## Pre-flight Checks

Before starting, verify:
1. On `main` branch, clean working tree
2. All feature branches merged (no pending reliability/dev branches)
3. CI green on latest main push (check `gh run list --limit 1`)

## Phase 1: zwasm Verification (Mac)

1. Ensure on `main` branch: `git checkout main && git status`
2. `zig build test` — all pass, 0 fail, 0 leak
3. `python3 test/spec/run_spec.py --build --summary` — 62,263+ pass, fail=0, skip=0
4. `python3 test/e2e/run_e2e.py --convert --summary` — 796+ pass, fail=0, leak=0
5. `python3 test/realworld/run_compat.py` — PASS=50, FAIL=0, CRASH=0 (requires `build_all.py` first if wasm files missing)
6. `bash test/c_api/run_ffi_test.sh --build` — 0 failed
7. `bash bench/run_bench.sh` — full benchmark suite, no regression
8. Size guard (stripped via `-Dstrip=true`):
   - Mac ≤ 1.30 MB (~1.20 MB), Linux ≤ 1.60 MB (~1.56 MB), Windows ≤ 1.80 MB (~1.70 MB)
   - Memory (sieve benchmark): ≤ 4.5 MB RSS

## Phase 2: zwasm Verification (Ubuntu x86_64 via OrbStack)

See `.dev/references/ubuntu-testing-guide.md` for commands. Setup: `.dev/references/setup-orbstack.md`.

1. Rsync project to VM-local storage:
   ```bash
   orb run -m my-ubuntu-amd64 bash -lc "
     rsync -a --delete \
       --exclude='.zig-cache' --exclude='zig-out' \
       '/Users/shota.508/Documents/MyProducts/zwasm/' ~/zwasm/
   "
   ```
2. Unit tests: `orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && zig build test"` — all pass, 0 fail, 0 leak
3. Spec tests: `orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && python3 test/spec/run_spec.py --build --summary"` — fail=0, skip=0
4. E2E tests: `orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && python3 test/e2e/run_e2e.py --convert --summary"` — fail=0, leak=0
5. Real-world compat:
   ```bash
   orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && export WASI_SDK_PATH=/opt/wasi-sdk && python3 test/realworld/build_all.py"
   orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && python3 test/realworld/run_compat.py --verbose"
   ```
   PASS=50, FAIL=0, CRASH=0 (needs `build_all.py` first; requires WASI SDK + Rust wasm32-wasip1 + Go + TinyGo)
6. FFI tests: `orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && bash test/c_api/run_ffi_test.sh --build"` — 0 failed
7. Benchmarks: `orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && bash bench/run_bench.sh --quick"` — no extreme regression

If Ubuntu reveals failures not seen on Mac, **fix the root cause** before proceeding.

**Note**: OrbStack output can be slow/buffered. Launch long commands in background, do other work, check periodically.

## Phase 3: ClojureWasm Verification (relative path build)

1. `cd ~/ClojureWasm`
2. Temporarily edit `build.zig.zon` to use local zwasm path:
   ```zig
   .zwasm = .{
       .path = "../Documents/MyProducts/zwasm",
   },
   ```
   (Comment out the `.url` + `.hash` lines, add `.path`)
3. `zig build test` — CW compiles and all tests pass with latest zwasm
4. `bash test/e2e/run_e2e.sh` — all e2e tests pass
5. `bash test/portability/run_compat.sh` — portability tests pass
6. Run CW benchmarks if available, check no extreme regression

**Revert `build.zig.zon`** after testing (will be updated properly in Phase 5).

## Phase 4: zwasm Version Bump + Tag + Push

1. **Version bump**: Update `build.zig.zon` `.version` to match the tag:
   ```
   .version = "1.2.0",  // was "1.1.0"
   ```
2. **CHANGELOG**: Add new version section `[X.Y.Z] - YYYY-MM-DD` at the top (if `[Unreleased]` section exists, rename it; otherwise create the section from git log since last tag)
3. **Commit**: `git commit -am "Release v1.2.0"`
4. **Record benchmark**: `bash bench/record.sh --id=v1.2.0 --reason="Release v1.2.0"`
5. **Commit benchmark**: `git add bench/history.yaml && git commit -m "Record benchmark for v1.2.0"`
6. **Tag**: `git tag v1.2.0`
7. **Push**: `git push origin main --tags`
8. **Verify**: CI runs on the tag push. `release.yml` builds 3 platform binaries (macOS aarch64, Linux x86_64, Linux aarch64) and creates a GitHub Release with checksums.
9. **Wait for CI**: `gh run list --limit 3` — confirm both CI and Release workflows succeed

## Phase 5: ClojureWasm Update + Tag + Push

1. `cd ~/ClojureWasm`
2. Update `build.zig.zon` to reference the new zwasm tag:
   ```zig
   .zwasm = .{
       .url = "https://github.com/clojurewasm/zwasm/archive/v1.2.0.tar.gz",
       .hash = "...",  // zig build will fail with expected hash — copy it
   },
   ```
3. `zig build` — get the correct hash from the error, update `.hash`
4. `zig build test` — verify CW works with the tagged version
5. `bash test/e2e/run_e2e.sh` — e2e tests pass
6. Commit: `git commit -am "Update zwasm to v1.2.0"`
7. Tag CW if applicable (CW version may differ from zwasm)
8. Push: `git push origin main --tags`

## Checklist Summary

| Phase | Gate | Pass criteria |
|-------|------|---------------|
| 1 | Mac local | unit(0 fail/leak) + spec(0 fail/skip) + E2E(0 fail/leak) + compat(50/0/0) + FFI(0 failed) + bench + size (Mac ≤1.30MB / Linux ≤1.60MB / Win ≤1.80MB; mem ≤4.5MB) |
| 2 | Ubuntu OrbStack | unit(0 fail/leak) + spec(0 fail/skip) + E2E(0 fail/leak) + compat(50/0/0) + FFI(0 failed) + bench |
| 3 | CW local | CW unit + e2e + portability (local zwasm path) |
| 4 | zwasm tag | version bump + CHANGELOG + tag + push + CI green |
| 5 | CW tag | URL+hash update + CW tests pass + push |

## Lessons Learned

- **Always test real-world compat** (`run_compat.sh`). JIT bugs (OSR, back-edge, register order) only surface with real compiler output (Go, C++, Rust), not hand-written WAT.
- **Ubuntu x86_64 can differ from Mac ARM64**. The x86 JIT has its own codegen bugs (select aliasing, OSR prologue register order, division edge cases). Always verify both platforms.
- **wasm files are gitignored**. Ubuntu VM needs `build_all.sh` with WASI SDK + Rust wasm32-wasip1 target installed. CI installs these automatically but OrbStack VM requires manual setup (see `.dev/references/setup-orbstack.md`).
- **OrbStack sync**: Always rsync to VM-local storage (`~/zwasm/`) before testing. Building directly from Mac FS (`/Users/...`) is slow. Exclude `.zig-cache` and `zig-out`.
- **CI runs on tag push too**. The `release.yml` workflow triggers on `v*` tags. Don't tag until you're confident — the Release is created automatically.
- **CW hash discovery**: `zig build` with a wrong `.hash` prints the correct hash in the error message. Copy-paste it.
- **Strip before size check on Linux**. Linux ELF includes DWARF inline (~6.79 MB raw vs ~1.18 MB stripped). CI strips automatically.
