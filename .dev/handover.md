# Session handover

> ≤ 80 lines. No numeric predictions
> ([`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).
> Framing discipline:
> [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Cold-start procedure — §9.13-0 close-plan override active

**Authoritative work source**:
[`.dev/phase9_13_0_close_plan.md`](./phase9_13_0_close_plan.md).
The `/continue` skill's Step 1a close-plan override
activates; follow that doc's §6 Work sequence. HEAD
`3d9288a6` (2026-05-22); §0 preflight is now a 9-tool
inventory (sysinternals added at `711bdcce`) — green this
session.

## Active track

| Next chunk | First action | Gating |
|---|---|---|
| **D-161** (autonomous) — Win64 Class B mixed-class entry helper impl | `src/engine/codegen/shared/entry.zig:1135/1188/1259` 3 `@panic("D-022")` sites — replace with Win64 inline-asm thunks mirroring existing arm64+SysV branches (callI32f64NoArgs / callF64i32NoArgs / callF64f32NoArgs); cross-compile gate `zig build -Dtarget=x86_64-windows-gnu` | **none** — autonomous-eligible; surfaced 2026-05-22 `ba68a896` windowsmini post-Defender-fix test-all (was hidden by D-028 wedge until Defender fix uncovered it) |
| W3.b (main) — SEH shim impl per ADR 0103 | `src/platform/windows_traphandler.zig` (Zone 0): `install`/`uninstall`/`arm`/`disarm` + `vehHandler`; wire `installSigsegvHandler` Windows arm | **GATED** on user flip ADR 0103 Proposed → Accepted |

Subsequent: W4 windowsmini reconcile (gated on W3.b + D-161
both land); §9.13-0 close + Phase 9 boundary (gated on W4 +
ADR 0102 flip).

D-028 hypothesis #5 (Defender real-time scan) **CONFIRMED**
at `ba68a896`: post-fix test-all completed without wedge.
N=1; need N=5 consecutive silent runs per
`heisenbug_discharge.md` streak rule to close.

Discharged this session (do not re-walk): W0 / WA / F1 /
W1 / W2 (struck) / W3.a / W5 (struck) / W6-Mac. Full ledger
in close-plan §6.

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

- 9 tools (zig 0.16 / hyperfine / wasm-tools / wasmtime / wabt /
  yq / lldb / **sysinternals** [`711bdcce`]) installed via
  `scripts/windows/install_tools.ps1`.
- Defender exclusion baseline configured 2026-05-22: 8
  ExclusionPath (LLVM + sysinternals + CrashDumps + repo +
  caches) + 17 ExclusionProcess (all `addExecutable` outputs).
- `zig build test-all`: 37/39 steps OK; only spec_wasm_2_0
  runtime fails (D-136 SEH crashes inside).
- **Debug wiring** (per b737d53e): `debug_jit_auto` skill
  Recipes 9-14 + `windows_ssh_setup.md` "Interactive JIT debug
  session" section now provide windowsmini-equivalent
  "actively wired" debug posture (lldb-via-SSH, Procmon, fd
  count via handle64, llvm-objdump PE, WER post-mortem).
  Real-cycle試運転 deferred to W3.b implementation phase.
- Surveys: `private/notes/p9-9.13-0-survey.md` (W0),
  `private/notes/p9-d028-flake-rate.md` (W1 partial),
  `private/notes/p9-9.13-0-w3a-survey.md` (W3.a).

## Active `now` debts

- **D-161** — Win64 Class B mixed-class entry helper (3 @panic
  sites at `entry.zig:1135/1188/1259`); autonomous-eligible
  impl, surfaced 2026-05-22 `ba68a896`.

## Open questions / blockers (user-touchpoints)

- ADR 0102 (§9.12-F exit reframe) — Proposed → Accepted.
- ADR 0103 (Win64 SEH bridge VEH+threadlocal) — Proposed →
  Accepted; W3.b impl gated on flip.
- D-028 leading hypothesis re-framed at `f7d61bd1` from IPC
  timeout → Windows resource exhaustion at runner transition
  (W1 2026-05-22 partial evidence at 2/2 failures); next probe
  defers to post-W3.b natural-experiment OR explicit `test-all`
  orchestration instrumentation.

## See

- Execution plan: [`phase9_13_0_close_plan.md`](./phase9_13_0_close_plan.md).
- ROADMAP §9.13-0 / §9.12-F / §9.12-I.
- ADR 0102: [`decisions/0102_phase9_debt_exit_reframe.md`](./decisions/0102_phase9_debt_exit_reframe.md).
- ADR 0103: [`decisions/0103_win64_seh_bridge.md`](./decisions/0103_win64_seh_bridge.md).
- [`debt.md`](./debt.md): D-028 / D-136 (active Cat IV).
