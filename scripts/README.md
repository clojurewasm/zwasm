# scripts/

Unified entry points for the zwasm Commit Gate, Merge Gate, and bench
runner. Identical commands work on macOS, Linux, and Windows under
Git Bash. The toolchain comes from `flake.nix` on Linux/macOS (via
direnv) and from `scripts/windows/install-tools.ps1` on Windows.

## Layout

```
scripts/
├── lib/
│   └── versions.sh          # bash loader for .github/versions.lock
├── sync-versions.sh         # consistency check: versions.lock ↔ flake.nix
├── gate-commit.sh           # CLAUDE.md Commit Gate (steps 1-8)
├── gate-merge.sh            # CLAUDE.md Merge Gate (Commit + sync + CI)
├── run-bench.sh             # wrapper around bench/run_bench.sh
├── record-merge-bench.sh    # post-merge bench/history.yaml row (Mac only)
└── windows/
    └── install-tools.ps1    # provisions Zig/wasm-tools/wasmtime/WASI SDK
                             # on Windows by reading versions.lock
```

## Daily use

```bash
bash scripts/gate-commit.sh             # before committing
bash scripts/gate-merge.sh              # before merging (run on Mac AND
                                        # Ubuntu OrbStack — see CLAUDE.md)
bash scripts/run-bench.sh --quick       # quick bench
bash scripts/sync-versions.sh           # confirm pin consistency
bash scripts/record-merge-bench.sh      # post-merge: append history.yaml row
                                        # (auto-skips on Linux/Windows)
```

`gate-commit.sh --help` lists the per-step skip flags. Steps map 1:1
to the CLAUDE.md checklist; the gate runners are intentionally thin
so the source of truth stays in CLAUDE.md.

## Rationale

See `.dev/decisions.md` D136 for the unified-gate design and the
single-source-of-truth model (flake.nix → versions.lock).
