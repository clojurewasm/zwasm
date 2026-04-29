# Ubuntu x86_64 Testing Guide (OrbStack)

How to run zwasm tests on the local OrbStack Ubuntu x86_64 VM.

## Connection

```bash
# Interactive shell
orb shell my-ubuntu-amd64

# One-shot command (used by Claude Code)
orb run -m my-ubuntu-amd64 bash -lc "COMMAND"
```

Claude Code uses stateless one-shot execution — each `orb run` starts a fresh shell.
Always use `bash -lc` to load `.bashrc` (PATH for zig, wasmtime, etc.).

## Sync Project

Rsync from Mac filesystem to VM-local storage for build performance:

```bash
orb run -m my-ubuntu-amd64 bash -lc "
  rsync -a --delete \
    --exclude='.zig-cache' --exclude='zig-out' \
    '/Users/shota.508/Documents/MyProducts/zwasm/' ~/zwasm/
"
```

Run sync before each test session to pick up latest changes.

## Test Commands

All commands run inside the VM at `~/zwasm/`:

```bash
# Whole Commit Gate (preferred — same wrapper as Mac/Windows)
orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && bash scripts/gate-commit.sh"

# Whole Merge Gate (Mac runs this too; gh CLI must be authed in the VM)
orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && bash scripts/gate-merge.sh"

# Individual steps when iterating:
orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && zig build test"
orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && python3 test/spec/run_spec.py --build --summary"
orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && python3 test/e2e/run_e2e.py --convert --summary"
orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && export WASI_SDK_PATH=/opt/wasi-sdk && python3 test/realworld/build_all.py && python3 test/realworld/run_compat.py"
orb run -m my-ubuntu-amd64 bash -lc "cd ~/zwasm && bash scripts/run-bench.sh --quick"
```

## Expected Results (Merge Gate)

| Suite      | Expectation                       |
| ---------- | --------------------------------- |
| Unit tests | all pass, 0 fail, 0 leak         |
| Spec tests | 62,263/62,263 (100%), 0 skip      |
| E2E        | 796/796, 0 fail, 0 leak          |
| Real-world | PASS=50, FAIL=0, CRASH=0         |
| Benchmarks | Ubuntu-vs-Ubuntu no regression (CI) |

## Known Issues

- **Debug builds**: 11 tail-call tests timeout on Ubuntu (Rosetta overhead).
  Use ReleaseSafe for spec tests (the test scripts handle this automatically).
- **Long-running output**: SSH/orb run output can be slow/buffered.
  For long tests, launch in background and check periodically.
