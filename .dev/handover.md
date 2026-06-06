# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Recently completed (all DONE; detail in debt.yaml + commits)

- **ADR-0164 trap/crash/exception-diagnostics PROGRAM COMPLETE**: D-293 per-kind JIT trap codes unified
  arm64+x86_64 (demuxed fixup channels); D-292 B-core internal-fault handler (`400c7006`, ADR-0166, exit 70,
  POSIX sigaction + Win VEH); C uncaught_exception(12) (`c2650de5`); D trap-UX audit → D-294 (`partial`).
- **D-288 DONE 3-host** (`5be983bc`, ADR-0167 option b): interp native-stack-limit check in `mvp.invoke()` —
  `Runtime.checkNativeStackLimit(@frameAddress())` traps CallStackExhausted at the real per-OS limit (128KB
  interp headroom) before SEGV. Mac test=0 / ubuntu OK / **windows OK @`23269621`** (no false-traps:
  spec_assert 212/0, wast 1158/0, realworld 55/55, simd 13351/0). Closes the latent Win64 deep-recursion SEGV.
- D-291 (`23874eda`), D-287 (`cf605260`, ADR-0165), D-284 (`fbc60815`). All 3-host green.

## ← LEAD: D-288 closed → B-group; D-294 reassessed (residuals are D-293-class) → next: D-286

**D-294 reassessed** (debt row): the load-bearing inline null-elem mislabel is FIXED (`4fa16b29`); both
residuals are D-293-class (R2 "undefined element" needs splitting the SHARED oob_table/code-2 channel —
op_table routes call_indirect+table.get/set/copy/fill all to code 2 — AND is conformance-neutral cosmetic; R1
needs the subtyping-trampoline null sentinel). NOT cheap standalone fixes → fold into D-293.

**Triage of the B-group (2026-06-06)**: D-294 residuals → D-293-class (deferred); **D-286** → perf-measure-first
DEFER (byte loops are spec-correct; row admits no fill/init-bound bench → no measured need). The genuine
**correctness/completeness** gaps that warrant fresh-context codegen work, in priority order:
- **D-289** — arm64 frame-offset imm12 cap. GPR paths (`340eaf5e`) + **FP/v128 local.get/set/tee arms now DONE**
  (`7dfc5992`: `gpr.frameLdrFp`/`frameStrFp` + d289_fp_large_frame fixture, 85/0 green). REMAINING: param-marshal
  (emit.zig :397-455) + stack-args (:466-531) large arms — lift with the same helpers + a fixture each.
- **D-229** — x86_64 SysV param-bearing multi-value wrapper thunk UNIMPLEMENTED (arm64 has it `f1858416`):
  backend asymmetry; a real completeness/parity gap.
- **D-293** — kinded-fixup refactor (splits the shared bounds_fixups/code-2 channel; subsumes D-294 R2).
- **D-283** (realworld WASI not JIT-run e2e — but only 46/55 compile, so enabling surfaces failures) ·
  **D-204** (validator.zig at cap=3300 split review). NEXT: D-289.

**Blocked / parked**: **D-290** remainder = 3 proposal-laden distillers (wasmtime_misc / spec_2_0_assert /
spec_simd) direction-gated — wasm-tools vs wabt TOOL-OUTPUT divergence breaks curated gates (NOT drift; debt
row D-290 has the full proof + methodology); wabt stays. **D-279** Win64 SIMD heisenbug streak **4/5** (one
more silent win run → discharge candidate). 31 blocked-by (external/future). 0 `now` debts.

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** Phases 0–15 all DONE;
  v0.1.0-scope complete + 3-host green. Tag/publish/cutover are manual, user-only — no release gate.
- Debt ledger: **65 entries, 0 `now`** (31 blocked-by / 31 note / 3 partial). Resolved entries deleted per
  ledger discipline (git retains via discharge commits — D-288/D-291/D-285/D-284 closed this session).

## Step 0.7 (next resume) — verify remote logs

- **windows**: ✅ GREEN @`23269621` (`[run_remote_windows] OK`) — D-288 verified, no false-traps (spec_assert
  212/0, wast 1158/0, realworld 55/55, simd_assert 13351/0). Cadence recorded. D-279 heisenbug `silent`,
  **streak 4/5** (one more silent win run → discharge candidate).
- **ubuntu**: ✅ GREEN @`8906af1b` (`OK`). Re-kick on the next code commit (D6 = always).
- **Gate note**: `[run_remote_windows] OK` = real green; `Build Summary: N failed` (no OK) = RED.
  `zig-host-hello` exit-42 + `--__selftest-crash` exit-70 "failed command" = EXPECTED, not crashes; the sha256
  `verify: FAIL` line is the known fixture-wrong-constant FALSE lead (zwasm hashes correctly).

## Key refs

- **ADR-0167** (D-288 interp native-stack-limit check) · **ADR-0156** (no autonomous release) · **ADR-0153**
  (rework campaign) · **ADR-0076** (3-host gate cadence D6/D7) · **ADR-0105** (JIT stack-probe, D-288's precedent).
- **D-290** debt row = wabt→wasm-tools blocker proof + the distiller recipe. Full debt sweep (2026-06-06) is in
  the LEAD section above. `.dev/proposal_watch.md` = v0.2.0 feature backlog (threads / wide-arith / component model).
