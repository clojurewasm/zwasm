# Dual-view table storage sync via `mirrorWrite`

Auto-loaded when editing `src/engine/codegen/arm64/op_table.zig` /
`src/engine/codegen/x86_64/op_table.zig` /
`src/engine/codegen/shared/table_storage.zig` /
`src/feature/table/**` (post-9.12 if Q3 picks per-op-file).
Codifies the discipline established by ADR-0068 §A1 / §A7 for
keeping the dual-view table storage (`funcptr_base` view +
`tables_ptr[k].refs` view) in sync after mutating ops.

## The rule

Any JIT op handler that **writes** to `tables_ptr[k].refs[i]`
MUST go through `shared/table_storage.zig::mirrorWrite(...)`
— NOT a raw STR / direct refs-only write — so the parallel
funcptr-view (`funcptr_base` for k=0; `tables_jit_ci_ptr[k].
funcptr_base` for k>0) is updated in lockstep.

The 5 mutating ops covered today (after ADR-0068 chunks α/β/γ
land):

- `emitTableCopy` — table.copy (refs + funcptr from src→dst)
- `emitTableInit` — table.init (refs + funcptr from elem
  segment)
- `emitTableSet` — table.set (refs from caller, funcptr
  derived via `FuncEntity.funcptr`)
- `emitTableGrow` — table.grow (refs + funcptr filled from
  init value)
- `emitTableFill` — table.fill (refs + funcptr filled from
  init value)

Future Wasm 3.0 reftype additions + GC table operations
(table.atomic_*, etc.) MUST follow the same discipline.

## Why this rule exists (motivation)

D-126's root cause was that `op_table.zig` mutating ops
wrote to `tables_ptr[k].refs` (= `scratch_table_refs[k]`,
FuncEntity-pointer encoding) without updating the parallel
`funcptr_base` (= `scratch_funcptrs`, raw funcptr encoding)
that `call_indirect t0` reads via the §9.9-l-1b-d093 X26
fast path. The two views diverged after any mutating op,
causing `call_indirect` post-mutation to read pre-mutation
state. γ-4 probe (2026-05-18) exposed 113 functional FAILs
across `table_copy` / `ref_func` / `table_init` / `imports`
spec corpora.

The fix (ADR-0068 §A1) introduced `mirrorWrite` as the
single-site triple-write helper. The discipline is to
**never** bypass it — direct refs-only writes silently
re-introduce D-126.

## Mechanical pattern

```zig
// CORRECT
const mw = @import("../shared/table_storage.zig");
// ... pop n / src / dst vregs ...
try mw.mirrorWriteOne(ctx, tableidx, dst_idx_reg, refs_val_reg);
// helper emits STR to refs, STR to funcptr_base, STR to typeidx_base.

// REJECTED — bypasses helper, re-introduces D-126
try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(refs_val_reg, refs_ptr, dst_idx_reg));
// (call_indirect would now see stale funcptr_base[dst_idx])
```

For bulk operations (table.copy / table.init), the helper
exposes a `mirrorWriteRange(ctx, tableidx, dst_base, src_base,
n, mode)` variant that emits the paired loop body.

## Reviewer checklist

When reviewing code that touches `op_table.zig` /
`feature/table/**`:

- [ ] Every direct STR to `tables_ptr[k].refs` is replaced by
      `mirrorWrite*` call?
- [ ] Every new table-mutating op handler imports
      `shared/table_storage.zig` and uses the helper?
- [ ] The `// TODO(9.12-audit): table storage shape — see
      D-126 / ADR-0068` marker is present at every helper
      callsite (so the 9.12 audit cleanup grep finds it)?
- [ ] No new field added to `TableSlice` extern struct
      without updating ADR-0068 §A4's chunk-α scope and
      bumping the audit Q6 reference?

## Forbidden patterns this rule rejects

- Direct `encStrXRegLsl3` / `encStrImm` writes to a register
  loaded from `tables_ptr[k].refs`.
- Per-op "fast path" optimisation that skips `mirrorWrite`
  because "this op only mutates one slot, it's faster
  inline" — the helper is on the cold path of cross-module
  dispatch; perf savings inline are imaginary, sync gap is
  real.
- Adding a new mutating op without registering it in this
  rule's "5 mutating ops covered today" list.

## When the rule dissolves

After 9.12 substrate audit's Q6 decision lands and the
dual-view storage is either unified (Option A) or otherwise
restructured, this rule's payoff disappears (single-site
storage doesn't need a sync helper). At that point:

1. If unified: rewrite `mirrorWrite` body as a single STR;
   keep the helper as a no-op-shape thin wrapper (delete in
   a follow-up cleanup chunk).
2. Delete this rule file.
3. Remove `// TODO(9.12-audit)` markers (grep-cleanup chunk).
4. Update `audit_scaffolding §F` to drop the helper-callsite
   check.

If 9.12 keeps the dual-view (Option B continuation), this
rule stays as the load-bearing discipline. `audit_
scaffolding` periodically verifies no new table-mutating
ops bypass `mirrorWrite`.

## Stale-ness

- If `shared/table_storage.zig` is deleted or its API
  changes incompatibly, this rule is stale and must be
  updated or removed.
- `audit_scaffolding` skill periodically `grep -rn
  "encStrXRegLsl3.*refs_ptr"` to catch direct bypasses
  that this rule forbids.

## Related

- ADR-0068 — the architectural decision this rule
  enforces.
- `.dev/lessons/2026-05-18-debt-dedup-grep-before-file.md`
  — D-143 → D-126 absorption that surfaced the
  dual-view bug originally.
- `.claude/rules/abi_callee_saved_pinning.md` — sibling
  rule for ABI register-class invariants (distinct
  axis but similar "discipline must be auto-loaded"
  shape).
- `.claude/rules/edge_case_testing.md` — A3 contract
  fixture discipline that pairs with this rule.
