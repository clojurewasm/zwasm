# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing discipline:
> [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Fresh-session start here

**Authoritative remaining-work source**:
[`.dev/phase9_close_master.md`](./phase9_close_master.md).

**Mandatory before any §9.x [x] flip**: run

```sh
bash scripts/check_phase9_close_invariants.sh --gate
```

(per `.claude/skills/continue/SKILL.md` Resume Step 5d + ADR-0104
+ `.claude/rules/phase9_close_invariants.md` §"Forbidden edits").

**Current gate state**: **FAIL 3/18** (15 OK: I2×4 + I3×5 + I4 +
I5 + I6×2 + I7×2). I6 ADR-0105 + ADR-0106 flipped Accepted
2026-05-23 cycle (path (a) buffer-write selected for 0106 per
ROADMAP §2 P3+P10+P13+§14 alignment + ADR-0104 D3 Tier-0).
Remaining 3 FAILs are all I1 SKIP-WIN64 arms — implementation
work, no longer user-gated.

## Active task — I1 SKIP-WIN64 arm removal via ADR impl

Per ADR-0105 + ADR-0106 Implementation plans:

### ADR-0105 (JIT-prologue stack-probe) — 3 cycles

1. [x] `JitRuntime.stack_limit` field + `src/platform/stack_limit.zig`
   cross-platform query helper (this cycle `3aa5ee5e`).
2a. [x] arm64 prologue probe + stack-overflow trap stub (`7b86f715`).
    stack_limit=0 default keeps probe a no-op; Mac test-all green.
2b. [x] x86_64 prologue probe + trap stub (`c2caba63`).
2c. [x] Wire stack_limit init via `invokeAndCheck`/`invokeAndCheckVoid`
    central helpers (`0b534d66`). All ~14 entry-helper sites
    auto-populate via the shared helper. Mac test-all green.
3. [x] D-162 closed (`6b9ae4ce`). SKIP-WIN64-EXHAUSTION arm
   removed + EXCEPTION_STACK_OVERFLOW filter removed from VEH.
   Win64 cross-compile green; windowsmini reconciliation at
   Phase 9 close boundary.

### ADR-0106 path (a) buffer-write entry ABI — 4 cycles

1. [x] `BufferWriteFn` + `invokeBufferWrite` foundation in new
   `entry_buffer_write.zig` (`f8b9eff7`). Hand-rolled JIT bytes
   verify end-to-end (results[0] = 42).
2a. [x] `ResultAbi` enum foundation in `result_abi.zig` (`7dd79884`)
    per `private/spikes/adr-0106-cycle2/SPIKE.md` Alt 2 (per-module
    compile flag, phased migration).
2b. [x] `Allocation.result_abi: ResultAbi = .register_write` field
    threaded via regalloc (`1909b06e`). compile() signature
    unchanged (358 callsites). Cycle-4 debt: promote to CompileOpts struct.
2c. [ ] x86_64 emit reads `alloc.result_abi` + branches prologue
    (capture RSI=results into frame slot) + epilogue (write
    `[results_ptr + 8*i]` per result) when `.buffer_write`.
    Hand-rolled `result_abi = .buffer_write` test exercises the
    new path end-to-end.
3. [ ] arm64 JIT epilogue rewrites — write `results[i]` instead
   of X0/X1.
4. [ ] Remove `FuncRet_*` extern struct family from `entry.zig`.
   Remove `SKIP-WIN64-MULTI-RESULT` arm. D-094 + D-164 close;
   gate I1c OK.

### ADR-0163 (Win64 call_indirect trap codegen spike) — 1-2 cycles

Disassemble `emitCallIndirect` Win64 branch at the OOB fixture's
index 306 site; compare bounds-check + trap-stub epilogue with
POSIX sibling; fix divergence. Remove `SKIP-WIN64-CALL-INDIRECT-
TRAP` arm. Gate I1b OK.

## Phase 9 close sequence (post-I1)

1. All 3 SKIP-WIN64 arms removed → gate 18/18 OK.
2. windowsmini `test-all` green with ZERO `SKIP-WIN64-*` token
   (Phase boundary windowsmini reconciliation per ADR-0049).
3. §9.13-0 / §9.12-F / §9.12-I re-flipped `[x]` with cited SHAs.
4. §9.13 🔒 collab gate review cleared.
5. Phase Status widget flips `9 | IN-PROGRESS → DONE`.

## Work landed this session (2026-05-23 cycle)

- **I3** Zig facade `Runtime / Module / Instance / Value` +
  facade test in `src/zwasm.zig` (`6c4faeea`).
- **I2** 4 c_api Wasm-2.0 utilisation test blocks in
  `src/api/instance.zig` (`a35e0f21`): reftype round-trip,
  bulk-traps, mixed-exports walk, cross-module funcref.
- **§5.4** stale ADR/debt cleanup (`97b2a2db`): 5 ADR Revision
  history SHA backfills + D-007 / D-010 Phase target verify.
- **D-062** closed (`b14e5438`) — barrier dissolved
  (§9.9-f-3 `80b2f1c5` already landed both sides).
- **I6** ADR-0105 + ADR-0106 Accepted (this commit, path (a)
  buffer-write for ADR-0106).

## Active `now` debts

(None — D-062 closed; D-094 / D-164 will flip to `now` and
close inside the ADR-0106 path (a) implementation cycles.)

## See

- [`phase9_close_master.md`](./phase9_close_master.md) (§5
  Tier 1; §6 exit predicate; §8 fresh-session entry).
- [ADR-0104](./decisions/0104_phase9_honest_accounting_reframe.md)
  (META reframe; Accepted).
- [ADR-0105](./decisions/0105_jit_prologue_stack_probe.md)
  (Accepted 2026-05-23; impl per §"Implementation plan").
- [ADR-0106](./decisions/0106_multi_result_return_convention.md)
  (Accepted 2026-05-23 path (a); impl per §"If path (a)").
- [`.claude/rules/phase9_close_invariants.md`](../.claude/rules/phase9_close_invariants.md)
  (I1-I7 invariants + Forbidden edits).
- [`debt.md`](./debt.md): D-094 / D-164 (blocked by ADR-0106
  Accept — barrier dissolved; will move to `now` next cycle).
