# zwasm Reliability Improvement — Plan

> Updated: 2026-02-26
> Principles & branch strategy: `@./.claude/rules/reliability-work.md`
> Progress: `@./.dev/reliability-handover.md`

## Goal

Make zwasm **undeniably correct and fast** on Mac (aarch64) and Ubuntu (x86_64).
zwasm philosophy: **100% spec compliance, runs everything wasmtime runs, lightweight yet wasmtime-competitive speed.**

## Priority Order

| Priority | Meaning | Criteria |
|----------|---------|----------|
| **A** | Correctness | spec/test/real-world fully working on arm64+amd64 |
| **B** | Feature completeness | Implement missing features (GC JIT, etc.) |
| **C** | Performance | Target wasmtime 1x, accept 1.5x, allow 2-3x for single-pass limits |

## Completed Phases

| Phase | Content | Status |
|-------|---------|--------|
| A-F | Environment/compilation/compat/E2E/bench/analysis | Done |
| G | Ubuntu cross-platform | Done — spec 62,158 (100%) |
| I | E2E 100% + FP correctness | Done — 792/792 |
| J | x86_64 JIT bug fixes | Done |
| K.old | JIT opcode coverage, self-call, div-const | Done |

## Active: Plan A — Incremental regression fix + feature implementation

### Phase 1: rw_c_string hang fix (Priority A — Correctness)

**Symptom**: zwasm hangs on rw_c_string (60s timeout). wasmtime runs in 9.3ms.
**Cause**: Introduced at ee5f585 (OSR). Worked fine at 22859e2 (21ms).
**Approach**: Investigate OSR back-edge detection or guard function misjudgment.

Verification:
- `./zig-out/bin/zwasm run test/realworld/wasm/c_string_processing.wasm` completes normally
- `zig build test` pass, spec pass, no benchmark regression
- **Record**: `bash bench/record.sh --id=P1 --reason="Fix rw_c_string hang"`

### Phase 2: nbody FP cache fix (Priority C — Regression)

**Symptom**: nbody 43.8ms (1.99x wasmtime). Was 8-12ms (0.5x) before be466a0.
**Cause**: be466a0 "Fix JIT FP precision: getOrLoad must check dirty FP cache first"
  — correctness fix is valid, but implementation over-evicts FP cache.
**Approach**: Restrict eviction to rd==rs1 case only. Maintain correctness.
**Target**: Restore to 10-15ms (≤0.7x wasmtime).

Verification:
- nbody ≤ 15ms, spec pass, no regression on other benchmarks
- **Record**: `bash bench/record.sh --id=P2 --reason="Fix nbody FP cache regression"`

### Phase 3: rw_c_math re-measure (Priority C) — ACCEPTED AS EXCEPTION

