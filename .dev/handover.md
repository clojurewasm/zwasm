# Session handover

> ≤ 80 lines. No numeric predictions
> ([`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).
> Framing discipline:
> [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Cold-start procedure — §9.13-0 close-plan override active

**Authoritative work source for this session**:
[`.dev/phase9_13_0_close_plan.md`](./phase9_13_0_close_plan.md).
The `/continue` skill's Step 1a close-plan override
activates; follow that doc's §6 Work sequence. §0 preflight
(8-tool inventory) green at HEAD `8334bc44` (2026-05-22).

| Next track | First action | User touchpoint |
|---|---|---|
| W3.b (main) — SEH shim impl per ADR 0103 (after Proposed → Accepted) | `src/platform/windows_traphandler.zig` (Zone 0): `install`/`uninstall`/`arm`/`disarm` + `vehHandler` reading `EXCEPTION_POINTERS.ContextRecord.Rip`; wire `installSigsegvHandler` Windows arm; Mac cross-compile gate (`-Dtarget=x86_64-windows-gnu`) | ADR 0103 flip Proposed → Accepted before W3.b impl |
| WA (DONE) — §9.12-F ADR draft | `4196b385` (ADR 0102 Proposed) | ADR-flip Proposed → Accepted |
| W3.a (DONE) — SEH bridge ADR draft | `8334bc44` (ADR 0103 Proposed; **diverges from close-plan §5/W3 Option A** to VEH+threadlocal Option B per v1/Wasmtime/Wasmer precedent) | ADR 0103 flip Proposed → Accepted |

§9.12-E ★ DONE (Wasm 2.0 100%). §9.12-I batched at row 11
(§9.13-0 close).

## Critical: do NOT widen shared `Error` for Win64 gaps

`src/engine/codegen/shared/entry.zig` is **auto-loaded with**
[`.claude/rules/platform_panic_vs_error.md`](../.claude/rules/platform_panic_vs_error.md).
Win64 else-branches in comptime arch conditionals MUST use
`@panic("D-NNN")`, NOT new `Error` variants. Inline INVARIANT
comments at the 3 @panic sites in entry.zig. See lesson
[`2026-05-22-platform-panic-vs-error-widening.md`](./lessons/2026-05-22-platform-panic-vs-error-widening.md).

## Win64 iteration workflow (4-tier, ~150× speedup)

Per execution plan §0.2.1. **Inner loop = Mac cross-compile**
(`zig build -Dtarget=x86_64-windows-gnu`, ~3s). L1 sync via
`tar cf - src/ test/ build.zig | ssh windowsmini "cd ... && tar xf -"`
(~4s; rsync not on windowsmini). L3 (commit + push +
test-all) **only at chunk close**, not per iteration.

## windowsmini state

- 8 tools installed via `scripts/windows/install_tools.ps1`:
  zig 0.16.0 / hyperfine / wasm-tools / wasmtime / wabt /
  yq / lldb (LLVM 22.1.6 + python311.dll).
- `zig build`: ✓.
- `zig build test`: 1744/1775 pass, 2 D-136 SEH crashes.
- `zig build test-all`: 37/39 steps OK; only spec_wasm_2_0
  runtime fails (D-136 inside).
- W0 survey: `private/notes/p9-9.13-0-survey.md`.
- W1 survey: `private/notes/p9-d028-flake-rate.md` (partial).
- W3.a survey: `private/notes/p9-9.13-0-w3a-survey.md`.

## Current Phase 9 state

| Exit | Latest fact |
|---|---|
| §9.13-0 windowsmini full green | D-022 closed (`0c2474c2`); D-084 closed pre-§9.13-0 (`7a7e387c` 2026-05-12 per ADR-0055); D-136 ADR 0103 Proposed (`8334bc44`); D-028 partial-measure (diverges from IPC framing) |
| §9.12-F debt active rows | 19 active; WA ADR 0102 Proposed (`4196b385`) reframes exit per-row predicate |
| §9.12-I ADR `Accepted` < 30 | strict 33; batched at Phase 9 close |

## Active `now` debts

- なし.

## Open questions / blockers

- ADR 0102 (§9.12-F exit reframe) — Proposed → Accepted needs
  user (allowed `user-judgment` per `handover_framing.md`).
- ADR 0103 (Win64 SEH bridge) — Proposed → Accepted needs
  user; W3.b impl chunk gated on flip (architectural ADR-first
  per `architectural_spike.md`).
- D-028 barrier re-framing — W1 partial evidence suggests
  Windows resource exhaustion / SSH stall, not IPC timeout.
  Revisit after W3.b lands (SEH bridge may reduce corpus
  duration).

## Recent context (2026-05-22 commits)

- `8334bc44` — ADR 0103 draft (Win64 SEH bridge via VEH, Proposed).
- `15300741` — refresh §9.13-0 items (D-084 closed pre-row) + W1 partial.
- `4196b385` — ADR 0102 draft (§9.12-F exit reframe, Proposed).
- `0c2474c2` — F1 fix via `@panic` (D-022 close).
- `7a7e387c` — Win64 v128 marshal via hidden-pointer (D-084 close, 2026-05-12).

## See

- Execution plan: [`phase9_13_0_close_plan.md`](./phase9_13_0_close_plan.md).
- ROADMAP §9.13-0 / §9.12-F / §9.12-I.
- [`debt.md`](./debt.md): D-028 / D-136 (active Cat IV).
- ADR 0102: [`decisions/0102_phase9_debt_exit_reframe.md`](./decisions/0102_phase9_debt_exit_reframe.md).
- ADR 0103: [`decisions/0103_win64_seh_bridge.md`](./decisions/0103_win64_seh_bridge.md).
