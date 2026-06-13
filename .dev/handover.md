# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **ROADMAP widget: Phase 17 = IN-PROGRESS (feature line)** — the
  **CM + WASI-P2 wasmtime-equivalent campaign CLOSED 2026-06-13**
  (component_model_plan.md ARCHIVED-IN-PLACE; Retrospective filled:
  Tier 2 EXCEEDED — typed embedder API ADR-0183, sockets incl. windows
  AFD readiness with D-319 discharged, guest-defined resources D-322,
  component default-ON ADR-0182, validator rules 1–12, corpus
  **158/0/0**, rust+tinygo proofs 3-host green).
- **ADR-0184 COMPLETE 2026-06-13 (Status: Implemented)** — engine-owned
  io for C-API WASI: (1) `0f9dcfc6` engine-owned `std.Io.Threaded`;
  (2) `12d71f5d` `zwasm_wasi_config_preopen_dir`; (3) `8be99968`
  `zwasm_wasi_config_inherit_env`; (4) `e9cfe566` C-API preopen e2e
  smoke (`test/c_api_conformance/wasi_preopen.c` + committed guest
  fixture `wasi_preopen_guest.wat/.wasm`, argv[1]-wired via build.zig
  `wasm_arg`; red-verified — wrong content fails, missing preopen
  fails). **D-255 discharged**; **D-007 discharged** (stale "minimal
  WASI subset" row — full preview1 + CLI preopens/env long landed);
  ROADMAP 13.3 resolution note appended. `inherit_argv` stays deferred
  per the ADR (no Zig-0.16 library-side process-args path).
- **Campaign-close audit DONE** (private/audit-2026-06-13.md): 0 block;
  health good. Docs sweep + simplify sweep (3/3) done — campaign-grown
  surfaces clean.
- **D-290 progressed**: regen_spec_2_0_assert.sh migrated to
  wasm-tools (swap-GREEN, exact 25437/0/489 parity; + D-148
  supported_multi staleness fixed). Remaining blocked distillers =
  regen_wasmtime_misc.sh + regen_spec_simd_assert.sh (re-curation
  class — per-fixture work, the D-290 row has the full evidence).
- Mac test/lint green per commit; ubuntu test-all baseline green
  2026-06-13 (exit 0, post-account-switch re-kick); windows batch not
  due (last batch landed pre-stop).
- **NEXT (first chunk): CWFS north-star gap (user-surfaced 2026-06-13)**
  — extend `TypeInfo.exportedFuncs` to ENUMERATE interface-nested funcs
  (walk exported instances; emit path-qualified `<iface>#<func>`
  entries — the resolution machinery exists in exportedFuncIndex, only
  enumeration is missing). Required for CWFS's require-like automatic
  component intake; small chunk + test over resource_counter.wasm.
- **THEN**: D-290 re-curation distillers (regen_wasmtime_misc /
  regen_spec_simd_assert — per-fixture work, evidence in the row) ·
  debt long-tail · §1.3 backlog demand-driven · D-323 blocked-by.
- **Other open**: D-323 (stdlib NTSTATUS, blocked-by) · D-318 (note,
  non-gating Rosetta limitation) · §1.3 backlog demand-driven.

## Closed-work pointers (detail in git log / ADRs)

- **d314-jit-sandbox CLOSED 2026-06-12** (interrupt/fuel/mem-cap triad on
  both engines + CLI + C-API; ADR-0179). **GATE NOTE (D-311 residual)**:
  raw-entry-call tests crash seed-flakily in `zig build test` (at-exit IPC
  variant prints `failed command:` but exits 0); 3-host test-all is the
  authority (`releasesafe_jit_failures.md`).
- **JIT-correctness pass 2026-06-12**: wasm-3.0 JIT assert_return 880/0 on
  BOTH arches (`e758412a..9a9b46de`). D-318 (note): Rosetta x86_64-macos
  corpus-JIT SEGVs, local-diagnostic only.
- Earlier: embedder-hardening · Tier-1 static-lib · interp sandboxing ·
  musl (ADR-0178) · host-infra hardening (`3e501d9c`).
- **Open user-decision follow-ons**: Tier-2 #5 ILP32/watchOS.

## State at pause (stable baseline)

- **Core Wasm 1.0/2.0/3.0**: 100% spec, 0 skip, 3-host green. v0.2 features +
  official corpora complete. WASI 0.1 complete. Sandboxing triad everywhere.
- **CM + WASI-P2**: default-ON (ADR-0182); real Rust/Go wasip2 components run
  e2e; typed API (ADR-0183); validator rules 1–9; corpus 139/0/19.
- **Surfaces**: C-API 293/293 (+preopen_dir/inherit_env per ADR-0184) ·
  Zig-API complete (docs §3.9) · lean CLI · memory-safety sound ·
  dogfooded into cw v1. Runners ReleaseSafe (ADR-0177).
- Debt ledger: zero `now` rows; rest `blocked-by`/`note` long-tail
  (blocked-by = call_ref / future proposals).

## Key refs

- [`docs/handoff_cw_v1.md`](../docs/handoff_cw_v1.md) — consumer-side handoff.
- **ADR-0184** (engine-owned io, Implemented) · **ADR-0179** (sandboxing) ·
  **ADR-0156** (no release) · **ADR-0153** (rework posture) ·
  **ADR-0174** (windows gate) · **ADR-0170/0176/0177** (CM / validation / runners).
- [`component_model_plan.md`](component_model_plan.md) ·
  [`releasesafe_jit_failures.md`](releasesafe_jit_failures.md) (D-311 residual).
