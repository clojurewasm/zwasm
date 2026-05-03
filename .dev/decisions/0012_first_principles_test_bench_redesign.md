# 0012 — Adopt tier-provisioned hybrid architecture for the test/bench suite

- **Status**: Accepted
- **Date**: 2026-05-03
- **Author**: continue loop
- **Tags**: phase-6, test-suite, bench-suite, infrastructure,
  follows-adr-0011

## Context

ADR-0011 reopened Phase 6 and deferred the v1-asset triage
methodology to a separate decision. This ADR is that decision.

A v1 audit surfaced two facts that drive the design:

1. **v2 has no runtime-asserting runner.** All four current
   runners do parse + (optionally) validate + (optionally)
   instantiate, but none execute `assert_return` /
   `assert_trap`. This is the literal blocker for the §9.6 /
   6.2 honest close.
2. **v1 was 80% planned, 20% ad-hoc.**
   - Re-derive: spec submodule + auto-bump, by-origin BATCH
     classification, in-repo realworld source, `gate-commit.sh`
     unified entry, `flake.nix` + `versions.lock` pinning.
   - Rebuild from first principles: `bench/wasm/` mixed-origin
     flat dir, source-less binaries (`tgo_*`, `gc_*`),
     prefix-as-pseudo-hierarchy, fuzz seed missing,
     `bench/history.yaml` per-commit accretion.

User requirements from dialogue:

- (1) v2's current 4-runner / 4-dir layout is not a constraint.
- (2) Public suites must be reproducible by any contributor /
  CI; origin-based separation acceptable; aggregated entry
  point must be visible at a glance; per-origin individual
  execution desired.
- (3) Tool / platform setup hurdles must stay low; idiosyncratic
  preparation steps avoided.

## Decision

### 1. Information sources — upstream-tracked + in-repo source

