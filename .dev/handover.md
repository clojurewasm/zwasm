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
- Recently closed bundles (detail in git log): e2-go-wasip2-host
  @2976e380 (tinygo hello + fs e2e; start-via-import fix; CLI --dir) ·
  d3-8-sockets-tcp @edd5eaad (ADR-0180 Phase 1: TcpSocket + real poll(2)
  readiness; rust TCP client e2e) · E3-CM-validation (rules 1-8).
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
- **typed-component-api bundle CLOSED (exit MET)**: ADR-0183 F1–F4
  shipped — ComponentValue + binary introspection + canonical-ABI call
  flattening (+ canon memory-staleness fix) + invokeTyped /
  invokeTypedBuilt + named-type/nested-scope resolution. PROOF:
  wit-bindgen `typed_payload` round-trips rich types typed. Both CWFS
  ADR-0135 runtime asks servable.
- **Typed-API polish LANDED**: `assert_typed` + `component_p2` corpus
  directives · typed-invoke core deduped into `api/component_typed.zig`
  (P1 split) · docs `zig_api_design.md` §3.9.
- **Component spec corpus COMPLETE: 158/0/0** (skips 19→0 this
  session): index spaces + def-order alias_space_before + semantic
  extern-name keys @6c895983 · rule 10 nested type-scope deep validation
  @09c4d520 · rule 11 core-type section decode @785acfaf · rule-9
  sortidx bounds @7ee5c997 · last case resolved @e988e4f4 — it rejects
  via the UNDECODED resource-definition form (0x3f), the right verdict
  for a decode-level reason; **D-322** (note) tracks the honest
  residual: resource defs 0x3f/0x3e decode + the outer-alias
  generativity rule + an exported-resource fixture must land TOGETHER.
- **adr0180-phase2-listeners bundle CLOSED (exit MET on the re-scope
  arm)**: listeners/accept/local+remote-address/backlog + WSAPoll all
  LANDED (rust TcpListener e2e green Mac+ubuntu); windows verification
  HUNG (timeout 3600) in the de-skipped test step → tests re-gated
  @d039d727, D-319 row re-scoped to the named hang barrier (3-hypothesis
  list + targeted-probe plan in the row). D-320 size datapoint: base
  1.97 MB (+37.6 KB), lean unchanged.
- **D-319 ROOT CAUSES FOUND (probes #2/#3)**: (a) WSAPoll failed WSA
  10093 WSANOTINITIALISED — the pinned std.Io.net windows backend is
  pure NT/AFD, winsock never initialized; FIX LANDED (lazy WSAStartup in
  pollOnce). (b) netConnect maps NTSTATUS 0xC0000236 (CONNECTION_REFUSED)
  to error.Unexpected — pinned-stdlib gap, recorded. PROBE #4: WSAENOTSOCK
  — winsock structurally unusable on the stdlib's raw NT/AFD handles.
  FIX LANDED: pollOnce windows branch = IOCTL_AFD_POLL via
  ntdll.NtDeviceIoControlFile (wepoll approach; zero-timeout snapshot;
  winsock externs removed). PROBE #5 in flight → /tmp/win_probe5.log at
  Step 0.7: lifecycle tests green ⇒ only residual = the stdlib
  connect-refused NTSTATUS mapping (test expectation), then de-skip e2e
  and re-verify the hang.
- **D-322 CORE LANDED @3cf52d80**: resource defs (0x3f) decode (raw-byte
  peek — 0x3f is sleb-positive) + dtor core-func bounds + rule 12
  resource generativity (nested-component recursive scan; the corpus
  case now rejects via the REAL rule) + runner prints reject reasons +
  core_scan.zig P1 split (types.zig was past the 2000 cap). D-322
  residual = guest-resource RUNTIME path (exported-resource fixture e2e).
- **D-322 Phase-I MEASURED**: resource_counter fixture committed
  (wit-bindgen guest resource); gap = UnknownImport on the synthesized
  `[export]<iface>` `[resource-new]/[resource-drop]` core imports → wire
  canon resource.new/drop/rep core_funcs to the C1 resource table in the
  graph builder, then ComponentValue own-handle arms for the typed path.
- **NEXT**: D-322 runtime bundle — wiring plan SURVEYED: in
  buildWasiP2Component, walk info.core_funcs .resource_new/.resource_drop
  (CanonDef carries the resource type_index) and defineFuncCtx
  trampolines under module `[export]<iface>` / names
  `[resource-new/drop]<type>` (wit-component constants confirmed),
  backed by a per-instance ResourceTable (C1 API: new(rt,rep)/rep/drop;
  rt = the DEFTYPE index — the hardcoded WasiP2Ctx RT ids must not
  collide; instance.zig:419-540 is the UnknownImport loop). Then
  ComponentValue own-handle arms. After: D-319 probe #4 verdict ·
  D-318 · D-251.

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
- **Open user-decision follow-ons**: D-251 (C-API WASI preopen io ADR);
  Tier-2 #5 ILP32/watchOS.

## State at pause (stable baseline)

- **Core Wasm 1.0/2.0/3.0**: 100% spec, 0 skip, 3-host green. v0.2 features +
  official corpora complete. WASI 0.1 complete. Sandboxing triad everywhere.
- **CM + WASI-P2**: default-ON (ADR-0182); real Rust/Go wasip2 components run
  e2e; typed API (ADR-0183); validator rules 1–9; corpus 139/0/19.
- **Surfaces**: C-API 293/293 · Zig-API complete (docs §3.9) · lean CLI ·
  memory-safety sound · dogfooded into cw v1. Runners ReleaseSafe (ADR-0177).
- Debt ledger: zero `now` rows; rest `blocked-by`/`note` long-tail (32
  blocked-by = call_ref / future proposals).

## Key refs

- [`docs/handoff_cw_v1.md`](../docs/handoff_cw_v1.md) — consumer-side handoff.
- **ADR-0179** (sandboxing, Revisions 2026-06-12) · **ADR-0156** (no release) ·
  **ADR-0153** (rework posture) · **ADR-0174** (windows gate) ·
  **ADR-0170/0176/0177** (CM / validation / runners).
- [`component_model_plan.md`](component_model_plan.md) ·
  [`releasesafe_jit_failures.md`](releasesafe_jit_failures.md) (D-311 residual).
