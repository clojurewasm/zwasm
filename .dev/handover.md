# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## JIT-correctness pass (2026-06-12) — PUSHED, ubuntu re-gate in flight

User-directed "make the codebase better" session, prioritised JIT spec-correctness
(the bar's `100% spec` held for interp; JIT had real gaps — now **wasm-3.0 JIT
mode = assert_return 880/0 on BOTH arm64 + x86_64**, matching interp). Commits
`e758412a..9a9b46de` on `zwasm-from-scratch`, **pushed** (no release — ADR-0156).
Mac arm64 green; ubuntu `test-all` OK @008dc3be; **ubuntu re-gate of `9a9b46de`
IN FLIGHT** (`private/ubuntu_gate_4_*`). Rosetta x86_64 corpus per-manifest green.

**Shipped**:
- **GC-ref-through-table JIT corruption FIXED (both arches)** `9a9b46de` — the
  last 2 jit-mode wasm-3.0 fails (gc/ref_test test-sub/test-canon). TWO distinct
  bugs, BOTH making a table-loaded struct.new* object fail ref.test: (1) arm64 —
  struct.new*/array.new_fixed spilled the u32 GcRef result via STR W (32-bit),
  leaving the 64-bit slot's high half stale → table.set stored `(stale<<32)|ref`;
  fix = STR X. (2) x86_64 — table.set reused r10/r11 for the descriptor AND the
  spill stages, so a force-spilled idx (struct.new is a CALL) clobbered `len` →
  bounds `cmp idx,idx` → trap; fix = snapshot idx→EDX/val→R9 before the
  descriptor (mirrors arm64 X16/X17). D-317 was MIS-FRAMED as call_indirect
  subtyping; the real bugs were GcRef width + register clobber.
- **memory64 JIT bounds overflow FIXED (both arches)** `fc5be95e` — `emitMemOpI64`
  did `ADD ea,#size; CMP; B.HI` so `ea+size` near 2^64 WRAPPED past the bounds
  check → no trap (spec violation). Now flag-setting `ADDS`+`B.HS` (arm64) /
  `ADD`+`JC` (x86_64). `ZWASM_SPEC_ENGINE=jit` wasm-3.0 memory64 FAILtrapNoTrap
  51→0, return 337/0. **This reopened+fixed D-234**, mis-closed as a "harness
  artifact" over 6 cycles (its isolation tests all used SMALL addresses that never
  overflow). Lesson `…harness-artifacts` corrected: Rule 6 (isolation must replay
  the corpus's boundary INPUT values) overrides its Rule 4.
- **Test capture-allocator mismatch FIXED** `008dc3be` — `2d99e5a2` made
  runWasmCaptured* grow the buffer with the CALLER's allocator; diff_runner +
  wasi/runner still freed with `c_allocator` → `free(): invalid pointer` SIGABRT
  on x86_64-Linux (first ubuntu RED since that change). Mac aliased malloc so it
  hid there.
- **D-237 spec-runner double-free FIXED** `314a0c97` — the corpus-end
  `defer free(cur_module_bytes)` fired even after ownership transferred to
  kept_bytes; now respects `cur_bytes_kept`. `ZWASM_SPEC_DETAIL=1` env added.
- **36 stale multi-memory skips retired** `93792696` — regen with the current
  distiller; `assert_unlinkable`/`assert_uninstantiable` now real directives.
- **D-299 stale row deleted** `e758412a` — already fixed same-day as D-303.

**Open JIT-correctness follow-ons (NEXT, per task list)**:
- **D-318** (note) — Rosetta x86_64-macos FULL corpus-JIT SEGVs (pre-existing,
  local-diagnostic only, not a gate; native x86_64-Linux + per-manifest Rosetta
  are green). The GcRef fix above was verified per-manifest on Rosetta.
- Then **D-314** JIT sandboxing (interrupt/fuel/mem-cap on `--engine jit`;
  Win64-risk → `should_gate_windows.sh --resume`, conflicts w/ cw dev) +
  diagnostics/DX (trap backtraces; industry pain #1) + D-313 realworld stdout-
  assert gate-hole. wasm-3.0 jit-mode is now CLEAN both arches (0 assert_return
  fails); remaining jit skips are eligibility-gated, not correctness gaps.

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