- `test/spec/testsuite/` — git submodule of `WebAssembly/testsuite`,
  auto-update via v2-side workflow (re-derived from v1
  `spec-bump.yml`). Replaces v2's current vendored `test/spec/{smoke,
  wasm-1.0,wasm-2.0}/`.
- `test/spec/legacy/` — fixtures lifted from v2's existing
  `v1_carry_over/` that overlap spec testsuite (verified by content
  comparison during 6.B), kept stable across submodule bumps.
- `test/wasmtime_misc/wast/` — sparse-clone of
  `bytecodealliance/wasmtime/tests/misc_testsuite/` to
  `.cache/wasmtime_misc/`, pinned in `versions.lock`.
- `test/realworld/{c,cpp,go,rust,tinygo}/` — sources in repo,
  binaries built on demand by `scripts/build_realworld.sh` and
  also committed to `test/realworld/wasm/` for binary-only
  consumers.
- `bench/{wat,sightglass,custom}/` — sources in repo. **No
  source-less binaries.**
- Generated artifacts (wast2json output, fuzz corpora) not
  committed.
- Every fixture must be regeneratable via a single
  `scripts/regen_<asset>.sh` invocation.

### 2. Tool dependencies — three-tier model

| Tier | Tools | Required when | Build-flag opt-in |
|---|---|---|---|
| **Enforce** | zig 0.16.0, wabt, python3 | Always | (no flag) |
| **Conditional** | wasmtime, cargo+rustup, go, tinygo, wasi-sdk | Realworld rebuild OR `test-realworld-diff` | `-Dwith-realworld-rebuild=false` (default), `-Dwith-realworld-diff=false` (default); set `true` ⇒ tools required, fail-fast at build |
| **Optional** | hyperfine, bun, node | `bench-quick` / cross-runtime comparison | `-Dwith-bench-compare=false` (default); set `true` ⇒ tools required |

`zig build test-all` is sized to run green with only the Enforce
tier installed.

- **Three-host gate**: Enforce tier on all three (Mac aarch64
  + OrbStack Ubuntu + windowsmini SSH); bench steps Mac-only.
- **`versions.lock`**: human-readable pin cross-referenced by
  `flake.nix` and `install_tools.ps1`; `sync_versions.sh`
  enforces agreement with `flake.lock`.
- **Offline / restricted-network CI**: `setup_corpora.sh`
  (introduced by 6.C) wraps submodule + sparse-checkout into
  one command, caches under `.cache/`, supports `--offline`.

### 3. Directory layout — by-origin primary

```
test/
├── runners/                    cross-origin runners
│   └── wast_runtime_runner.zig (added in 6.A)
├── spec/                       upstream: WebAssembly/testsuite
│   ├── testsuite/              git submodule
│   ├── manifests/
│   ├── legacy/                 stable subset from v2 v1_carry_over
│   └── runner.zig              (kept as-is)
├── wasmtime_misc/              upstream: wasmtime/tests/misc_testsuite
│   ├── wast/{basic,reftypes,embenchen,issues,simd,proposals}/
│   └── manifests/
├── realworld/                  in-repo source + committed binaries
│   ├── {c,cpp,go,rust,tinygo}/ sources
│   ├── wasm/                   binaries
│   └── {runner,run_runner,diff_runner}.zig  (kept as-is)
├── c_api/                      in-repo
├── wasi/                       in-repo (runner.zig kept as-is)
├── fuzz/                       generated; deterministic seed registry
└── threads/                    Phase 9+ placeholder
```

```
bench/
├── wat/                        v2-authored
├── sightglass/                 upstream: Bytecode Alliance sightglass
├── embenchen/                  Phase 11+ placeholder
├── custom/                     v2-authored Zig + WAT
├── runners/                    run_bench.sh + compare_runtimes.sh (Phase 7+ placeholder)
├── results/
│   ├── recent.yaml             rolling per-commit (gitignored)
│   └── history.yaml            phase-boundary append-only (committed)
└── README.md
```

**Runner placement rule**: origin-agnostic runners → `test/runners/`;
origin-specific runners stay in their origin directory. Existing
v2 runners are origin-specific and stay where they are.

### 4. File naming — directory hierarchy replaces prefix

v1's `tgo_*.wasm`, `shootout-*.wasm`, `gc_*.wasm`,
`BATCH3_embenchen_*.wast` prefix-as-pseudo-hierarchy is rejected.
Origin lives in directory paths; filenames carry only fixture-
local identity.

```
v1 (rejected):    bench/wasm/tgo_fib.wasm
v2 (this ADR):    bench/tinygo/wasm/fib.wasm

v1 (rejected):    test/e2e/wast/embenchen_fannkuch.wast
v2 (this ADR):    test/wasmtime_misc/wast/embenchen/fannkuch.wast
```

### 5. Entry points — `zig build` aggregation

```
zig build test-all                    aggregate (Enforce tier only)
├── test                              src/ unit tests
├── test-spec                         test/spec/
├── test-wasmtime-misc                test/wasmtime_misc/
├── test-realworld                    parse smoke
├── test-realworld-run                end-to-end
├── test-realworld-diff               (Conditional tier — wasmtime)
├── test-c-api
└── test-wasi

zig build test-fuzz                   Phase 7+ placeholder; NOT in test-all
zig build bench-quick                 (Optional tier — hyperfine)
zig build bench-full                  Phase 7+; cross-runtime comparison
zig build lint                        zlinter (Mac-only, ADR-0009)
```

Each step is individually invocable (`zig build test-spec
--filter add`), composes via `dependOn`, respects build flags.

`scripts/{gate_commit.sh, gate_merge.sh}` stay as **hook
plumbing only** — invoke `zig build` steps + three-host
orchestration, no embedded test logic.

### 6. Phase 6 reopen work items

```
6.A (runtime-asserting runner + per-instr trace)
 │
 ├─→ 6.B (test/ restructure + 4 fixtures migration)
 │    │
 │    └─→ 6.C (vendor wasmtime_misc BATCH1-3 ≈ 55 fixtures)
 │         │
 │         └─→ 6.D (wire 6.C into test-all via 6.A runner)
 │              │
 │              └─→ 6.E (interp behaviour bug fixes)
 │                   │
 │                   ├─→ 6.F (test-realworld-diff 30+ matches)  ─┐
 │                   ├─→ 6.G (ClojureWasm guest e2e)              ├─→ 6.J
 │                   └─→ 6.H (bench honest baseline)              │
 │                                                                │
 └─→ 6.I (bench/ restructure + sightglass)  ──────────────────────┘
       (parallel to 6.E〜6.H)
