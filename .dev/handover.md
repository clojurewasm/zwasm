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
- ubuntu test-all: green (25457 passed wasm-2.0-assert,
  /tmp/ubuntu.log verified at HEAD=baa60ec4).
- windowsmini test-all: simd_assert green (13351/0 fail);
  spec_assert_non_simd has D-167 1+arg multi-result fails
  (~10-11 directives across `break-br_if-num-num` /
  `break-br_table-num-num` / `break-br_table-nested-num-num` /
  `add64_u_with_carry`). NOT blocking Phase 9 close gate.

## Closed 2026-05-23 (cycles 10-25)

1. **A1 D-157 CLOSED** (`6e48e680` + `bf4edaca`). SKIP-NO-
   LINK-TYPECHECK 56→0 on wasm-2.0; root cause was type-section
   early-return gap in spec runner's `hasIncompatibleImportType`.
2. **A2 D-139 CLOSED** (`c423cb4e`). c_api Instance audit
   tests in `src/api/instance.zig` (arena ownership + zombie
   lifecycle).
3. **A4 D-163 + D-166 CLOSED via shared root cause**
   (`e5042b3e`). Spec runner's `scratch_typeidxs` not reset
   between modules — caused Mac silent / ubuntu off-by-one /
   Win64 silent process death asymmetrically. Single fix.
   Lesson: `2026-05-23-d163-d166-shared-root-cause.md`.
4. **Win64 2-i32-result fix** (`a40bc6d6`). `callI32i32NoArgs`
   missing Win64 wrapper-thunk path (asymmetric with the
   3-result version). wasm-2.0/call/ Win64 isolated:
   90 passed / 0 failed / 0 SKIPs after fix.
5. **ADR-0107 Proposed** (`6b3c6705`). Byte-buffer
   `Runtime.globals` migration for D-079 (ii).
6. **Cycle 21-24 attempt at D-167 REVERTED** (`9a11b8d0` →
   `e0995333`). `wrapper_thunk.emitX8664Win64` extension to
   1-3 args compiled on Mac+ubuntu but regressed simd_assert
   on Win64 (process death compiling simd_bitwise.17). Filed
   as **D-167** for spike-first re-attempt.

## Remaining work

### Autonomous-eligible (next session pick from here)

- **D-167** — Win64 1+arg multi-result wrapper extension.
  **Spike with full context already exists** at
  `private/spikes/d167-win64-multi-arg-wrapper/README.md` —
  contains cycle 21-24 retrospective, proven Win64 byte
  sequences (1-arg + 3-arg 2-int-result), 4 work-order steps,
  failure-mode diagnosis. Read FIRST. Recipe: (1) per-shape
  Mac byte tests in `wrapper_thunk.zig` first, (2) synthetic
  end-to-end execution test, (3) land wrapper extension only
  after Mac tests green, (4) windowsmini integration verify
  ESPECIALLY simd_assert (cycle 24's regression site).

### User-gated

- **A3 D-079 (ii)** — blocked-by: ADR-0107 Accept. Structural
  `Runtime.globals` byte-buffer migration (13 callsites + JIT
  codegen). ADR proposed; awaiting collab review.
- **§9.13 hard gate** — ADR-0105 + ADR-0106 `Status: Accepted`
  flip via Track D collab review + Phase B `[x]` re-flip with
  cited SHAs (per `phase9_close_master.md` §5.3a Phase B).

## Cold-start procedure

1. Read this file (already loaded via SessionStart hook).
2. Read [`phase9_close_master.md`](./phase9_close_master.md)
   §5.3a + §6 for canonical work-sequence.
3. `tail -3 /tmp/ubuntu.log` — expect `OK (HEAD=baa60ec4)`
   or newer.
4. `bash scripts/check_phase9_close_invariants.sh --gate` —
   expect 18/18.
5. `.dev/debt.md` Step 0.5 sweep: D-167 is the sole `now`
   row. Discharge path: spike-first per row body.
6. Proceed per `.claude/skills/continue/SKILL.md` Step 0.4
   (lesson scan — `2026-05-23-d163-d166-shared-root-cause.md`
   for Win64 multi-result context).

## See

- [`phase9_close_master.md`](./phase9_close_master.md) §5.3a + §6.
- ADR-0104 Revision 2026-05-23 (Phase 9 真スコープ).
- ADR-0107 Proposed (D-079 (ii) byte-buffer globals).
- `.dev/debt.md` D-167 (`now`, Win64 multi-result wrapper).
- Lessons 2026-05-23-d163-* (Win64 narrowing methodology).

windowsmini SSH-reachable per ADR-0049. Debug infra:
`debug_jit_auto/SKILL.md` Recipes 15-17.
