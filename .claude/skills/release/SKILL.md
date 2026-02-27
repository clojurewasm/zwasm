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
4. `bash test/e2e/run_e2e.sh --convert --summary` — 792+ pass, fail=0, leak=0
5. `bash test/realworld/run_compat.sh` — PASS=30, FAIL=0, CRASH=0 (requires `build_all.sh` first if wasm files missing)
6. `bash bench/run_bench.sh` — full benchmark suite, no regression
7. Size guard:
   - Binary (ReleaseSafe, stripped): ≤ 1.5 MB
   - Memory (sieve benchmark): ≤ 4.5 MB RSS

## Phase 2: zwasm Verification (Ubuntu x86_64 via SSH)

See `.dev/ubuntu-x86_64.md` for SSH connection and command patterns (`nix develop`).

1. Push `main` to remote: `git push origin main`
2. SSH pull: `ssh ubuntu 'bash -l -c "cd ~/zwasm && git pull --ff-only"'`
3. Unit tests: `zig build test` — all pass, 0 fail, 0 leak
4. Spec tests: `python3 test/spec/run_spec.py --build --summary` — fail=0, skip=0
5. E2E tests: `bash test/e2e/run_e2e.sh --convert --summary` — fail=0, leak=0
6. Real-world compat: `bash test/realworld/run_compat.sh` — PASS=30, FAIL=0, CRASH=0
   (needs `build_all.sh` first; requires WASI SDK + Rust wasm32-wasip1 + Go/TinyGo)
7. Benchmarks: `bash bench/run_bench.sh` — no extreme regression

If Ubuntu reveals failures not seen on Mac, **fix the root cause** before proceeding.

**Note**: Ubuntu SSH output is slow/buffered. Launch commands in background, do other work, check periodically. Never block waiting.

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
2. **CHANGELOG**: Rename `[Unreleased]` section to `[1.2.0] - YYYY-MM-DD`
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
| 1 | Mac local | unit(0 fail/leak) + spec(0 fail/skip) + E2E(0 fail/leak) + compat(30/0/0) + bench + size(≤1.5MB/≤4.5MB) |
| 2 | Ubuntu SSH | unit(0 fail/leak) + spec(0 fail/skip) + E2E(0 fail/leak) + compat(30/0/0) + bench |
| 3 | CW local | CW unit + e2e + portability (local zwasm path) |
| 4 | zwasm tag | version bump + CHANGELOG + tag + push + CI green |
| 5 | CW tag | URL+hash update + CW tests pass + push |

## Lessons Learned

- **Always test real-world compat** (`run_compat.sh`). JIT bugs (OSR, back-edge, register order) only surface with real compiler output (Go, C++, Rust), not hand-written WAT.
- **Ubuntu x86_64 can differ from Mac ARM64**. The x86 JIT has its own codegen bugs (select aliasing, OSR prologue register order, division edge cases). Always verify both platforms.
- **wasm files are gitignored**. Ubuntu needs `build_all.sh` with WASI SDK + Rust wasm32-wasip1 target + Go/TinyGo installed. CI installs these automatically but SSH environment requires manual setup.
- **CI runs on tag push too**. The `release.yml` workflow triggers on `v*` tags. Don't tag until you're confident — the Release is created automatically.
- **CW hash discovery**: `zig build` with a wrong `.hash` prints the correct hash in the error message. Copy-paste it.
- **Strip before size check on Linux**. Linux ELF includes DWARF inline (~6.79 MB raw vs ~1.18 MB stripped). CI strips automatically.
