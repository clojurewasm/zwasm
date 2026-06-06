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

## ← LEAD: actionable high-value Phase-16 debt PAID DOWN (2026-06-06 session); INFLECTION

**This session shipped** (all 3-host or Mac+ubuntu green): **D-288** (interp native-stack-limit check, Win64
SEGV fix), **D-289** (arm64 FP/v128 large-frame, practically done), **D-229** (x86_64 SysV multi-value param
thunk, closed), **D-204** (GC-subtype extraction, validator 3267→3086), + the **ADR-0076 D8** batched-windows
cadence (user-directed). D-291/284/287 prior.

**B-group is now drained of actionable HIGH-value work** (triage 2026-06-06):
- **D-293** — already SUBSTANTIALLY COMPLETE (slices 1-4d done; all common + GC null/bounds/cast trap kinds
  precise both arches; interp surface complete). Remainder = array.len/fill/copy/new trampolines + i31 check:
  ambiguous failure semantics, JIT-only, **NO user-facing gap (interp precise)** → row says "leave unless a
  GC-on-JIT program needs it". NOT a next item.
- **D-294** residuals (D-293-class cosmetic, conformance-neutral) · **D-286** (perf-measure-first DEFER, no
  bench) · **D-289** param/stack arms (degenerate-only) — all correctly deferred, no measured need.
- **D-283** (realworld WASI JIT e2e) would SURFACE failures (46/55 compile) = creates debt, counterproductive.

**DIRECTION (user-steered 2026-06-06): 完成形 surface audits.** CLI surface AUDIT DONE → **D-295** (subagent vs
wasmtime/wasmer): CLI is ~85% complete + intentionally lean (validate/inspect/wat declined per ADR-0159 = not
gaps). Genuine gaps prioritized: **P0 `--env KEY=VAL`** (WASI environ — host `setEnvs` infra EXISTS, unwired at
CLI; mirror `--dir`: accumulate in main.zig + thread `envs` into runWasmJit/runCwasmWasi/runWasmCapturedOpts +
`host.setEnvs` after setArgs — all 3 call sites @main.zig:212/223/225) · **P1 `--verbose`** (LOW effort) ·
**P2 WAT input** (needs a parser; maybe v0.2). **NEXT: implement P0 `--env`** (atomic — CLI + 3 runners + a
test; needs an env-reading fixture or CLI integration test — deferred from this session's tail to fresh
context, full plan in D-295). Then P1 `--verbose`, then the C-API + Zig-API surface audits (reuse the method).
**Remaining (non-audit)**: (a) blocked-by 31 (external/future); (b) v0.2.0 features (proposal_watch); (d)
dogfooding (D-264 gated).
**CADENCE (ADR-0076 D8)**: windows BATCHED (≥6 ABI-risk / ≥12 else); chain MANY chunks/turn, never poll-wait
on windows.

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
