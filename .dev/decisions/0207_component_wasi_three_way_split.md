# ADR-0207: component_wasi_p2.zig three-way split (D-444)

- **Status**: Proposed
- **Date**: 2026-08-12
- **Front**: S1 of the pre-v2.5.0 cleanliness sweep (user-directed 2026-08-11);
  campaign `s1-d444-three-way-split` per ADR-0153 discipline.
- **Findings base**: D-444 row Phase-I structural map (2026-08-11) + the
  Phase-II characterization net (7 in-file tests, commits `3c935b12a`,
  `6fc672a30`, `e546857`).

## Context

`src/api/component_wasi_p2.zig` is 5649 lines — past even the FILE-SIZE-EXEMPT
cap (2500, ADR-0099). It accreted three distinct responsibilities:

1. **Shared substrate** (~lines 92–2171 + stream engine): `WasiP2Ctx` (resource
   tables, parked-work queues, poll/deliver engines), the generation-neutral
   host-stream peer engine (`p2StreamFutureCopyInner`), async builtins glue,
   `defineSynth`, and marshalling helpers used by BOTH generations
   (`descriptorFilestat`/`pathFilestat`, `decode`/`writeIpSocketAddress`).
2. **P2 trampolines + orchestration**: the 0.2 trampoline set,
   `defineClassifiedFunc` (exhaustive `P2Op` binding switch),
   `buildWasiP2Component` / `runWasiP2Main`.
3. **P3 trampolines** (~2340 lines, non-contiguous): fs3 / sock3 / http3 +
   `defineAsyncLoweredOp` (28/30 entries P3).

The original D-444 plan ("move the P3 trampolines out") is WRONG (Phase I): P2/
shared code calls INTO P3 at three non-negotiable sites — `p2ResourceDrop` →
`http3DropTransferredEnd`, `pollBlockedUdpReceives` → `sock3UdpReceiveComplete`,
and the host-stream engine → `fs3FailFileStream` / `sock3ResolveSendFuture` /
`sockErrToFs3Code` / `fs3DirStreamRead` — so a one-way extraction yields a
bidirectional import pair.

## Decision

**Three-way split with hook inversion** (the zone_deps lower-needs-higher
vtable pattern applied at file level; all files stay Zone 3 `src/api/`):

- **(a) `component_wasi_ctx.zig`** — shared substrate: `WasiP2Ctx` + tables +
  poll/park/deliver engines + host-stream peer engine + async glue +
  `defineSynth` + generation-neutral marshalling helpers. Declares a
  **`P3Hooks` fn-pointer set** for the reverse-dep sites (drop-transferred-end,
  udp-receive-complete, fail-file-stream, resolve-send-future, err-code map,
  dir-stream-read). An unset hook reached at runtime = `@panic("P3 hook
  uninstalled (ADR-0207)")` per `platform_panic_vs_error.md` — reaching it
  requires P3 resources, which only exist once (c) installed the hooks.
- **(b) `component_wasi_p2.zig`** — P2 trampolines, `defineClassifiedFunc`'s
  P2 arms, `buildWasiP2Component` / `runWasiP2Main` orchestration (may import
  (a) and (c) freely — no cycle). **Compat re-exports** keep the 12 externally
  imported pub symbols resolving here (`WasiP2Ctx`, `WasiP2Error`,
  `buildWasiP2Component`, `runWasiP2Main`, `p2*` trampoline fns,
  `http3DropTransferredEnd`).
- **(c) `component_wasi_p3_host.zig`** (name reserved by ADR-0190) — fs3 /
  sock3 / http3 trampolines, `defineAsyncLoweredOp`, a P3-arm registration fn
  for the classifier (~100 lines), and `installP3Hooks(ctx)` called by
  `buildWasiP2Component`.

### Migration sequence (each step lands green: `test` + `test-wasi-p3` + corpus)

- **M1**: introduce `P3Hooks` IN-FILE — route the three reverse-dep call sites
  through `ctx.p3_hooks`; `WasiP2Ctx.init` self-installs while co-located, so
  every existing test exercises the indirection with zero call-site churn.
- **M2**: extract (c) + move hook installation to its `installP3Hooks`
  (called by `buildWasiP2Component`); classifier gains the P3 registration fn;
  compat re-exports land in (b). Direct P3 calls remaining in substrate code
  surface as compile errors here and are hook-routed on the spot.
- **M3**: extract (a); (b) keeps P2 trampolines + orchestration.
- **M4**: measure; sub-split (b)'s P2 fs / sockets clusters ONLY on a positive
  ADR-0099 condition, else honest `FILE-SIZE-EXEMPT` markers.

### Invariants (anti-regression)

- **I1**: the 12 externally imported pub symbols keep resolving via
  `component_wasi_p2.zig` (re-export is the compat mechanism).
- **I2**: behaviour-preserving code motion ONLY — no semantic change rides
  along; the Phase-II tests move WITH their functions and stay green.
- **I3**: every new file carrying in-file tests is added to `zwasm.zig`'s
  test-discovery block IN THE SAME COMMIT (the II-2a dead-discovery lesson;
  S5 mechanizes the guard).
- **I4**: no new cross-zone imports; `zone_check` baseline stays 0.

### Measurable exit

Each of the three files ≤ the ADR-0099 hard cap (2000) or carrying a specific
EXEMPT rationale ≤ 2500; full 3-OS CI green; D-444 discharged.

## Alternatives rejected

- **One-way P3 extraction** (original row plan): bidirectional imports
  (Phase-I finding).
- **comptime generation-generic trampolines**: compile-time complexity with no
  change-cadence benefit; hooks mirror an existing project pattern.
- **Immediate 5+-file split**: N3 shallow-module risk before M2 measurement.

## Consequences

- (b) stays ~3200 lines after M2 — M3 decides split-vs-EXEMPT by measurement,
  not by reflex (ADR-0099 smell discipline).
- `component_wasi_p3.zig` (test file) may keep importing via (b)'s re-exports;
  its import lines are NOT churned in M1/M2.
- D-444's row gains a discharge pointer to this ADR at campaign close.
