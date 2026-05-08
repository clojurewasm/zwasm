# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/phase8_transition_gate.md` — 🔒 Phase 7→8 hard gate (load-bearing).
3. `.dev/decisions/0019_x86_64_in_phase7.md` / 0021 / 0023 / 0025 / 0026 / 0027 / 0028 — recent ADRs.
4. `.dev/debt.md` — discharge `Status: now` rows; review `blocked-by` triggers.
5. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain.
6. `.dev/optimisation_log.md` — F-NNN / R-NNN / O-NNN ledger.

## Current state — Phase 7 / §9.7 / 7.10 IN-PROGRESS

直近 commit (HEAD = `ff1e62a`):

- `ff1e62a` feat(p7): §9.7 / 7.10 chunk m — D-049 root cause + fix
  (call_indirect funcref table population)
- `98c8305` chore(infra): JIT/runtime debug toolkit
- `9b60c17` chore(p7): chunk-m strategy — promote lldb batch mode
- `911b92c` feat(p7): §9.7 / 7.10 chunk l (partial) — JIT entry() guards

**Phase status**: §9.7 / 7.5 + 7.8 + **7.9 [x]**。Phase 7 残 row =
7.10 / 7.11 🔒 / 7.12 / 7.13 🔒。

**§9.7 / 7.10 progress** (post-chunk-m):
- compile-pass: arm64 52/55, x86_64 45/55 (post-D-048)
- run-stage: **SEGV 解消** — minimal call_indirect spike + 27
  realworld fixtures all RUN-TRAP / RUN-UNSUPPORTED-SIG, 0 SEGV.
  D-049 discharged at `ff1e62a`.
- run-pass: still 0/55 — WASI host stubs trap on first import
  (`fd_write` / `proc_exit`). Not a JIT bug; needs WASI host
  wiring or strict-trap-pass interpretation per 7.9 precedent.

**§9.7 / 7.10 chain plan** (NEXT 群):
- **7.10-n (NEXT)**: x86_64 host (OrbStack / windowsmini)
  ZWASM_JIT_RUN=1 verification — confirm chunk-m fix removes
  SEGV on Linux + Windows x86_64 too (Mac arm64 already
  verified). After confirm, decide 7.10 close path: (a) follow
  7.9 precedent (interpret "40+ run" as "40+ no-SEGV / clean
  trap"), or (b) wire minimal WASI stubs (proc_exit + fd_write
  → noop OK) to convert RUN-TRAP→RUN-PASS.
- 7.10-br_table-fdepth (deferred): return-trampoline pattern。
- 7.10-regalloc-port (deferred to Phase 8): D-029.

**Pre-existing infra (out-of-scope)**: `.githooks/pre_commit`
(snake_case) が fire しないため fmt/file_size/lint gate 無効。
fmt drift 38 files, hard-cap 超過 3 files (emit_test.zig +
emit.zig + inst.zig, all pre-existing), lint warns 4 (全
pre-existing)。修復は専用 chore + 大規模 fmt + 分割 ADR 必要。

> **🔒 Phase 7 → 8 hard gate** が §9.7 / 7.13 に登録済。Detection
> は Resume Step 2 + Step 7 re-target。詳細 `phase8_transition_gate.md`。
> Active row 7.10 は gate prep window (= 7.13 - 3) 内 — Step 0.6
> awareness 必須。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`。

## Open structural debt (pointers)

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後再評価。
- **D-026** env-stub host-func wiring (cross-module dispatch)。
- **D-029** parallel-move 経路完備、reject は regalloc port 後 discharge
  (currently absent from debt.md — file row at next regalloc-port chunk).
- 詳細・staleness check は `.dev/debt.md`（all active rows are
  `blocked-by:` after D-049 discharge — zero `now` rows）。
- ADR-0025 (Zig host API) Phase B/D は post-7.8 — `0025_zig_library_surface.md`。

## Recently closed
- §9.7 / 7.10 chunk m (`ff1e62a`) — D-049 SEGV 解消。call_indirect
  funcref table population in `setupRuntime`。Edge fixture
  `test/edge_cases/p7/call_indirect/funcref_roundtrip.{wat,wasm,expect}`
  追加。
- §9.7 / 7.10 chunks a..l-partial (`a8777ac`..`911b92c`)。
  compile-pass 0 → 45/55 (D-048 が大寄与)。
- §9.7 / 7.9 [x] — arm64 realworld JIT 52/55 compile-pass。
