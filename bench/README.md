# bench/

Benchmark history (append-only) and runner data.

## Layout

```
bench/
├── README.md          # this file
├── history.yaml       # append-only per-merge records
├── runners/           # bench wasm samples (Phase 10+)
│   └── src/           # source for runners (committed)
└── fixtures/          # bench-specific data files (Phase 10+)
```

## Cadence (ROADMAP §12.4)

- **Local manual** (Phases 0–12): `bash scripts/run_bench.sh
  [--quick]` against a target. `bash scripts/record_merge_bench.sh
  [--quick]` appends one row to `bench/history.yaml`.
- **Per-merge automated** (Phase 13+): GitHub Actions matrix
  records on `macos-15`, `ubuntu-22.04`, `windows-2022`.
- **Manual baselines**: workflow_dispatch in Phase 13+, or local
  `bash scripts/record_merge_bench.sh` + manual commit.

## Schema (ROADMAP §12.3)

```yaml
- date: 2026-XX-XXTHH:MM:SSZ
  commit: <full SHA>
  arch: aarch64-darwin | x86_64-linux | x86_64-windows
  reason: "Record benchmark for <subject>"
  runs: 5
  warmup: 3
  benches:
    - name: <bench-name>
      median_ms: 12.34
      stddev_ms: 0.45
```

This file is append-only (ROADMAP §A9). Rows are added by
`scripts/record_merge_bench.sh` and the Phase-13+ CI bench-record
job. Never edit historical rows.

## No fixed numeric targets (ROADMAP §12.1)

Per-phase numeric ratios (e.g. "within 1.5× of wasmtime") are
deliberately not set. Goodhart's law: a numeric target distorts
behaviour toward the number, not the underlying goal. Comparison
against reference runtimes (wasm3, wasmtime baseline, wasmtime
cranelift, wasmer singlepass) is recorded but not gated.
