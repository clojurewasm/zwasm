# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active bundle

- **Bundle-ID**: d314-jit-sandbox (interrupt poll → fuel → mem-cap → C-API/CLI)
- **Cycles-remaining**: ~5
- **Continuity-memo**: DONE — trap surface (`TrapKind.interrupted=16`) `5564c553`;
  **arm64 prologue interrupt poll** `c1a9da15` (`JitRuntime.interrupt_ptr` trailing
  field + `interrupt_ptr_off`; poll after the stack-probe `B.LS`: `LDR X16←ptr; CBZ
  skip; LDR W17←[X16]; CMP W17,WZR; B.NE→interrupt stub kind=16`; `CMP+B.NE` NOT
  CBNZ — EmitCindStub patcher does B/B.cond only; `JitInstance.setInterruptFlag`).
  Prologue grew 56→76; param-store byte tests relativised to `body_start_offset()`.
  **NEXT = x86_64 prologue poll** (after the `JBE` stack probe, emit.zig ~351;
  stub in op_control.zig like the stack-overflow stub kind=16; MOV/TEST/JZ-skip/
  MOV-flag/JNE). x86_64 prologue IS Win64-prologue-risk → `should_gate_windows.sh
  --resume` + verify (windowsmini FREE now — user 2026-06-12, CWFS uses tag refs).
  Then ungate the `runner_trap_test` interrupt test (drop the `skip.blocker(.@"D-314")`
  arch-gate). Then loop **back-edge poll** (the `(loop)`-with-no-calls case; fb=
  frame_bytes since it fires post-SUB-SP, a SEPARATE fixup list) → #3b fuel → #3c-2
  mem-cap → #3a-4 CLI `--timeout`/`--fuel`/`--max-memory`. **Code-size note**: the
  poll (20 B) + interrupt stub (28 B) are unconditional per fn — measure the bloat
  and consider an opt-in compile flag (wasmtime-style) per perf-measure-first.
- **Exit-condition**: a JIT-compiled looping/recursive fn traps `error.Interrupted`
  when the host raises the flag, verified 3-host (windows in scope for x86_64).

## JIT-correctness pass (2026-06-12) — LANDED, 2-host green

JIT spec-correctness was the priority (`100% spec` held for interp; JIT had real
gaps). **Now wasm-3.0 JIT mode = assert_return 880/0 on BOTH arm64 + x86_64**,
matching interp. Commits `e758412a..9a9b46de` pushed, **ubuntu `test-all` OK
@9a9b46de** (no release — ADR-0156; windows suspended ADR-0174 — now resumable).

**Shipped (detail in git log)**: GC-ref-through-table JIT corruption `9a9b46de`
(arm64 GcRef spill STR-W→STR-X + x86_64 table.set r10/r11 descriptor-vs-spill-stage
clobber → snapshot idx/val first; D-317 re-framed from "call_indirect subtype");
memory64 bounds `ea+size` 2^64-overflow `fc5be95e` (ADDS+carry, both arches;
reopened+fixed D-234, mis-closed 6 cycles — lesson Rule 6: isolation must replay
boundary INPUT values); test capture-allocator mismatch `008dc3be` (ubuntu RED);
D-237 spec-runner double-free `314a0c97`; 36 stale multi-memory skips `93792696`;
D-299 stale row `e758412a`. **D-318** (note): Rosetta x86_64-macos FULL corpus-JIT
SEGVs (pre-existing, local-diagnostic only, not a gate). Remaining jit-mode skips
are eligibility-gated (multi-memory/v128/multi-value/cross-module), NOT correctness.

**Prior pass — embedder-hardening (2026-06-08, `14de5430..d6699b00`, pushed,
ubuntu-green @d6699b00)**: facade `InstantiateOpts` fuel + `max_memory_pages`
budgets (ADR-0179 rev); decoder robustness (`checkVecCount`, locals cap,
interp-path memory ceiling); table-min regression fix; D-315 plant-time symlink
refuse; D-316 `setTableElementsLimit`; rec-group fuzz seeds; 18 Actions SHA-pinned.
Detail in git log + `private/` (gitignored).

