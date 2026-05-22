# Session handover

> ≤ 80 lines. No numeric predictions
> ([`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).
> Framing discipline:
> [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Cold-start procedure — §9.13-0 close-plan override active

**Authoritative work source**:
[`.dev/phase9_13_0_close_plan.md`](./phase9_13_0_close_plan.md).
The `/continue` skill's Step 1a close-plan override
activates; follow that doc's §6 Work sequence. ADRs 0102 +
0103 flipped `Status: Proposed → Accepted` at `a6e3eb4f`;
bucket-3 gate dissolved. §0 preflight is a 10-canary check
(8 build tools + handle64 / Procmon64 — full Sysinternals
bundle at `711bdcce`).

## Bucket-3 stop — Win64 spec-compliance strategic direction needed

W4 retry chain summary:

| Retry | HEAD | Result | Crash directive |
|---|---|---|---|
| 1 | `f73e7a98` | exit 253 zero output | unknown (no beacons) |
| 2 | `1567516e` | exit 1 | `assert_exhaustion runaway ()` |
| 3 | `09ee5bb9` | exit 29 (STACK_OVERFLOW filter active) | `assert_exhaustion runaway ()` (downstream re-fault) |
| 4 | `007e26e1` | exit 1 | `assert_trap as-call_indirect-last ()` (call.0.wasm OOB) |
| 5 | `45cb3365` | exit 1 | `assert_return type-all-i32-i64 () -> i64:2 i32:1` (call_indirect.0.wasm multi-result) |

Each retry surfaced a NEW Win64-specific crash class. Three so
far: D-162 (stack overflow), D-163 (call_indirect bounds-check
trap), and an as-yet-unfiled multi-result calling convention
issue (retry 5). The "skip-accumulate" pattern reveals that
Win64 has multiple JIT-codegen and runtime-recovery gaps, not
a single bug. Per architectural_spike.md's "3-cycle cap"
discipline (cycles 1-3 produced clear progress; 4-5 had
diminishing returns), the loop pauses for strategic direction.

**Strategic options (user-gated)**:

(a) **Continue skip-accumulation**. File D-164 for the
    multi-result crash class, repeat W4 retry, file
    D-165/166/... as more surface. Eventually corpus completes
    with N SKIP tokens, §9.13-0 closes. Pro: autonomous.
    Con: Win64 spec compliance becomes a long list of debts.

(b) **Deep root-cause investigation**. windowsmini lldb-attach
    + Procmon trace + JIT disasm inspection across all 3+
    crash classes. Likely 1+ day of focused debugging.
    Resolves D-162/D-163/multi-result class fundamentally.

(c) **Scope-down Win64 for v0.1.0**. New ADR: defer full Win64
    spec compliance to Phase 10+; v0.1.0 RC ships with
    "Windows: build + unit-test only; spec corpus on Mac /
    Linux" framing. Removes W4 as a Phase 9 close blocker.
    Most aggressive simplification.

**Permanent value landed across this session**: W3.b-1 trap
handler module (`c97cb72f`), W3.b-2 callJitOrTrap helper +
callsites (`72d8a0e8`, `af4eff55`), VEH STACK_OVERFLOW filter
(`09ee5bb9`), per-manifest + per-directive beacons (`ee7403ff`,
`aeb01a23`), D-162 SKIP-WIN64-EXHAUSTION (`007e26e1`), D-163
SKIP-WIN64-CALL-INDIRECT-TRAP (`45cb3365`). ADR-0103 design
refined; spike `private/spikes/win64-recovery-pc-sp/` design
merged into prod (status flip pending W4 closure).

**To resume**: pick (a) / (b) / (c) and re-invoke /continue.

After resolution: spike status flips `merged-into-prod`;
close-plan §6 row 8 → row 10 W6 Windows DCE → row 11 §9.13-0
close + Phase 9 boundary.

## Autonomous prep paths walked this resume (do not re-walk)

- W3.b-1/2/2b implementation: COMPLETE (`c97cb72f` / `72d8a0e8` /
  `af4eff55`).
- ADR-0103 spike `private/spikes/win64-recovery-pc-sp/`:
  design validated via Win64 cross-compile + disasm (`b66ba743`
  refinement; ready for `merged-into-prod` flip).
- W4 reconcile retry chain (5 cycles, 2 SKIP tokens filed):
  diminishing returns at retries 4-5. Architectural-spike
  3-cycle cap exceeded.
- ADR-0078 taxonomy + ADR-0070 libc_boundary impact noted
  (D-162 mentions `_resetstkoflw()` as a future amendment
  trigger).
- Reference-repo enrichment (Wasmtime VEH pattern at
  `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/
  sys/windows/vectored_exceptions.rs:107-289`): captured in
  ADR-0103 §References at design time.

## Critical: do NOT widen shared `Error` for Win64 gaps

`src/engine/codegen/shared/entry.zig` is auto-loaded with
[`platform_panic_vs_error.md`](../.claude/rules/platform_panic_vs_error.md).
Win64 else-branches in comptime arch conditionals MUST use
`@panic("D-NNN")`, NOT new `Error` variants. See lesson
[`2026-05-22-platform-panic-vs-error-widening.md`](./lessons/2026-05-22-platform-panic-vs-error-widening.md).

## Win64 iteration workflow (4-tier, ~150× speedup)

Inner loop = Mac cross-compile
(`zig build -Dtarget=x86_64-windows-gnu`, ~3s). L1 sync via
`tar cf - src/ test/ build.zig | ssh windowsmini "cd ... && tar xf -"`
(~4s; rsync not on windowsmini). L3 (commit + push + test-all)
**only at chunk close**, not per iteration. Per close-plan §0.2.1.

## windowsmini state

- 9 tools + sysinternals installed via
  `scripts/windows/install_tools.ps1` (`711bdcce`).
- Defender exclusion baseline configured 2026-05-22.
- Surveys: `private/notes/p9-9.13-0-survey.md` (W0),
  `private/notes/p9-d028-flake-rate.md` (W1 partial),
  `private/notes/p9-9.13-0-w3a-survey.md` (W3.a).

## Active `now` debts

(none. D-136 in-flight discharge across W3.b; row stays
`blocked-by: <Win64 SEH bridge land + W4 reconcile>` until
W4 confirms windowsmini green.)

## Open questions / blockers

D-028 next probe defers to post-W3.b natural-experiment
(streak rule N=5 silent test-all runs). The N=1 confirmation
at `ba68a896` (Defender real-time scan hypothesis) is one
data point.

## See

- Execution plan: [`phase9_13_0_close_plan.md`](./phase9_13_0_close_plan.md).
- ROADMAP §9.13-0 / §9.12-F / §9.12-I.
- ADR 0102: [`decisions/0102_phase9_debt_exit_reframe.md`](./decisions/0102_phase9_debt_exit_reframe.md).
- ADR 0103: [`decisions/0103_win64_seh_bridge.md`](./decisions/0103_win64_seh_bridge.md).
- [`debt.md`](./debt.md): D-028 / D-136 (active Cat IV).
