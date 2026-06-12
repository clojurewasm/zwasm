# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **ROADMAP widget: Phase 16 = DONE, Phase 17 = IN-PROGRESS** (v0.2 feature
  line; NOW-pointer = the CM + WASI-P2 wasmtime-equivalent campaign,
  user-directed 2026-06-07, driver `component_model_plan.md`). The recent
  user-directed pivots (security → JIT-correctness → D-314 sandboxing) are
  all COMPLETE, so per resume rules (ROADMAP wins over this file) an
  unattended `/continue` resumes the **CM campaign at the plan's Work
  sequence** — the "Parked" note at the bottom predates those pivots'
  completion. If the user prefers debt work instead, the candidates are in
  NEXT below.
- Last: **E2 Go proof LANDED @2976e380** (bundle e2-go-wasip2-host CLOSED —
  exit MET: tinygo wasip2 hello prints "hello" e2e; the fs component
  round-trips mkdir/write/stat/rename/readdir/remove → "FS-OK b.txt").
  Shipped with it: P2 host completion (path-`*-at` trampolines +
  directory-entry-stream + get-random-u64), **start-via-import dispatch fix**
  (Wasm §4.5.4; wit-component start-shim), CLI `--dir` → component path,
  POSIX-style dir opens in P1 pathOpen. Earlier this session:
  E3-CM-validation bundle CLOSED (validator rules 1–8; corpus 18/0 + 2
  reasoned skip-impl). Mac test-all+lint+cross-compile green per chunk.
- **d3-8-sockets-tcp bundle CLOSED (exit MET)**: ADR-0180 Phase 1 shipped —
  `p2_sockets.zig` TcpSocket over `std.Io.net` (impl-1) + component
  trampolines with REAL poll(2) readiness, honest not-supported stubs
  (listen/accept/options/UDP/name-lookup), and real
  get-arguments/get-environment (impl-2/3 @edd5eaad, e2e test follow-up
  commit). Proof: `wasi_p2_tcp_rust.wasm` (rustc wasip2 std::net) connects
  to a loopback echo server and round-trips e2e ("got pong-ping"). Also:
  E3 error-path fixture `wasi_p2_fs_err_go` · sockets survey · ADR-0180.
  Phase 2 (listeners + windows WSAPoll D-319) + Phase 3 (UDP/name-lookup)
  deferred per ADR-0180.
- **E3 corpus growth LANDED**: 115 official assert_invalid cases
  distilled verbatim into `official_distilled/`; gap-driven validator
  extensions (rule-1 definition-order bounds, rule-8 nested-scope
  names, NEW rule-9 instantiate/inline-export/sortidx bounds, rule-3/6
  count-0 outer-alias existence) → **corpus 105 pass / 0 fail / 30
  reasoned skip-impl** (was 18 pass). test-all+lint green.
- **ADR-0181 LANDED (user-approved 2026-06-13)**: version lines retired
  from the ROADMAP; §1.2 floor gained CM + WASI-0.2 wasmtime-equivalent
  rows; §1.3→capability backlog; optimising tier → §3.2 permanent-out;
  §3.3/§7/§8 reality-synced (atomics=instruction-set shipped, threaded
  EXECUTION deferred; native P2 host described). New D-320 (note):
  lightweight axis needs a binary-size/poll-code-size bench series.
- **ADR-0182 LANDED**: component support default-ON (`-Dcomponent=false`
  = real lean opt-out; CM subsystem measured at 156 KB / +8.3%). D-321
  (gate rot) discharged; D-320 size series live
  (`scripts/record_binary_size.sh`, base 1.94 MB / lean 1.78 MB).
- **Rule-5 grammar COMPLETE** (dep/url/integrity/semver/projection +
  import-only forms): corpus **136 pass / 0 fail / 19 skip-impl**. Win
  batch at 43ab91a8: all suites green on win64 incl. component corpus;
  the one red was the NEW TCP e2e lacking its D-319 gate — fixed
  @d0cd9f67 (next batch verifies + --record).
- **NEW NOW-POINTER (user-directed 2026-06-13): ADR-0183 typed component
  embedder API** — CWFS's ADR-0135 made WIT the north star
  (component-as-namespace; no .wit sidecar; records↔maps etc.). See
  `## Active bundle`. After: sockets Phase-2 / remaining 19 validator
  skips / D-318 / D-314 / D-251.

## Active bundle

- **Bundle-ID**: typed-component-api (ADR-0183 / plan Phase F)
- **Cycles-remaining**: ~4
- **Continuity-memo**: F1 `ComponentValue` union + `exportedFuncs()`
  introspection (decode data already has exports + full type space;
  this is facade plumbing) → F2 typed lower (reuse canon.zig
  size/align/flatten + cabi_realloc patterns from the P2 trampolines)
  → F3 lift + compound round-trip → F4 wit-bindgen proof fixture +
  `assert_typed` corpus directives. Consumer = CWFS wasm/load+wasm/call
  today (scalar-only); they're blocked on this surface.
- **Exit-condition**: a committed wit-bindgen component exchanging
  `record{list<u32>, string}` ↔ `result<record, string>` round-trips
  through `invokeTyped` in an e2e test (greet also callable typed).

## Sandboxing bundle d314-jit-sandbox — CLOSED 2026-06-12

Exit-condition MET and exceeded: a JIT looping/recursive fn traps when the host
raises the flag — and the full triad now spans both engines + CLI + C-API.