**Symptom**: 58ms (4.92x wasmtime 11.8ms). Previous 16.4ms was anomalous measurement.
**Root cause**: c_math_compute has a single hot function (func#5) with 1381 IR instrs,
  136 vregs, 36 locals. Single-pass regalloc produces 876 STRs + 426 LDRs + 265 FMOVs
  out of 3323 total ARM64 instructions (38% memory traffic). wasmtime uses graph-coloring
  regalloc2 which handles 136 vregs efficiently.
**Decision**: Accept as single-pass regalloc limitation (like st_matrix).
  No further optimization feasible without multi-pass register allocator.

Verification:
- **Record**: `bash bench/record.sh --id=P3 --reason="Re-measure: accept as regalloc limit"`

### Phase 4: GC JIT basic implementation (Priority B — Feature)

**Symptom**: gc_alloc 1.79x, gc_tree 4.40x. GC opcodes fall back to interpreter.
**Approach**: JIT-compile struct.new, struct.get, struct.set, array.new, array.get, array.set.
  GC collection logic does not affect JIT codegen — just emit load/store for
  struct/array memory layout.
**Target**: gc_alloc ≤1.5x, gc_tree ≤2x.

Verification:
- GC spec tests pass, unit tests pass
- **Record**: `bash bench/record.sh --id=P4 --reason="GC JIT basic opcodes"`

### Phase 5: st_matrix — accept as exception (Priority C — Single-pass limit)

**Symptom**: 296ms (3.23x wasmtime 92ms). 35 vregs, fundamental single-pass regalloc limit.
  cranelift uses graph-coloring regalloc for optimal spill placement.
**Decision**: Accept ≤3.5x. Try LRU eviction improvements if feasible,
  but 1.5x is not realistic for single-pass.
**Official exception**: Phase H Gate condition 6 exempts st_matrix.

---

## Phase H Gate — Entry Criteria

**Phase H may NOT begin until ALL of the following are satisfied.**

| # | Condition | Verification |
|---|-----------|-------------|
| 1 | E2E: **778/778 (100%)** | Mac: e2e runner 0 failures |
| 2 | Real-world Mac: **all PASS** | `bash test/realworld/run_compat.sh` exits 0 |
| 3 | Real-world Ubuntu: **all PASS with JIT** | SSH same |
| 4 | Spec Mac: **62,158/62,158** | `python3 test/spec/run_spec.py --build --summary` |
| 5 | Spec Ubuntu: **62,158/62,158** | SSH same |
| 6 | Benchmarks Mac: **≤1.5x wasmtime** | `bash bench/compare_runtimes.sh` |
|   | Exception: st_matrix ≤3.5x (single-pass regalloc limit) | |
| 7 | Benchmarks Ubuntu: **≤1.5x wasmtime** (same exception) | SSH same |
| 8 | Unit tests: **Mac + Ubuntu PASS** | `zig build test` |
| 9 | Benchmark regression: **none vs history.yaml** | `bash bench/run_bench.sh` |

---

## Phase H: Comprehensive Documentation Audit (LAST)

Begins only after Phase H Gate passes.
Audit **every external-facing document** — verify accuracy, delete stale content, add missing info, update numbers.

### Procedure

For each file: read → compare against actual codebase/test results → update/delete/add as needed → commit.

### Checklist (41 files)

#### Root (6 files)
- [x] `README.md` — updated benchmarks, feature counts, binary/memory sizes
- [x] `CHANGELOG.md` — added [Unreleased] section with reliability improvements
- [x] `LICENSE` — OK (2026, correct copyright)
- [x] `SECURITY.md` — updated version support, DoS scope
- [x] `CONTRIBUTING.md` — updated test counts, added missing source files
- [x] `CODE_OF_CONDUCT.md` — OK

#### docs/ (5 files)
- [x] `docs/usage.md` — OK (accurate)
- [x] `docs/security.md` — fixed resource exhaustion text, DoS section
- [x] `docs/errors.md` — OK
- [x] `docs/api-boundary.md` — OK
- [x] `docs/audit-36.md` — updated binary size, test count

#### mdBook English — book/en/src/ (13 files)
- [x] `SUMMARY.md` — OK
- [x] `introduction.md` — updated binary/memory sizes
- [x] `getting-started.md` — OK
- [x] `cli-reference.md` — OK
- [x] `embedding-guide.md` — OK
- [x] `faq.md` — OK
- [x] `architecture.md` — updated LOC, opcode count, added component model files
- [x] `spec-coverage.md` — OK (numbers match)
- [x] `security-model.md` — OK
- [x] `performance.md` — updated benchmarks 16/29, binary/memory, benchmark layers
- [x] `memory-model.md` — OK
- [x] `comparison.md` — updated binary size, size ratio
- [x] `contributing.md` — updated E2E count, added realworld tests

#### mdBook Japanese — book/ja/src/ (13 files)
- [x] `SUMMARY.md` — OK
- [x] `introduction.md` — mirrored EN update
- [x] `getting-started.md` — OK
- [x] `cli-reference.md` — OK
- [x] `embedding-guide.md` — OK
- [x] `faq.md` — OK
- [x] `architecture.md` — mirrored EN update
- [x] `spec-coverage.md` — OK
- [x] `security-model.md` — OK
- [x] `performance.md` — mirrored EN update
- [x] `memory-model.md` — OK
- [x] `comparison.md` — mirrored EN update
- [x] `contributing.md` — mirrored EN update

#### GitHub .github/ (4 files)
- [x] `FUNDING.yml` — OK
- [x] `ISSUE_TEMPLATE/bug_report.yml` — OK
- [x] `ISSUE_TEMPLATE/feature_request.yml` — OK
- [x] `workflows/book.yml` — OK
