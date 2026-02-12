---
name: release
description: Full release process for tagging zwasm and updating ClojureWasm downstream
disable-model-invocation: true
---

# Release: zwasm + ClojureWasm

Full release process. Only run when explicitly instructed by the user.
Version argument: `/release v0.13.0`

**Failure policy**: Stop at the failed phase, report to user.
Fix the issue (new commit on zwasm or CW), then re-run from the failed phase.
Never tag or push until all prior phases pass.

## Phase 1: zwasm Verification (Mac)

1. Ensure on `main` branch with all feature branches merged
2. `zig build test` — all unit tests pass
3. `python3 test/spec/run_spec.py --summary` — spec tests 100%
4. `bash bench/run_bench.sh` — full benchmark suite, no regression

## Phase 2: zwasm Verification (Ubuntu x86_64 via SSH)

See `.dev/ubuntu-x86_64.md` for SSH connection and command patterns (`nix develop`).

1. Push `main` to remote: `git push origin main`
2. SSH pull with submodules: `git pull --recurse-submodules` (+ `git submodule update --init` if first time)
3. Convert spec tests: `bash test/spec/convert.sh` (uses submodule at `test/spec/testsuite/`)
4. `zig build test` — all tests pass on x86_64
5. `python3 test/spec/run_spec.py --summary` — spec tests pass
6. `bash bench/run_bench.sh` — benchmarks, no extreme regression

If Ubuntu reveals failures not seen on Mac, **fix the root cause** before proceeding.

## Phase 3: ClojureWasm Verification (relative path build)

1. `cd ~/ClojureWasm`
2. Ensure `build.zig.zon` uses relative path to local zwasm (for testing)
3. `zig build test` — CW compiles and all tests pass with latest zwasm
4. `bash test/e2e/run_e2e.sh` — all e2e tests pass
5. `bash test/portability/run_compat.sh` — portability tests pass
6. Run CW benchmarks if available, check no extreme regression

## Phase 4: zwasm Tag + Push

1. **Version gate**: Verify `build.zig.zon` `.version` matches the tag (e.g. tag `v0.13.0` → `.version = "0.13.0"`). If mismatched, update `.version`, commit, then proceed.
2. Record full benchmark: `bash bench/record.sh --id=$ARGUMENTS --reason="Release $ARGUMENTS"`
3. Commit benchmark results: `git add bench/history.yaml && git commit -m "Record benchmark for $ARGUMENTS"`
4. Tag: `git tag $ARGUMENTS`
5. Push: `git push origin main --tags`

## Phase 5: ClojureWasm Tag + Push

1. Update `build.zig.zon` to reference the new zwasm tag (GitHub URL + hash)
2. `zig build test` — verify it still works with the tagged version
3. Record CW benchmark history if applicable
4. Commit: `git commit -am "Update zwasm to $ARGUMENTS"`
5. Tag CW (version may differ from zwasm)
6. Push: `git push origin main --tags`
