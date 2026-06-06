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

**DIRECTION (user-steered 2026-06-06): 完成形 surface audits — ALL THREE DONE.** CLI→**D-295** (~85% + lean;
declines per ADR-0159 ≠ gaps); P0 `--env KEY=VAL` DONE (`90e3ebfd`, 3-host), P1 `--verbose` deferred-to-M5
(no rich user content yet), P2 WAT = v0.2 parser. **C-API→ZERO gaps** (`scripts/capi_surface_gap.sh` 293/293;
Phase 13 conformance VERIFIED+EXCEEDED — no debt). **Zig-API→gap#1 CLOSED** (`a9c850be`): `Module.imports()`/
`.exports()` pre-instantiation introspection (was ADR-0109 line-378 "Phase 11 D6 follow-up" carve-out that
slipped while siblings landed; reuses sections.decode*, arena-backed result, ExternKind native mirror). All
audit detail in **D-296** (note). Residual Zig-API gaps = v0.2/deferred, cross-ref D-269/D-177/D-178, none
完成形-blocking.
**Remaining (post-audit)**: (a) blocked-by 31 (external/future); (b) v0.2.0 features (proposal_watch + the
D-296 Zig-API residuals: Memory.grow/sliceAt, Linker.defineInstance, funcref-call, full WASI config); (d)
dogfooding (D-264 gated). No actionable HIGH-value 完成形 surface gap remains.
**Recently closed** (D-296 Zig-API residuals, all green Mac test+spec+lint, ubuntu @3aaf9df2): `Memory.grow`
(`f163e882`, test-spec 9/0) + `Memory.sliceAt` (`e5f34ff8`) + `Engine.linker()` (`994a5aef`) +
`Linker.defineInstance()` (`dba99bb8`, all 4 export kinds — the prior "deferred sugar" call was over-cautious;
all 4 cross-module alias paths already existed → clean compose). **ALL implementable Zig-API residuals CLOSED.**
**Zig-API surface is COMPLETE + reviewed + doc-synced.** Memory-safety review of the session's facade additions
(subagent, `a9c850be^..HEAD`): CLEAN — no HIGH/MED issues (arena error-paths covered, realloc aliasing safe,
growMemory behavior preserved line-for-line, sliceAt overflow-safe, defineInstance lifetime contract consistent;
one LOW fail-loud-exhaustive note, no action). `docs/zig_api_design.md` synced (`e120cc15` — killed the stale
2026-05-25 "thin veneer, ships in 6-8 cycles" status block; fixed introspection/grow signatures).
**Memory-safety: cross-module aliasing audited** (D-297) — model SOUND (zombie-parking keeps aliased storage
alive past instance deletes; DISPROVED a claimed table-UAF). One real gap FIXED (`477a9004`, docs): the
**Linker must outlive Instances it creates** (importer runtime holds a raw ptr into Linker-owned CallCtx →
post-deinit cross-module call = UAF) — now documented on header + deinit. Optional debug-assert guard deferred
(D-297, contract-based OK for v0.1 à la wasmtime). Verify finding: ALWAYS adversarially check audit "CRITICAL"
labels — this audit flip-flopped + missed the zombie-parking model; 1 of 2 "criticals" was a false positive.
**Windows batch RED @`23542591` = D-279 resurfacing** (NOT a regression). Win64 test-all crashed in
`zwasm-spec-wasm-2-0-assert.exe` exit-3 (SIMD-JIT heisenbug; `[d-163-jit]` movd/movaps dumps preceding).
EXONERATED: ubuntu ran the SAME assert GREEN, exit-3 = process crash (0 test-assertion fails), facade/growMemory
changes don't touch SIMD + would fail on ubuntu too. Recorded `track_heisenbug.sh win64-testall segv` (streak
6→0; NO LONGER discharge candidate — bug is real + unresolved, no root cause). NOT auto-reverted (D7). Windows
cadence NOT --record'd (RED). Also shipped `Engine.linker()`/`defineInstance`/lifetime-doc/example-introspection.
**D-279 investigation progress** (@82fb2db0): REFUTED hypothesis H1 (SIMD v128-spill aligned-move #GP) — x86_64
v128 spills use MOVUPS (unaligned-safe, inst_sse.zig:157-198), call-arg writes MOVUPS, GPR spills plain MOV → NO
aligned-move-on-misaligned-addr path in SIMD codegen. REFINED LEAD: exit-3 is `abort()`-class (not `0xC0000005`
#GP), so likely the **FP-walk/stack-walk corruption** lineage (D-180/D-245 — corrupted RBP chain in a deep SIMD
call stack → trap-handler/`@errorReturnTrace` walk aborts), NOT codegen-alignment. Recorded in D-279 (H1 struck).
**D-279 DIAGNOSTIC LANDED** (`22310693`): `windows_traphandler.zig::diagUnrecovered` emits `[d-279-veh]
UNRECOVERED (unfiltered-code | rip-outside-jit): code/rip/jit-range` on the two armed-but-escaping VEH paths
(previously SILENT before exit-3). Next Win64 crash self-identifies its mechanism → picks the surviving
hypothesis. Cross-compiled x86_64-windows-gnu green; Mac test+lint green.
**Windows re-run (D7 confirm-flake) STILL IN FLIGHT** (2 turns) — verify next Step 0.7; --record cadence if green.
**NEXT track**: wait for a `[d-279-veh]` line on the next Win64 RED to pick the hypothesis, OR (D-279 is now
instrumented + a tracked rare-flake) pivot to another memory-safety area / blocked-by barrier-dissolution sweep.
High-value autonomous surface work is largely done; D-279 is appropriately instrumented now.
**CADENCE (ADR-0076 D8)**: windows BATCHED (≥6 ABI-risk / ≥12 else); chain MANY chunks/turn, never poll-wait
on windows.

**Blocked / parked**: **D-290** remainder = 3 proposal-laden distillers (wasmtime_misc / spec_2_0_assert /
spec_simd) direction-gated — wasm-tools vs wabt TOOL-OUTPUT divergence breaks curated gates (NOT drift; debt
row D-290 has the full proof + methodology); wabt stays. **D-279** Win64 SIMD heisenbug streak **4/5** (one
more silent win run → discharge candidate). 31 blocked-by (external/future). 0 `now` debts.

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** Phases 0–15 all DONE;
  v0.1.0-scope complete + 3-host green. Tag/publish/cutover are manual, user-only — no release gate.
- Debt ledger: **66 entries, 0 `now`** (+D-296 Zig/C-API audit note). Resolved entries deleted per ledger
  discipline (git retains via discharge commits).

## Step 0.7 (next resume) — verify remote logs

- **ubuntu**: re-kicked this turn at the Module.imports/exports commit (`a9c850be`); verify `[run_remote_ubuntu]
  OK` in `/tmp/ubuntu.log`. D6 = always re-kick on next code commit.
- **windows**: BATCHED (D8). Last GREEN @`23269621`; cadence batch counting up (was 1/12 @`90e3ebfd`). Verify
  `should_gate_windows.sh` before kicking; don't poll-wait. D-279 heisenbug `silent` streak 4/5.
- **Gate note**: `[run_remote_windows] OK` = real green; `Build Summary: N failed` (no OK) = RED.
  `zig-host-hello` exit-42 + `--__selftest-crash` exit-70 "failed command" = EXPECTED, not crashes; the sha256
  `verify: FAIL` line is the known fixture-wrong-constant FALSE lead (zwasm hashes correctly).

## Key refs

- **ADR-0167** (D-288 interp native-stack-limit check) · **ADR-0156** (no autonomous release) · **ADR-0153**
  (rework campaign) · **ADR-0076** (3-host gate cadence D6/D7) · **ADR-0105** (JIT stack-probe, D-288's precedent).
- **D-290** debt row = wabt→wasm-tools blocker proof + the distiller recipe. Full debt sweep (2026-06-06) is in
  the LEAD section above. `.dev/proposal_watch.md` = v0.2.0 feature backlog (threads / wide-arith / component model).
