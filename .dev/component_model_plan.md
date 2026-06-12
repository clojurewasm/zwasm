# Component Model + WASI Preview 2 — campaign plan

> **Doc-state**: ACTIVE
> Authoritative driver for the CM campaign (ADR-0170). The **§Work sequence**
> below supersedes ROADMAP §17 row ordering for this campaign (close-plan
> override): the loop follows the first unchecked chunk here. Per-chunk recipe
> = goal · files · references · red test · exit. Keep `[x]` flips current.

## Goal

Component Model + WASI Preview 2 to **wasmtime-equivalent conformance**, the
zwasm-v2 way: spec/test-referenced (NOT copied), philosophy-maintained,
proven by Rust+Go sample components. Full mandate + rationale: **ADR-0170**.

## Reference chains (read per chunk; textbook, never copy)

- **Spec (ground truth)**: `~/Documents/OSS/WebAssembly/component-model/` —
  `design/mvp/Binary.md` (component binary), `CanonicalABI.md` (lift/lower +
  size/align/flatten), `Explainer.md`, `WIT.md`; its `test/` vectors.
- **v1 textbook (re-derive, don't paste — `no_copy_from_v1`)**:
  `~/Documents/MyProducts/zwasm/src/component.zig` (1898 — decoder + instantiate
  + `WasiAdapter` @~799), `wit.zig` (2098 — WIT type system), `canon_abi.zig`
  (1165 — lift/lower, densest fixtures), `wit_parser.zig` (446).
- **Conformance/shape references (Rust; read for behaviour, never copy)**:
  `~/Documents/OSS/wasm-tools/crates/{wasmparser (component parse), wit-parser,
  wit-component}`; `~/Documents/OSS/wasmtime/crates/{environ/src/component,
  wasmtime/src/runtime/component}` (resource_table, canonical ABI).
- **Sample-project toolchains**: `~/Documents/OSS/wit-bindgen/` (Rust+Go
  bindgen); cargo-component (Rust), tinygo (Go) — invoked via `nix develop .#gen`
  on the Mac host only; committed `.wasm` run on test hosts (toolchain_provisioning).
- v2 survey: `.dev/component_model_survey.md` (architecture, 4 hard pieces).

## Discipline (every chunk)

- Zone-2 new layer in `src/feature/component/`; gated `-Denable=component`
  (+ `-Dwasi=preview2` for WASI work). NO change to ZIR/ZirOp/`runtime.Value`/
  Zone structure — consume `runtime/instance/*` + memory + `Runtime.invoke` as
  a black box (the survey's "zero core-VM changes" property).
- Component-level value type kept **distinct** from `runtime.Value`
  (`single_slot_dual_meaning`).
- TDD red→green; spec-citation docstrings (`spec_citation`); boundary fixtures
  for every ABI size/align/discriminant edge (`test_discipline §1`).
- Spec corpus + sample projects are the proof; inline tests are the net.
- 3-host gate (ADR-0076), no-copy, spike-for-unknowns, **no release** (ADR-0156).

## Tiers

- **Tier 0** (chunks A1–A4): decode + WIT parse/validate, NO execution. Can
  claim "parses/validates components." Zero core risk.
- **Tier 1** (B1–C2): canonical ABI + single/multi component instantiate+invoke
  + resources. Can claim **"Component Model works"** (run a real component, call
  exports). v1-parity-class.
- **Tier 2** (D1–E3): WASI Preview 2 (P2→P1 adapter → native hosts) + official
  conformance corpus + Rust/Go sample-project proof. wasmtime-equivalent.

## Work sequence

Each chunk: source commit + handover/`[x]` commit (per-chunk pair). Chain
several per turn (D5-a) where the recipe is established; split at ADR-grade
design forks. Update this doc's `[x]` + handover NEXT each chunk.

### Phase A — decode + WIT (Tier 0)

- [x] **A1 — component binary discriminator + section walk.** `decode.zig`:
  distinguish core module (`\0asm` + version `01 00`) vs component (`\0asm` +
  layer `01 00 0d 00`); enumerate component sections (custom/core-module/
  core-instance/core-type/component/instance/alias/type/canon/start/import/
  export). Open `src/feature/component/` + flip the build gate (was rejected).
  **Refs**: spec `Binary.md`; wasm-tools `wasmparser` component reader; v1
  `component.zig` decoder head. **Red**: a minimal component binary → section
  list; a core module is classified core (not component). **Exit**: decoder
  enumerates sections of a wasm-tools-emitted empty component. **ADR**: opening
  the slot + component-value-vs-`runtime.Value` boundary (small, in ADR-0170
  scope; note in commit).
- [x] **A2 — component type + import/export index spaces.** Decode component
  type section (func/instance/component types), import/export decls. **Refs**:
  `Binary.md` §type, v1 `component.zig`. **Red**: a component declaring an
  imported+exported func type round-trips to the type model. **Exit**: type
  index space resolves.
- [x] **A3 — WIT lexer + parser (primitive subset).** `wit/lexer.zig` +
  `wit/parser.zig`: tokenize + parse package/world/interface/func with
  primitive params/results (no resources/handles yet). **Refs**: spec `WIT.md`;
  v1 `wit_parser.zig`; v1 `src/testdata/10_greet.wit`/`11_math.wit`. **Red**:
  parse a `10_greet`-class `.wit` to an AST. **Exit**: AST for the primitive
  subset.
- [x] **A4 — WIT resolver + type model.** `wit/resolve.zig`: resolve type refs,
  build the resolved WIT type model (the canon ABI's input). **Refs**: wasm-tools
  `wit-parser` resolve; v1 `wit.zig`. **Red**: resolved model for a multi-interface
  world. **Exit**: Tier 0 complete — decode + WIT parse/validate green.

### Phase B — Canonical ABI + single-component execution (Tier 1 core)

- [x] **B1 — CanonContext + `cabi_realloc` callback.** `canon.zig`: the one core
  coupling — lift/lower call back into the guest to allocate via a
  `Runtime.invoke`-style callback. Scaffolding for register-passed primitives.
  **Refs**: spec `CanonicalABI.md` (flattening); v1 `canon_abi.zig` +
  `types.zig` `cabiRealloc`. **ADR**: the `cabi_realloc`/CanonContext core touch.
  **Red**: lower→lift an i32 round-trips through a trivial component func.
- [x] **B2 — canon primitives + flags** (bool/ints/floats/char/enum/flags;
  size/align/discriminant). Boundary fixtures per type. **Red**: each primitive
  round-trips; flag bit-packing matches spec.
- [x] **B3 — canon string** (utf8 first; utf16/latin1 next) over linear memory
  via realloc. **Refs** `CanonicalABI.md` string encoding. **Red**: a string
  round-trips guest↔host.
- [x] **B4 — canon list + record** (element/field layout, alignment). **Red**:
  `list<u32>` + a record round-trip.
- [x] **B5 — canon variant/option/result/tuple** (discriminant + payload align).
  **Red**: option/result/variant round-trip.
- [x] **B6 — single-component instantiate + invoke end-to-end.** Embed core
  module(s) → `instantiate.zig` per module → wire canon trampolines → invoke an
  export. **Red**: a real wasm-tools/cargo-component component exporting a
  `string→string` func runs via zwasm and returns the expected string. **Exit**:
  Tier 1 core — "a component runs."

### Phase C — resources + linking (Tier 1 complete)

- [x] **C1 — resource type + handle table.** `resource_table.zig`: own/borrow,
  `resource.new/drop/rep`, parent/child ownership + tombstones (the live table
  is the hard part). **Refs**: wasmtime `resource_table.rs`; spec resources.
  **Red**: own/borrow lifecycle + double-drop trap.
- [x] **C2 — multi-component linking / instance graph + adapters.** **Red**: a
  2-component graph (one imports the other's interface) links + runs.

### Phase D — WASI Preview 2 (Tier 1 → 2)

- [x] **D1 — P2 worlds + P2→P1 adapter (CLI subset).** `wasi/adapter.zig`
  name-map (D1-1 @b35a683e) + host trampolines (host-ctx seam `Caller.data` /
  `Linker.defineFuncCtx`, ADR-0173; @2d099ff1) + unified core-func index-space
  (`CoreFuncDef`, @27eb59b8) + `runWasiP2Main` (@96edb868) + `zwasm run`
  component dispatch (@161236db). **Exit MET**: `zwasm run
  test/component/wasi_p2_hello.wasm` prints "hello". Broader interface coverage
  (stderr/stdin/clocks/random/exit) + adapter-classified wiring → **D-306**.
- [x] **D2 — resource-modeled P2 interfaces** (stdio/filesystem as resources,
  not just name-map). **Red MET**: resource-typed P2 fs handle ops. Bundle
  CM-D2-fs: D-306 classified host wiring (@dde03160, by COMPONENT interface not
  core name; proof `wasi_p2_hello_renamed.wasm`) · stderr @1f5474d5 · descriptor
  resource (`DESCRIPTOR_RT`) write/drop @b766c583 · get-directories @e9d05999
  (list return-area via guest `cabi_realloc` from a trampoline — nested invoke,
  lesson `2026-06-07-engine-invoke-is-reentrant…`) · open-at @a8264fb4 · generic
  resource-drop @75d79a6c · **EXIT @85bcb5a5** `wasi_p2_fs.wasm` runs e2e
  (get-directories → open-at → write "DATA42" → drop). clocks/random (free funcs,
  not resources) + exit/stdin + P1→P2 error-code (D-307) → D3.
- [x] **D3 — broader native P2 host** @3a128a01 (free-func + stdin + fs descriptor
  completion + poll all DONE; sockets deferred to E3-area, spike-first). The
  trampolines live at `api/component_wasi_p2.zig` `defineClassifiedFunc`; wiring
  map in `private/notes/p17-D3-trampoline-map.md`. Done:
  - **D3-1 cli_exit** @9ce02433 — `exit(result)` → P1 procExit; noreturn via new
    `InvokeError.ProcExit` (instance.zig unwind variant, NOT a wasm Trap) caught
    in runWasiP2Main. Fixture `wasi_p2_exit`.
  - **D3-2 monotonic-clock.now** @f90cd931 — `()->i64`; factored
    `clocks.clockTimeNs`. Fixture `wasi_p2_clock`.
  - **D3-3 wall-clock.now** @85e8685f — `()->datetime` 12B record to retptr.
    Fixture `wasi_p2_wallclock`.
  - **D3-4 random.get-random-bytes** @6040671a — `->list<u8>` via guest
    `cabi_realloc` (ctx.reallocGuest), factored `clocks.randomFill`. Fixture
    `wasi_p2_random`. First list-return op.
  - **D3-5 stdin** @7f5c6677 — `get-stdin` mints INPUT_STREAM_RT(3); `input-
    stream.read->result<list,stream-error>` via factored `fd.readStdinSlice`.
    Fixture `wasi_p2_stdin`.
  - **D3-6 fs descriptor completion + flush** @43909eba — `read`(list via
    cabi_realloc+iovec→fdPread) / `sync` / `stat`(canonical descriptor-stat
    layout) / `get-type` + `out-stream.blocking-flush`. **D-307 DISCHARGED**
    @beb887c6 — `adapter.errnoToP2ErrorCode` (canonical fs error-code ordinals);
    all fs err arms (incl open-at/write) emit `result.err(error-code)`, no trap.
    Fixtures `wasi_p2_fs_full` (5 ops, guest asserts+traps) + `wasi_p2_fs_err`
    (open-at noent → err(no-entry)). Smell: `component.zig` 1834 LOC → **D-309**.
  - **D3-7 wasi:io/poll** @3a128a01 — pollable resource (POLLABLE_RT) +
    subscribe-duration/instant + input/output-stream.subscribe mint pollables;
    `pollable.ready`→true, `block`→noop, `poll(list)`→all-ready `list<u32>`
    (synchronous always-ready host). `dropAny` returns the typed handle so the
    generic drop skips fd_close for non-fd pollables. Fixture `wasi_p2_poll`.
  - **D-309 extraction** @ccdee2fa — WASI-P2 trampolines + runWasiP2Main split to
    `api/component_wasi_p2.zig` (component.zig 1922→1250 LOC), behavior-preserving.
  - **D3-8 sockets DONE (ADR-0180 Phase 1)**: TCP-client subset with REAL
    poll(2) readiness — `src/wasi/p2_sockets.zig` (TcpSocket over
    `std.Io.net`) + component trampolines (create/bind/connect → socket-
    backed stream pair; socket-aware pollable/poll/check-write; honest
    not-supported stubs for listen/accept/options/UDP/name-lookup; real
    get-arguments/get-environment). Proof: `wasi_p2_tcp_rust.wasm` (rustc
    wasip2 std::net) echoes through a loopback server e2e. Phase 2
    (listeners/WSAPoll-windows D-319) + Phase 3 (UDP/name-lookup) deferred
    per ADR-0180. **D-308**: runWasiP2Main error-cleanup SEGVs on a
    failed-import wire (unknown-interface error path only).

### Phase E — conformance + proof (Tier 2 = wasmtime-equivalent)

- [x] **E1 — official component-model spec corpus runner.** `test/spec/component_model_assert_runner.zig`
  drives the `-Dcomponent` host API (decode+instantiate+invoke) over a corpus
  root (`test/spec/component-model-assert/`); built against a component-ENABLED
  `zwasm` module (`core_comp` in build.zig); wired into `test-all`. Directives:
  `component`/`graph` + `assert_string`/`assert_flat_i32` + `skip-impl`/`skip-adr-*`.
  Fixtures reuse the committed `test/component/` set (no duplication). ADR-0174
  lesson honoured: a missing corpus root is a hard `exit(1)`, not a silent skip.
  First corpus = greet (string→string) + adder graph (cross-module i32): 4 pass, 0 skip.
  **NEXT corpus growth = E3** (distil official `WebAssembly/component-model` + wasm-tools
  `.wat` fixtures → committed `.wasm` on Mac; truthful skips for unsupported features).
- [x] **E2 — Rust proof DONE @96e1ccce; Go (tinygo) proof DONE @2976e380.**
  tinygo 0.40.1 (already in the gen shell) builds `-target=wasip2` natively, so
  the wit-bindgen-go toolchain gate DISSOLVED (go.mod must pin `go 1.25`).
  Landed with the Go proof: P2 host completion (path-addressed descriptor
  trampolines + directory-entry-stream + get-random-u64), the
  start-function-via-import dispatch fix (wit-component start-shim), CLI
  `--dir` threading into components, and POSIX-style directory opens in P1
  pathOpen. Fixtures `wasi_p2_hello_go.wasm` ("hello") + `wasi_p2_fs_go.wasm`
  (fs round-trip "FS-OK b.txt"); e2e tests + README_wasi_p2_go.md. A real
  `rustc --target wasm32-wasip2` component (no cargo-component/adapter; flake gen
  shell gained the wasip2 target) RUNS e2e through zwasm and prints. Delivered:
  **ADR-0175** general instance-graph engine (@8eab1703 — builds every core
  instance in order; the `$fixup` `elem` fills wit-bindgen's shim `$imports`
  table) · **D-310** runtime fix (@4e802881 — imported host funcs funcref-able:
  per-import placeholder sig + call_indirect→host_calls dispatch) + component
  memory fix (@96e1ccce — trampolines source `WasiP2Ctx.mem_instance`, not the
  memory-less shim caller) · cli/environment+terminal+check-write trampolines
  (@0888a3f9) · core-table decode (@73df8a7e). Fixture
  `test/component/wasi_p2_hello_rust.wasm` (stripped 78 KB) + e2e test + dogfood.
  Remaining nit: io/error trampoline (not yet exercised — a clean run never
  errors; surfaces with an error-path fixture when one matters).
- [~] **E3 — WASI-P2 conformance + edge cases.** P2 test corpus + boundary
  fixtures; close the gap to wasmtime where "beyond is satisfiable" (ADR-0170).
  **Started**: D-308 adversarial edge case @82d63d27 — an unknown wasi import
  (`wasi:sockets/tcp`) errors cleanly (no signal); fixture `wasi_p2_unknown_import.wasm`.
  **E3-CM-validation bundle (ADR-0176) CLOSED 2026-06-12**: structural-first component validator
  `src/feature/component/validate.zig` (post-decode, pre-instantiate, all 3 host entry points), driven by the official
  `component-model/test/wasm-tools` `assert_invalid` corpus. Runner has `assert_invalid`/`assert_malformed` + `skip-impl`
  directives; **corpus 18 pass / 0 fail / 2 reasoned skip-impl**. Rules shipped: **1–4 index bounds** (type `cfdb07be` /
  canon `6224a7e7` / alias-instance `5374dca7` / externdesc `d72c1b44`) · **5 name format** (`2b2eaeac` — kebab `label`
  grammar on deftype labels + import/export names incl. interfacename/bracket forms) · **6 outer-alias count vs nesting
  depth** · **7 export-type-named** (`TypeInfo.type_space` definition-order origins) · **8 case-insensitive dup-names**.
  Remaining-category triage: nested inline-component cases (resources.wast resource-refs, ~5) = skip-impl until
  recursive nested-component decode lands (`nested_component_resource_refs/`); deep extern-name grammars
  (base64/url/dep, ~12) = skip-impl (`extern_name_deep_forms/`); deep canon-ABI/subtyping cases = ADR-0176 out-of-scope
  (later bundle); wat-text-level malformed cases = N/A for a binary validator.
  Remaining (separate): more WASI-P2 boundary fixtures (trap/handle-invalid paths).

### Phase F — typed component embedder API (ADR-0183; CWFS north-star)

- [ ] **F1 — `ComponentValue` public value tree + introspection.** The WIT
  value model as a Zig union (distinct from `runtime.Value`); 
  `exportedFuncs()` on the decoded component/instance returning typed
  signatures from the SELF-DESCRIBING binary (no `.wit` sidecar — CWFS
  ADR-0135). **Red**: greet's export introspects as `(param "name" string)
  (result string)`.
- [ ] **F2 — typed invoke: lower.** `invokeTyped(name, args)` validates
  against the export type and lowers via the canonical ABI (flat when it
  fits; `cabi_realloc` + memory writes for strings/lists/records — reuse
  `canon.zig` size/align/flatten). **Red**: call greet with
  `.{ .string = "zwasm" }`.
- [ ] **F3 — typed invoke: lift + compound round-trip.** Lift results into
  caller-owned `ComponentValue`; record/list/variant/option/result arms.
  **Red**: a wit-bindgen fixture exchanging `record{list<u32>, string}` →
  `result<record, string>` round-trips.
- [ ] **F4 — proof fixture + corpus directives.** Real wit-bindgen (rust)
  component with rich types committed via gen shell; spec runner gains
  `assert_typed` directives; docs (`docs/` Zig API section) updated.

## Retrospective (fill at campaign close)

_(Tier reached? new debt? spec-corpus pass rate? sample-projects green on 3
hosts? Revision note on `component_model_survey.md`.)_
