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
- ADR-0181 (ROADMAP reality-sync; version lines retired) + ADR-0182
  (component default-ON; D-320 size series) + rule-5 grammar all LANDED
  — detail in git log / the ADRs.
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
- **D-319 DISCHARGED** (probe chain #1–#6): windows wasi:sockets
  readiness = IOCTL_AFD_POLL via NtDeviceIoControlFile (winsock is
  unusable on the pinned stdlib's raw NT/AFD handles — lesson
  winsock-vs-nt-afd-handles). Probe #6 full-green on windowsmini incl.
  both rust e2e; the old hang was a guest poll loop on never-ready
  readiness. All gates + probe flag removed — windowsmini runs the full
  socket suite per batch. Residual: D-323 (stdlib unmapped
  connection-refused NTSTATUS; degraded `unknown` error-code pinned).
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
- **D-322 RUNTIME LANDED**: guest-defined resource builtins wired
  (synthDef resource_builtin defs + per-def trampolines over the NEW
  ctx.guest_resources table + build-time dtor resolution); the
  resource_counter fixture builds and round-trips through real
  wit-bindgen code (methods take the REP — canon lift translates
  handle→rep). D-322 residual: ComponentValue own-handle arms so
  invokeTyped drives constructor→method BY HANDLE (incl. the lift-side
  handle→rep translation for exported methods).
- **D-322 CLOSED (typed guest resources e2e)**: own/borrow through the
  whole canonical-ABI bridge (slice a, unit-pinned) + slice b: the
  CanonContext borrow_rep hook wired in invokeTypedBuilt, and
  `<iface>#<func>` export paths resolved through wit-component's
  interface-WRAPPER instantiations (nested-scan import/export maps;
  instance_origins local-ordinal mapping). PROOF: typed
  [constructor]counter → ComponentValue.own → borrow methods mutate the
  boxed state; unknown handles are typed shape errors. The CWFS "WIT as
  north star" stack is now end-to-end: introspection + typed calls +
  guest-defined resources.
- **NEXT**: D-318 (Rosetta corpus-JIT diagnostic) · D-251 (C-API WASI
  preopen ADR draft) · D-323 (stdlib NTSTATUS, blocked-by) · CM plan
  long-tail per component_model_plan.md.

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
