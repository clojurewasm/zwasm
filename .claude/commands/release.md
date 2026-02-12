# Release: zwasm + ClojureWasm

Full release process for tagging zwasm and updating ClojureWasm downstream.
Only run when explicitly instructed by the user.

## Phase 1: zwasm Verification (Mac)

1. Ensure on `main` branch with all feature branches merged
2. `zig build test` — all unit tests pass
3. `python3 test/spec/run_spec.py --summary` — spec tests 100%
4. `bash bench/run_bench.sh` — full benchmark suite, no regression

## Phase 2: zwasm Verification (Ubuntu x86_64 via SSH)

1. Push `main` to remote: `git push origin main`
2. SSH to Ubuntu box (see `.dev/ubuntu-x86_64.md` for connection info)
3. `git pull && zig build test` — all tests pass on x86_64
4. `python3 test/spec/run_spec.py --summary` — spec tests pass
5. `bash bench/run_bench.sh` — benchmarks, no extreme regression

## Phase 3: zwasm Tag + Push

1. Record full benchmark: `bash bench/record.sh --id=vX.Y.Z --reason="Release vX.Y.Z"`
2. Tag: `git tag vX.Y.Z`
3. Push: `git push origin main --tags`

## Phase 4: ClojureWasm Update (relative path build)

1. `cd ~/ClojureWasm`
2. Ensure `build.zig.zon` uses relative path to local zwasm (for testing)
3. `zig build test` — CW compiles and all tests pass with latest zwasm
4. `bash test/e2e/run_e2e.sh` — all e2e tests pass
5. `bash test/portability/run_compat.sh` — portability tests pass
6. Run CW benchmarks if available, check no extreme regression

## Phase 5: ClojureWasm Tag + Push

1. Update `build.zig.zon` to reference the new zwasm tag (GitHub URL + hash)
2. `zig build test` — verify it still works with the tagged version
3. Record CW benchmark history if applicable
4. Commit: `git commit -am "Update zwasm to vX.Y.Z"`
5. Tag: `git tag vX.Y.Z` (CW version, may differ from zwasm version)
6. Push: `git push origin main --tags`