**Prior Tier-1 / release-prep (all ubuntu-green, pushed)**: #2 static-lib + extlink hardening
`45438b7a` (D-312, GNU-stack=zig-upstream); **ADR-0179** sandboxing design;
**interp-engine sandboxing TRIAD** via the Zig facade — interrupt/cancel/timeout
`Instance.interrupt()` (#3a-1/2 `1001fa0e`/`460210f1`), memory-limit
`setMemoryPagesLimit` (#3c-1 `7216e7b1`), fuel `setFuel` (#3b `58479dd6`);
**Phase B** honest gap analysis in `docs/migration_v1_to_v2.md`; **Phase D**
README release polish. Earlier: musl (ADR-0178), test-noise cleanup,
`docs/v1_contributor_history.md` + migration-guide rewrite.

**Documented follow-ons (need a user decision / focused effort — NOT v0.1-blocking)**:
- **JIT-engine sandboxing**: extend interrupt/fuel/mem-cap to `--engine jit`.
  Multi-part: host→JIT interrupt DRIVING path (none today) + prologue-poll codegen
  both arches (Win64-risk → `should_gate_windows.sh --resume`, conflicts w/ cw dev)
  + a JIT-run-trap harness (none). Interp (default) carries the guarantee meanwhile.
  Bundle memo (interp/JIT runtimes separate, setInterruptFlag, arm64 poll plan) in
  git: commit `fb18bd82`.
- **#3a-4 CLI/C-API surface** (`--fuel`/`--timeout`/`--max-memory`; `zwasm.h`
  setters + `TrapKind.interrupted`) — small; the Zig facade already has it.
- **#1 C-API WASI preopen — D-251**: pure C-API has no `std.Io` to open dirs;
  needs an io-acquisition ADR. CLI `--dir` + Zig API cover preopen today.
- **Tier-2 #5** ILP32/watchOS (static-lib target + #97 accommodations).
- **D-313**: realworld `c_sha256_hash.wasm` fixture has a wrong baked hash (zwasm
  is correct vs `shasum`; gate-hole = realworld-run doesn't assert guest stdout) —
  fixture regen + runner-assert deferred.

## State at pause

- **Core Wasm 1.0/2.0/3.0**: 100% spec, 0 skip, 3-host green. **v0.2 features**
  (atomics / wide-arith / custom-page-sizes / relaxed-SIMD) complete + official
  corpora. **WASI 0.1** complete.
- **Component Model + WASI Preview 2** (opt-in `-Dcomponent`): a real Rust
  wasm32-wasip2 component runs e2e (ADR-0170/0175); E1 spec-corpus runner
  (`test/spec/component-model-assert/`); **structural validation** rules 1-4
  (type-index/Canon/alias/ExternDesc bounds — ADR-0176, `feature/component/validate.zig`).
- **Surfaces**: C-API 293/293 gap-free · Zig-API complete · CLI (`run`/`compile`,
  intentionally lean) · memory-safety sound · dogfooded into cw v1.
- **Test iteration**: integration runners build ReleaseSafe (ADR-0177); unit
  `zig build test` stays Debug. `zig build test-all` auto-fast, no flag.
- Debt ledger **53 entries**, **zero `now` rows** (stale D-299 row deleted
  2026-06-12 — its substance was fixed+discharged same-day as D-303 @5b0db8e1/
  31b05bf9; re-verified: misaligned atomic load/store traps on arm64 + Rosetta
  x86_64 JIT). Rest `blocked-by`/`note` = long-tail.

**Parked (demand-driven, NOT this campaign)**: CM deeper conformance
([`component_model_plan.md`](component_model_plan.md)); WASI-P2 sockets; Go/tinygo
proof; 32 `blocked-by` debt (call_ref / future proposals).

## Key refs

- [`docs/handoff_cw_v1.md`](../docs/handoff_cw_v1.md) — consumer-side handoff.
- **ADR-0170** (CM campaign) · **ADR-0176** (component validation) ·
  **ADR-0177** (runners ReleaseSafe) · **ADR-0156** (no release) ·
  **ADR-0174** (windows gate suspend) · **ADR-0153** (rework posture).
- [`component_model_plan.md`](component_model_plan.md) ·
  [`releasesafe_jit_failures.md`](releasesafe_jit_failures.md) (D-311 resolved).
