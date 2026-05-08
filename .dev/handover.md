# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.8 task table — Phase 8 active.
3. `.dev/debt.md` — D-054 + D-055 `blocked-by:` chain; 9 other rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: hoist-vreg-semantic, regalloc-pool-size-mismatch, w54-class).
5. `.dev/decisions/0031_zir_hoist_pass.md` (ADR-0031 hoist design + cap=4 amend).
6. `.dev/decisions/0033_pass_trace_extension.md` + `0034_jit_execution_sentinel.md`
   (8a.1 + 8a.2 observability infra; the read-side for 8a.5).

## Current state — Phase 8 / §9.8a / 8a.5-c (fix br_table post-hoist UnsupportedOp)

§9.8a / 8a.1-8a.4 closed. The four foundation rows landed
across this session arc. Now the substantive 8a.5 row begins:
the cap-removal investigation that uses 8a.1 (pass-trace) +
8a.2 (sentinel) + 8a.3 (bench-delta) + 8a.4 (ZWASM_DIAG drain)
to localise which silent `UnsupportedOp` in
`arm64/{op_call,op_control,gpr}.zig` fires under post-hoist
IR with > 4 synthetic locals.

直近 commits (latest at top):

- (this commit) chore(p8): mark §9.8a / 8a.4 [x]; retarget at
  8a.5 cap-removal investigation.
- `9785ab8` feat(p8): §9.8a / 8a.4 — ZWASM_DIAG runtime opt-in.
- `d0a364b` feat(p8): §9.8a / 8a.3 — bench-delta-per-commit.
- `308ca97` feat(p8): §9.8a / 8a.2-d — realworld_run_jit
  cross-process sentinel surface (closes 8a.2 minus D-055).

3-host gate at `9785ab8`: Mac green, OrbStack 1 known D-054
FAIL only, windowsmini green.

**Phase 8 status**: §9.8 / 8.0-8.4 [x]; 8a.1-8a.4 [x];
**§9.8a / 8a.5 NEXT**. Phase 8 残 rows = 8a.5 + 8a.6 +
8b.1-8b.6.

## Active task — §9.8a / 8a.5-c: fix br_table post-hoist UnsupportedOp **NEXT**

8a.5-b finding (full notes: `private/notes/p8-8a5-survey.md`):
diagnostic `errdefer` added to `arm64/emit.zig` main op-
dispatch loop. Cap=1000 rerun surfaces:

```
arm64/emit: failing op `br_table` at func[18] pc=64
```

The post-hoist regression source is **`br_table` in `arm64/
op_control.zig`** (one of: line 270 `start+count >= targets.
len`, lines 295-296 `arity > merge_top_vregs_cap (8)`, line
320). Hoist's synthetic-local insertions shift the operand-
stack state; the br_table's per-target arity computation may
exceed the merge_top_vregs_cap.

8a.5-c plan: read `emitBrTable`, identify exact failing
constraint, fix or refine cap.

## Active task — historical 8a.5-b chunk-plan retired (was: bisect)

8a.5-a (cap-removed reproducer) findings (full survey in
`private/notes/p8-8a5-survey.md`):

- Cap=1000 regression: 52/55 → **42/55 compile-pass** (−10);
  15/55 → **8/55 RUN-PASS** (−7).
- Repeated stderr signature: `compileWasm: func[18] params=1
  results=1 → UnsupportedOp` across ≥5 fixtures (rust_file_io,
  go_string_builder, go_crypto_sha256, go_hello_wasi,
  cpp_vector_sort, …) — strongly suggests one shared runtime-
  stub function (≥5 const ops in a loop) hits a single
  ZirOp emit handler that fails under post-hoist IR.
- One outlier: cpp_unique_ptr_test.wasm fails with
  COMPILE-VAL BadValType (validator-stage) — unrelated to
  cap; likely a v128/funcref param leak. Not 8a.5 scope.

8a.5-b plan (next chunk):
1. Pick one fixture (e.g. tinygo_fib.wasm or rust_file_io.wasm).
2. Wire `trace.drainPassesToStderr()` into the realworld_run_jit
   runner's exit path so 8a.4's ZWASM_DIAG=passes drain fires
   from that exe (currently only cli/main.zig drains).
3. Re-run cap-removed with ZWASM_DIAG=passes,jit_exec; identify
   which pass produces the IR shape that arm64 emit rejects.
4. Hand-craft a minimal repro under `private/spikes/8a5_cap_
   removal/` (≤ 1 day per extended_challenge.md Step 4 spike
   discipline). Outcome → ADR or fix.

8a.5 still discharges D-054 + D-055 contingent (per chain in
debt.md).

Suggested chunk plan:

| #     | Description                                              | Status   |
|-------|----------------------------------------------------------|----------|
| 8a.5-a | Build with `-Dtrace-ringbuffer=true`; reproduce cap-removed regression locally; capture pass-trace + emit-stage logs | [x] (this commit; survey at `private/notes/p8-8a5-survey.md`) |
| 8a.5-b | Wire trace drain into realworld_run_jit runner; bisect to single fixture + ZirOp combo; small spike under `private/spikes/` | **NEXT** |
| 8a.5-c | Either fix emit path OR refine cap into structurally-correct filter | [ ]      |
| 8a.5-d | Remove `max_hoists_per_func` cap from `src/ir/hoist/pass.zig`; verify baseline ≥ 15/55 RUN-PASS + hoist count increased | [ ]      |
| 8a.5-e | 3-host gate; close D-053 + D-054 + D-055 contingent; close 8a.5 [x] | [ ]      |

After 8a.5 closes: 8a.6 (8a boundary audit). Then §9.8b begins.

## Open structural debt (pointers — current; full list in `.dev/debt.md`)

- **D-055** (`blocked-by: D-052 + emit_test_*.zig migration`) —
  x86_64 prologue inject deferred.
- **D-054** (`blocked-by: 8a.5 + D-055`) — OrbStack-only as-
  loop-broke regression.
- 9 `blocked-by:` rows — D-007 / D-010 / D-016 / D-018 / D-020
  / D-021 / D-022 / D-026 / D-028 / D-052; barriers all hold
  this resume.

D-053 promoted to ROADMAP row §9.8a / 8a.5 per ADR-0032.

**Phase**: Phase 8 (JIT optimisation foundation 🔒、ADR-0019)。
**Branch**: `zwasm-from-scratch`。
