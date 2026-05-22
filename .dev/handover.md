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

## Active task — W3.b-2 (callJitOrTrap helper + 5-callsite wiring)

W3.b-1 landed at `c97cb72f` (`src/platform/windows_traphandler.zig`
+ `installSigsegvHandler` Windows arm via VEH install). The
W3.b-2 design is now spike-validated at
`private/spikes/win64-recovery-pc-sp/` (gitignored) — Win64
cross-compile disasm confirms inline asm compiles; the survey's
Option B local-label pattern is refined into a wrapper-function
shape using `@returnAddress()` + inline-asm RSP capture (ADR-0103
Consequences refinement landed alongside).

Next chunk implements `windows_traphandler.callJitOrTrap()` per
the refined design and wires the 5 callsites on the Windows arm:

- `test/spec/spec_assert_runner_base.zig:3602` and `:3620`
  (in-source `test "..."` unittests for SIGSEGV recovery itself)
- `test/spec/spec_assert_runner_non_simd.zig:339`, `:1498`,
  `:1837` (production runner path during assert_trap fixtures)

Type: `emit` (post-spike). POSIX path keeps `sigsetjmp` +
`siglongjmp` inline (per discipline at base.zig:2306-2312).
Windows arm delegates to `callJitOrTrap(info, jit_fn, args) →
true` (=trapped). Spike status flips `merged-into-prod` when
the helper lands in production.

After W3.b-2: **W4** (windowsmini reconcile run; verifies
`spec_assert_runner_non_simd` green) → row 10 W6 Windows
DCE check → row 11 §9.13-0 close + Phase 9 boundary.

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