```

| # | Action |
|---|---|
| **6.A** | Add `test/runners/wast_runtime_runner.zig`. v1 `e2e_runner.zig` (844 LOC) is textbook reference; re-derived for v2 Zone shape. Capability scope: assert_return / assert_trap / assert_invalid / assert_malformed / assert_unlinkable / assert_uninstantiable / assert_exhaustion / register / action / module + cross-module Store sharing + per-instr execution trace. Thread block + NaN canonical / arithmetic asserts deferred. |
| **6.B** | Restructure `test/` per §3. Migrate 4 `v1_carry_over/` fixtures: `add` and `f64-copysign` → `test/spec/legacy/` if spec-overlapping (verify by content), else → `test/wasmtime_misc/wast/basic/`; `div-rem` and `empty` → `test/wasmtime_misc/wast/basic/`. Add `test/spec/legacy/` to layout. Update `scripts/gate_merge.sh` and ROADMAP §A13 (load-bearing edit citing this ADR). |
| **6.C** | Vendor wasmtime_misc BATCH1-3 (≈55 fixtures: basic + reftypes + embenchen + issues) into `test/wasmtime_misc/wast/{basic,reftypes,embenchen,issues}/`. BATCH4 (SIMD), BATCH5 (proposals) defer to feature phases. Introduce `scripts/setup_corpora.sh`. |
| **6.D** | Wire 6.C corpus into `test-wasmtime-misc` step + `test-all` aggregate via 6.A runner. Existing parse-only / instantiate-only runners kept as-is (the runtime-asserting runner is **added**, not a replacement). |
| **6.E** | Fix root cause of the 39 trap-mid-execution realworld fixtures using 6.A's per-instr trace. Move fixtures from trap-bucket to completion-bucket. Sequenced after 6.A + 6.D. |
| **6.F** | `test-realworld-diff` 30+ byte-for-byte matches against wasmtime (original §9.6 / 6.2). Re-add `test-realworld-diff` to `test-all`. Sequenced after 6.E. |
| **6.G** | ClojureWasm guest end-to-end via `build.zig.zon` `path = ...` (original §9.6 / 6.3). Parallel with 6.F after 6.E. |
| **6.H** | Bench honest-baseline migration: introduce `bench/results/{recent,history}.yaml` per §7; move existing `bench/baseline_v1_regression.yaml` content to `history.yaml` as "Phase 6 reopen revert" entry, delete old file; regenerate honest baseline post-6.E and append as "Phase 6 close baseline" entry. Sequenced after 6.E. |
| **6.I** | `bench/` restructure per §3; vendor 5 sightglass benchmarks with in-repo C source + documented build script. Reject v1's TinyGo binary-only and gc_* source-less artifacts. Parallel with 6.E〜6.H. |
| **6.J** | Phase 6 close gate: (i) `zig build test-all` green three hosts; (ii) `zig build bench-quick` green Mac-only; (iii) `audit_scaffolding` pass; (iv) Phase Status widget flip 6 → DONE / 7 → IN-PROGRESS; (v) handover retarget §9.7 / 7.0. |

**Out of Phase-6 scope**:

| Item | Defer to |
|---|---|
| BATCH4 SIMD wast | Phase 9 |
| BATCH5 proposal wast (function-ref / GC / threads / memory64 / tail-call) | Phase 10 |
| `test/threads/rust-atomic/` | Phase 9+ |
| `test/fuzz/` deterministic-seed integration | Phase 7 Step 0 |
| Embenchen full perf suite | Phase 11 |
| `test/c_api/` conformance expansion | Phase 13 |
| Cross-runtime bench comparison | Phase 7+ |

### 7. Bench history accretion suppression

- `bench/results/recent.yaml` — gitignored, rolling per-commit.
- `bench/results/history.yaml` — committed, appended **only at
  Phase boundaries**; ROADMAP §9 Phase Status widget references
  entries by phase number.
- `run_bench.sh` writes `recent.yaml` by default; `--phase-record`
  flag writes `history.yaml`. New `record_phase_bench.sh` wraps
  the flag with phase-tag metadata.
- `.gitignore` updated for `bench/results/recent.yaml`.

**Migration of existing v2 bench files in 6.H**:

| File | Action |
|---|---|
| `bench/baseline_v1_regression.yaml` | Content → `history.yaml` "Phase 6 reopen revert" entry; file deleted |
| `bench/history.yaml` | Existing entries → `bench/results/history.yaml`; old file deleted |

## Alternatives considered

- **Source-First Monorepo**: snapshot all upstream into v2.
  Rejected: forfeits upstream tracking automation; repo size
  grows; spec drift becomes invisible.
- **Mode-First Layout** (`test/{parse,validate,instantiate,
  runtime}/`): rejected — same fixture runs in multiple modes,
  forces symlink / duplication / manifest-layer complexity.
- **Spec-Bench Bipolar** (separate `test/` and `bench/`
  worlds): rejected — splits the unified entry point requirement
  (2) asks for; degraded variant of this ADR.
- **Defer restructure to Phase 11**: rejected — restructure-
  then-vendor is cheaper than vendor-then-restructure.

## Consequences

### Positive
- Requirements (1)(2)(3) all satisfied (zero-base, by-origin +
  aggregated entry, low-tier-1-hurdle).
- v1's bench/wasm mixing, prefix-as-hierarchy, source-less
  binaries, and ad-hoc bench history dissolve structurally.
- The runtime-asserting runner gap (keystone blocker for §9.6 /
  6.2 honest close) is named as the first action.

### Negative
- Phase 6 reopen has 10 explicit work items; 6.E and 6.F carry
  genuine investigative uncertainty.
- `versions.lock` and `setup_corpora.sh` are new infrastructure.
- `test/v1_carry_over/` directory is dissolved; downstream
  references (build.zig, gate_merge.sh, ROADMAP §A13, handover)
  need updating in 6.B.

### Neutral / follow-ups
- **ADR-0013 (blocking prerequisite for 6.A)** — runtime-
  asserting WAST runner detailed design. Drafted when 6.A is
  active.
- **ADR-0014 (parallel to 6.I, optional)** — bench infra
  (sightglass vendoring, fixture-selection criteria). Filed
  only if 6.I surfaces load-bearing decisions.
- `versions.lock` introduction inline in 6.B unless it
  surfaces a load-bearing decision (then ADR-0015).
- `audit_scaffolding` runs after 6.B and after 6.J.
- `/continue` autonomous loop re-arms once 6.A is the active
  task in handover.

## References

- ROADMAP §9.6 (Phase 6, reopened by ADR-0011, scope defined here)
- ROADMAP §A13 (v1 regression suite merge gate — needs rewording per 6.B)
- ROADMAP §4.6 (build flag policy — extended by §2 tier flags)
- ROADMAP §A12 (no pervasive build-time `if` — bench tier-3 conditional skip aligns)
- ROADMAP §18 (amendment policy — this ADR is §18.2 precondition for 6.B's ROADMAP edit)
- ADR-0008 (Phase 6 charter — operationalised here)
- ADR-0011 (Phase 6 reopen — this ADR is its Decision §6 follow-up)
- ADR-0013 (forthcoming — runtime-asserting WAST runner design)
- ADR-0014 (forthcoming, optional — bench infra expansion)
- `.claude/rules/no_copy_from_v1.md` (re-derivation discipline for 6.A)
- `.claude/rules/textbook_survey.md` (Step 0 Survey for each 6.x)
