# bench/

Benchmark history (append-only) and runner data.

## Layout

```
bench/
├── README.md          # this file
├── results/
│   ├── history.yaml   # committed, append-only, phase-boundary entries only
│   └── recent.yaml    # gitignored, rolling per-commit
├── runners/           # bench wasm samples (Phase 10+)
│   └── src/           # source for runners (committed)
└── fixtures/          # bench-specific data files (Phase 10+)
```

The `results/` split (committed `history.yaml` vs gitignored
`recent.yaml`) was introduced 2026-05-04 per §9.6 / 6.H +
ADR-0012 §7. The two-file approach prevents per-commit bench
runs from inflating git history; only phase-boundary results are
preserved long-term.

## Cadence (ROADMAP §12.4)

- **Local manual** (Phases 0–12): `bash scripts/run_bench.sh
  [--quick]` writes `bench/results/recent.yaml`. `bash
  scripts/record_merge_bench.sh [--phase-record] [--quick]`
  appends one row to `bench/results/history.yaml` when
  `--phase-record` is set; without that flag it still writes
  to `recent.yaml`.
- **Per-merge automated** (Phase 13+): GitHub Actions matrix
  records on `macos-15`, `ubuntu-22.04`, `windows-2022`. Phase-
  boundary commits trigger `--phase-record`.
- **Manual baselines**: workflow_dispatch in Phase 13+, or local
  `bash scripts/record_merge_bench.sh --phase-record` + manual
  commit.

## Schema (ROADMAP §12.3)

```yaml
- date: 2026-XX-XXTHH:MM:SSZ
  commit: <full SHA>
  arch: aarch64-darwin | x86_64-linux | x86_64-windows
  reason: "<phase-tag>: <one-line>"
  runs: 5
  warmup: 3
  benches:
    - name: <bench-name>
      median_ms: 12.34
      stddev_ms: 0.45
```

`bench/results/history.yaml` is append-only (ROADMAP §A9). Rows
are added by `scripts/record_merge_bench.sh --phase-record` and
the Phase-13+ CI bench-record job. Never edit historical rows.

`bench/results/recent.yaml` is gitignored and overwritten on
every local run.

## No fixed numeric targets (ROADMAP §12.1)

Per-phase numeric ratios (e.g. "within 1.5× of wasmtime") are
deliberately not set. Goodhart's law: a numeric target distorts
behaviour toward the number, not the underlying goal. Comparison
against reference runtimes (wasm3, wasmtime baseline, wasmtime
cranelift, wasmer singlepass) is recorded but not gated.

## Current status (post-§9.6 / 6.H, pre-Phase 11)

`bench/results/history.yaml` carries the pre-Phase-6-revert
trap-time baseline (preserved per ADR-0011 §3). Real numbers
against the post-6.K interpreter land at Phase 11 when
`scripts/run_bench.sh` + `record_merge_bench.sh` finish their
stub→hyperfine wiring (their TODO p11 markers). Until then, the
file's role is structural — proving the layout per ADR-0012 §7
holds.
