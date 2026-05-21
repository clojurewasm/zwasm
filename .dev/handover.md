# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure — §9.12-F D-055 migration in progress

§9.12-F (debt active rows < 15) and §9.12-I (ADR canonical) open.

| Exit criterion                  | Latest fact                                                                |
|---------------------------------|----------------------------------------------------------------------------|
| §9.12-F: debt active rows < 15  | 23 (no change this commit; D-055 site-count progressing)                   |
| §9.12-I: ADR `Accepted` < 30    | strict 33 / loose 52 — blocked on Phase 9 close                            |

**This commit (D-055 migration batch 2)**: 6 more test sites in
`emit_test_int.zig` migrated from hardcoded prologue offsets to
`prologue.body_start_offset()` pattern. `emit_test_int.zig` is
now substantially helper-relative; only 1 literal-offset site
remains (the `[0..body_start]` slice that already uses the
helper).

Tests migrated this commit:
- `(i32.const 0xDEADBEEF) end` — imm32 byte slice
- `(i32.const 7) (local.tee 0) end` — STORE [RBP-8] EBX
- `(i32.const 8) (i32.const 3) i32.sub end` — SUB R13D R12D
- `(i32.const 6) (i32.const 7) i32.mul end` — IMUL
- `i32.wrap_i64` — MOV EBX EBX self-MOV
- `i64.extend_i32_u` — MOV EBX EBX
- `i64.extend_i32_s` — MOVSXD RBX EBX
- `(i32.const 0)(i32.const 99) i32.store offset=0` — store path

Behavior-preserving (zig build test-all green on Mac aarch64).
Combined with batch 1 (commit `84c83e11`), the 4
`uses_runtime_ptr=true` tests + the bulk of `uses_runtime_ptr
=false` tests in `emit_test_int.zig` now use the helper.

**Next pickup**: D-055 migration batch 3 — sweep
`emit_test_float.zig` (91 `out.bytes[...]` sites). Most are
`uses_runtime_ptr=false` per the file's comments; the migration
applies the same `prologue.body_start_offset(false, 0) + delta`
pattern. After full sweep, the 5-line
`inst.encMovMemDisp32Imm32` wire-up in `x86_64/emit.zig`
prologue can land safely.

## Recent context

- §9.12-G closed (`4bd62842`); §9.12-H closed (`600bd7cf`).
- §9.12-I batch 1 (`1095d225`) + batch 2 (`5e2b1a6e`).
- §9.12-F D-018 discharge (`02397144` + backfill `3df2f7ff`).
- §9.12-F barrier sweep (`d68ad87c`).
- D-055 migration batch 1 (`84c83e11`).

## Active `now` debts

- **D-055** (mechanical, multi-cycle): emit_test_int.zig ~done;
  emit_test_float.zig pending; final 5-line wire after sweep.

## Other queued work

1. **D-055 migration batch 3 (emit_test_float.zig)**.
2. **D-141 per-file file-size ADRs** — 18 WARN files.
3. **§9.12-I revisit after Phase 9 close**.

## Active state (snapshot)

- §9.12-A enforcement: 11 items OK.
- §9.12-F: 23 active rows; D-055 migration in progress.
- §9.12-G / §9.12-H: closed.
- §9.12-I: 29 ADRs flipped; blocked on Phase 9 close.

## Open questions / blockers

- なし for D-055 batch 3.

## See

- [ROADMAP](./ROADMAP.md) §9.12-F + §9.12-I scope + exit
- [`debt.md`](./debt.md), [`lessons/INDEX.md`](./lessons/INDEX.md)
- [`src/engine/codegen/x86_64/prologue.zig`](../src/engine/codegen/x86_64/prologue.zig) — body_start_offset helper
