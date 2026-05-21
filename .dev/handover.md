# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure — §9.12-F D-055 migration in progress

§9.12-F (debt active rows < 15) and §9.12-I (ADR canonical) open.

| Exit criterion                  | Latest fact                                                                |
|---------------------------------|----------------------------------------------------------------------------|
| §9.12-F: debt active rows < 15  | 23 (D-018 closed last cycle); 8 over target                                |
| §9.12-I: ADR `Accepted` < 30    | strict 33 / loose 52 — blocked on Phase 9 close                            |

**This commit (D-055 migration batch 1)**: 4 tests in
`emit_test_int.zig` migrated from hardcoded post-prologue offsets
(`out.bytes[13..]` / `out.bytes[18..]` etc.) to
`prologue.body_start_offset(true, 8) + delta` pattern. Behavior-
preserving — tests stay green on Mac aarch64. The migration
makes these assertions survive the +7 prologue shift that
the JIT-execution sentinel injection will introduce when
D-055 ultimately lands.

Tests migrated (all `uses_runtime_ptr=true`):
- `(i32.const 0) i32.load offset=0 end — ADR-0026 prologue ...`
- `call N — 0 args, no return`
- `call N — 0 args, i32 return — captures EAX`
- `call N — 1 i32 arg — marshals top-of-stack`
- `call_indirect — bounds + sig + CALL RAX`

**Next pickup**: D-055 migration batch 2 — sweep remaining
uses_runtime_ptr=true sites in `emit_test_int.zig` (later test
blocks with `.call` / `.i32.load` ops) and start `emit_test_
float.zig` (91 `out.bytes[...]` sites total; most are
uses_runtime_ptr=false so no migration needed; only those that
trigger memory accesses or calls need the helper).

After all uses_runtime_ptr=true sites land helper-relative
offsets, the 5-line `inst.encMovMemDisp32Imm32` wire-up in
`x86_64/emit.zig` prologue can land safely (each tests passes
post-sentinel via the body_start_offset() helper).

## Recent context

- §9.12-G closed (`4bd62842`); §9.12-H closed (`600bd7cf`).
- §9.12-I batch 1 (`1095d225`) + batch 2 (`5e2b1a6e`).
- §9.12-F D-018 discharge (`02397144` + backfill `3df2f7ff`).
- §9.12-F barrier sweep (`d68ad87c`).

## Active `now` debts

- **D-055** (mechanical, multi-cycle): ~91 expectEqualSlices sites
  remain after batch 1 (5 ish in emit_test_int.zig); helper-
  migration in progress.

## Other queued work

1. **D-055 migration batches 2+** — per-cycle ~5-10 sites.
2. **D-141 per-file file-size ADRs** — 18 WARN files.
3. **§9.12-I revisit after Phase 9 close**.

## Active state (snapshot)

- §9.12-A enforcement: 11 items OK.
- §9.12-F: 23 active rows; D-055 migration batch 1 landed.
- §9.12-G / §9.12-H: closed.
- §9.12-I: 29 ADRs flipped; blocked on Phase 9 close.

## Open questions / blockers

- なし for D-055 migration continuation.

## See

- [ROADMAP](./ROADMAP.md) §9.12-F + §9.12-I scope + exit
- [`debt.md`](./debt.md), [`lessons/INDEX.md`](./lessons/INDEX.md)
- [`src/engine/codegen/x86_64/prologue.zig`](../src/engine/codegen/x86_64/prologue.zig) — body_start_offset helper
