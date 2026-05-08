# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.8 task table — Phase 8 active.
3. `.dev/debt.md` — D-054 `blocked-by` 8a.1-d/e + 8a.5; 9 other `blocked-by:` rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain.
5. `.dev/decisions/0033_pass_trace_extension.md` (8a.1 design landed) +
   `0028_diagnostic_m3_trace_ringbuffer.md` (parent).
6. `.dev/decisions/0021_arm64_prologue_split.md` (relevant for 8a.2 prologue inject).

## Current state — Phase 8 / §9.8a / 8a.2 (JIT-execution sentinel)

§9.8a / 8a.1 closed: per-pass diagnostic two-channel design
(ringbuffer Category.pass + ZirFunc.pass_diagnostics slot)
landed across `93da390` (ADR-0033 design) → `0b6408c` (trace.zig
passEvent API) → `26b4fcf` (slot + types) → `af0fb5a` (compile.zig
pipeline wiring + integration test).

直近 commits (latest at top):

- (this commit) chore(p8): mark §9.8a / 8a.1 [x]; retarget at
  8a.2 JIT-execution sentinel.
- `af0fb5a` feat(p8): §9.8a / 8a.1-d/e — wire passEvent into
  compile.zig pipeline (closes 8a.1).
- `26b4fcf` feat(p8): §9.8a / 8a.1-c — ZirFunc.pass_diagnostics
  slot per ADR-0033.
- `0b6408c` feat(p8): §9.8a / 8a.1-b — trace.zig passEvent API.

3-host gate at `af0fb5a`:
- Mac aarch64: green (test-all + lint).
- windowsmini Win x86_64: green (212/0/20 spec_assert).
- OrbStack Linux x86_64: 1 known D-054 FAIL (`as-loop-broke`,
  OrbStack-only); +1 test correctly skipped under default
  `-Dtrace-ringbuffer=false`.

**Phase 8 status**: §9.8 / 8.0-8.4 [x]; 8a.1 [x]; **§9.8a /
8a.2 NEXT**. Phase 8 残 rows = 8a.2-8a.6 + 8b.1-8b.6.

## Active task — §9.8a / 8a.2: JIT-execution sentinel **NEXT**

Per ROADMAP §9.8a row text: JIT block prologue gets a small
inject (counter increment / sentinel store at a known runtime
offset) so post-execution checks can prove the JIT-emitted body
actually ran (vs. compile-passed but never invoked). The
`realworld_run_jit` runner reads the counter post-call and
reports `RUN-JIT-VERIFIED` vs `RUN-JIT-COMPILE-ONLY-PATH`.
Resolves the v1-era recurring "is the JIT actually running?"
confusion. Delta on prologue size is at most 4-8 bytes (ARM64
single LDR-ADD-STR or x86_64 single INC-MEM); negligible for
hot-loop benchmarks.

Suggested chunk plan:

| #     | Description                                              | Status   |
|-------|----------------------------------------------------------|----------|
| 8a.2-a | Step 0 survey + design: where does the sentinel counter live (JitRuntime field? threadlocal? trace ringbuffer Category.exec?); both-arch prologue inject shape | **NEXT** |
| 8a.2-b | ARM64 prologue inject + unit test                       | [ ]      |
| 8a.2-c | x86_64 prologue inject + unit test                      | [ ]      |
| 8a.2-d | realworld_run_jit runner reads counter; new RUN-JIT-VERIFIED status | [ ]      |
| 8a.2-e | 3-host gate; close 8a.2 [x]                             | [ ]      |

After 8a.2 closes: 8a.3 (bench-delta-per-commit), 8a.4
(`ZWASM_DIAG` env var), 8a.5 (D-053 + D-054 cap-removal
investigation), 8a.6 (8a boundary audit).

Then §9.8b begins: 8b.1 (Coalescer, bench-delta required) →
8b.2 (Regalloc upgrade) → 8b.3 (AOT skeleton) → 8b.4 (≥10%
aggregate) → 8b.5 (boundary audit) → 8b.6 (open §9.9).

## Open structural debt (pointers — current; full list in `.dev/debt.md`)

- **D-054** (`blocked-by: 8a.1-d/e + 8a.5`) — OrbStack-only
  as-loop-broke. 8a.1-d/e barrier dissolved this commit; only
  8a.5 remains. Will reframe at next chore commit if 8a.5 still
  the only block.
- 9 `blocked-by:` rows — D-007 / D-010 / D-016 / D-018 / D-020
  / D-021 / D-022 / D-026 / D-028 / D-052; barriers all hold
  this resume.

D-053 promoted to ROADMAP row §9.8a / 8a.5 per ADR-0032.

**Phase**: Phase 8 (JIT optimisation foundation 🔒、ADR-0019)。
**Branch**: `zwasm-from-scratch`。