- **#3a interrupt**: prologue polls both arches (`c1a9da15`/`6d56f517`); loop
  back-edge polls + x86_64 R15-forcing (`72801881`); arm64 br_table-to-loop +
  honest RUNNING-loop thread-raiser tests, hang-as-failure (`b365c190`).
- **#3b fuel-on-JIT** (`a6d7ae72`): `fuel_metered`/`fuel_cell` polls beside the
  interrupt polls; units = poll-site crossings (v1 parity, ADR-0179 rev); kind
  17 = `TrapKind.out_of_fuel` wired interp+JIT+runner; new `encSubMem64Disp32Imm8`.
- **#3c-2 mem-cap-on-JIT** (`866d784e`): `MemGrowCtx.host_max_pages` +
  `JitInstance.setMemoryPagesLimit` (host-side only).
- **#3a-4 CLI** (`ce2ded2b`): `--fuel`/`--timeout`/`--max-memory` on both
  engines (io-event-loop timer → shared interrupt flag; cwasm/component refuse
  loudly); **C-API** (`f1a88e77`): `zwasm_instance_*` setters + `zwasm_trap_kind`
  in new `src/api/zwasm_ext.zig` + real `include/zwasm.h` (naming rev in
  ADR-0179: instance-level over v1's config-level).
- Follow-ons re-scoped into the **D-314 `note` row** (epoch counter, JIT
  table-elems limit, cwasm/component limits, facade-JIT routing, poll
  code-size measurement). Facade stays interp-only (live security posture).

**GATE NOTE (D-311 residual)**: the 3 raw-entry-call tests crash seed-flakily in
`zig build test`; NEW variant: under the build-runner `--listen` IPC the unit
binary can crash AT EXIT after all results stream back OK — zig prints
`failed command:` but exits 0; standalone = green. Don't chase as a new bug;
3-host test-all is the authority (`releasesafe_jit_failures.md`).

## JIT-correctness pass (2026-06-12) — LANDED, 2-host green

wasm-3.0 JIT mode = assert_return 880/0 on BOTH arm64 + x86_64, matching interp
(`e758412a..9a9b46de`). Shipped: GC-ref-through-table corruption `9a9b46de`;
memory64 `ea+size` overflow `fc5be95e` (D-234 reopened+fixed); capture-allocator
`008dc3be`; D-237 double-free `314a0c97`; 36 stale multi-memory skips `93792696`.
**D-318** (note): Rosetta x86_64-macos FULL corpus-JIT SEGVs (local-diagnostic
only). Remaining jit-mode skips are eligibility-gated, NOT correctness.

**Prior passes (green, pushed; detail in git log)**: embedder-hardening
`14de5430..d6699b00` (InstantiateOpts budgets, decoder robustness, D-315/D-316,
Actions SHA-pinned); Tier-1 — static-lib `45438b7a` (D-312), ADR-0179 design +
interp sandboxing triad (`1001fa0e`/`460210f1`/`7216e7b1`/`58479dd6`),
migration-guide Phase B/D, musl (ADR-0178). Host-infra hardening 2026-06-12
`3e501d9c` (gate timeouts, orphan reaps — host memory-exhaustion incident,
lesson `host-memory-exhaustion-defenses`).

**Documented follow-ons (need a user decision / focused effort)**:
- **#1 C-API WASI preopen — D-251**: pure C-API has no `std.Io` to open dirs;
  needs an io-acquisition ADR. CLI `--dir` + Zig API cover preopen today.
- **Tier-2 #5** ILP32/watchOS (static-lib target + #97 accommodations).

## State at pause

- **Core Wasm 1.0/2.0/3.0**: 100% spec, 0 skip, 3-host green. **v0.2 features**
  (atomics / wide-arith / custom-page-sizes / relaxed-SIMD) complete + official
  corpora. **WASI 0.1** complete. **Sandboxing triad on both engines + CLI/C-API.**
- **Component Model + WASI Preview 2** (opt-in `-Dcomponent`): a real Rust
  wasm32-wasip2 component runs e2e (ADR-0170/0175); E1 spec-corpus runner;
  structural validation rules 1-4 (ADR-0176).
- **Surfaces**: C-API 293/293 gap-free + zwasm.h extensions · Zig-API complete ·
  CLI (`run`/`compile` + sandbox flags, intentionally lean) · memory-safety
  sound · dogfooded into cw v1.
- **Test iteration**: integration runners ReleaseSafe (ADR-0177); unit
  `zig build test` Debug; `test-all` auto-fast.
- Debt ledger **54 entries**, **zero `now` rows**; D-314 re-scoped to `note`
  (follow-on list). Rest `blocked-by`/`note` = long-tail.

**Parked (demand-driven)**: WASI-P2 sockets; Go/tinygo proof; 32
`blocked-by` debt (call_ref / future proposals). (CM deeper conformance is
NO LONGER parked — it is the ROADMAP Phase-17 NOW-pointer, see Current
state.)

## Key refs

- [`docs/handoff_cw_v1.md`](../docs/handoff_cw_v1.md) — consumer-side handoff.
- **ADR-0179** (sandboxing, Revisions 2026-06-12) · **ADR-0156** (no release) ·
  **ADR-0153** (rework posture) · **ADR-0174** (windows gate) ·
  **ADR-0170/0176/0177** (CM / validation / runners).
- [`component_model_plan.md`](component_model_plan.md) ·
  [`releasesafe_jit_failures.md`](releasesafe_jit_failures.md) (D-311 residual).
