# arm64 reserved-reg staleness after a same-function table.grow (D-497)

**Date**: 2026-06-23 · **Refs**: D-497, ADR-0201,
`src/engine/codegen/arm64/op_table.zig:emitTableGrow`, `op_call.zig` table-0 fast path

## Observation

arm64's JIT prologue caches three table-0 invariants in callee-saved reserved
regs (per the ADR-0026 invariant strategy): **X25 = table_size**, **X26 =
funcptr_base**, **X24 = typeidx_base** (`emit.zig:303` loads X25 from
`[runtime_ptr + table_size_off]`). `call_indirect`'s table-0 fast path
bounds-checks the index against **W25**, not the fresh `TableSlice.len`.

A `table.grow` of table 0 bumps `rt.table_size` (and `TableSlice.len`), but X25
is **callee-saved** — it survives the `table_grow_fn` BLR with the **stale
pre-grow** value. So a `call_indirect` of a grown slot *later in the same
function* read the old bound and trapped OOB, even though the slot was correctly
populated. (Cross-function calls re-establish X25 at the callee prologue, so the
bug only bites the grow-then-call-in-one-function shape.)

This stayed latent until D-497 because **non-funcref tables can't
`call_indirect`** — funcref-table grow on JIT was the first op to expose it.

## Fix

After a `table.grow` of table 0, reload W25 from `[runtime_ptr +
table_size_off]` in `emitTableGrow` (arm64 only). **x86_64 reads
`rt.table_size` fresh from `[R15 + off]` each call_indirect**, so it never had
the staleness (memory-relative, not reg-cached) — confirmed by ubuntu x86_64
green with no x86_64 emit change.

## Generalization

Any future table-0-**mutating** op that can change the count, OR any change to
the reserved-reg scheme, must re-sync the cached invariant reg. The funcptr_base
(X26) / typeidx_base (X24) **pointers** stay valid across grow (ADR-0201
pre-allocates the mirror arenas, no realloc), so only the **size** reg needs the
reload — but that asymmetry is itself a thing to re-check if the arena strategy
ever changes to realloc.
