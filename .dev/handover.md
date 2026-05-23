# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Fresh-session start here

**Authoritative remaining-work source**:
[`phase9_close_master.md`](./phase9_close_master.md)
§5.3a (Phase A + Phase B 2-stage iteration discipline).

**Mandatory before any §9.x [x] flip**:
`bash scripts/check_phase9_close_invariants.sh --gate`.

**Phase 9 close gate (mac-host)**: **18/18 PASS** (was 17/18
pre-cycle-20). I1 satisfied — no SKIP-WIN64-* emission.

**Test state**:
- Mac aarch64 `zig build test` / `test-all`: green.
- ubuntu test-all: green at HEAD=39eac7ba (verify next resume
  Step 0.7 for HEAD post-this-commit-pair).
- windowsmini test-all: simd_assert green (13351/0 fail);
  spec_assert_non_simd has D-167 1+arg multi-result fails
  (~10-11 directives across `break-br_if-num-num` /
  `break-br_table-num-num` / `break-br_table-nested-num-num` /
  `add64_u_with_carry`). NOT blocking Phase 9 close gate.

Closed 2026-05-23 cycles 10-25 summary (A1 D-157, A2 D-139,
A4 D-163/D-166 shared root-cause, Win64 2-i32-result fix,
ADR-0107 Proposed, cycle 21-24 D-167 revert): `git log
--grep="cycle 2[0-5]"` and `git log --grep="A1\|A2\|A4"`.

## Cycle 26 progress (D-167 spike work-order step 1, shape 1/3)

**1-arg + 2-int-result wrapper shape LANDED** with Mac byte
test. `emitX8664Win64` predicate now allows `n_params == 1
and n_results == 2 and all_gpr`. Bytes per spike README §
"Win64 byte sequences (proven from cycle 21-24)". Wrapper
extension only; entry.zig if-arm wire-up deferred until
remaining shapes land (incremental approach per spike work
order step 3). Implicitly covers both `callI32i32_i32` and
`callI32i64_i32` (same wrapper bytes; result types differ
only in body-side emit).

## Remaining work

### Autonomous-eligible (next session pick from here)

- **D-167 shape 2/3** — 3-arg + 2-int-result Win64 wrapper
  (`callI64i32_i64i64i32`). Recipe: per-shape Mac byte test
  in `wrapper_thunk.zig` (44 bytes per spike README; mind
  the a2-FIRST load ordering because R8 holds args ptr and
  gets overwritten by a1). Extend `emitX8664Win64` predicate
  to allow `n_params == 3`. Same TDD red→green cycle as 1/3.
- **D-167 shape 3/3** — 1-arg + 3-int MEMORY-class
  (`callI32i32i64_i32`). Body uses Win64 MEMORY-class
  convention (RCX = hidden ptr, RDX = rt). Cycle 21-24's
  3-int extension was the same shape as the existing 0-arg
  3-int MEMORY arm; just add `n_params == 1` allowance with
  `MOV RDX/RCX` rearrangement.
- **D-167 wire-up** — after all 3 shapes Mac-green: add
  entry.zig Win64 if-arms calling `invokeBufWin64Args`
  helper (to add back in `entry_buffer_write.zig`), then
  windowsmini integration verify ESPECIALLY simd_assert
  (cycle 24's regression site).

### User-gated

- **A3 D-079 (ii)** — blocked-by: ADR-0107 Accept. Structural
  `Runtime.globals` byte-buffer migration (13 callsites + JIT
  codegen). ADR proposed; awaiting collab review.
- **§9.13 hard gate** — ADR-0105 + ADR-0106 `Status: Accepted`
  flip via Track D collab review + Phase B `[x]` re-flip with
  cited SHAs (per `phase9_close_master.md` §5.3a Phase B).

## Cold-start procedure

Per `/continue` SKILL.md Resume Steps 0.5 / 0.7 / 0.8. Lesson
scan: `2026-05-23-d163-d166-shared-root-cause.md` for Win64
multi-result context. D-167 is sole `now` row (sub-shape 2/3
next per "Remaining work" above).

## See

- [`phase9_close_master.md`](./phase9_close_master.md) §5.3a + §6.
- `private/spikes/d167-win64-multi-arg-wrapper/README.md`.
- ADR-0104 Revision 2026-05-23 (Phase 9 真スコープ).
- ADR-0107 Proposed (D-079 (ii) byte-buffer globals).

windowsmini SSH-reachable per ADR-0049. Debug infra:
`debug_jit_auto/SKILL.md` Recipes 15-17.
