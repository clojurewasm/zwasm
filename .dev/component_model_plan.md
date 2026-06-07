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
- [ ] **D3 — broader native P2 host** (free-func + stdin trampolines DONE; fs
  descriptor completion + poll/sockets remain). The gap is the trampolines at
  `api/component.zig` `defineClassifiedFunc`; wiring map in
  `private/notes/p17-D3-trampoline-map.md`. Done:
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
  - **NEXT = D3-8**: **sockets** (tcp/udp — spike-first per plan). OR Phase E
    (E1 conformance corpus + E2 Rust/Go real-toolchain proof — the campaign's
    wasmtime-equivalent existence proof). **D-308**: runWasiP2Main error-cleanup
    SEGVs on a failed-import wire (unknown-interface error path only).

### Phase E — conformance + proof (Tier 2 = wasmtime-equivalent)

- [ ] **E1 — official component-model spec corpus runner.** Distil the
  `WebAssembly/component-model` + wasm-tools component tests into a runner
  (mirror `test/spec/spec_assert_runner_*`), wired into `test-all`. Track
  pass/skip with truthful reasons (no blanket skips — the D-301 lesson).
- [ ] **E2 — Rust + Go sample-project proof.** Build a Rust (cargo-component)
  AND a Go (tinygo + wit-bindgen-go) component on the Mac `nix develop .#gen`
  host; commit the `.wasm`; run via the zwasm CLI in the realworld runner
  asserting output. The "CM actually works, cross-toolchain" existence proof.
- [ ] **E3 — WASI-P2 conformance + edge cases.** P2 test corpus + boundary
  fixtures; close the gap to wasmtime where "beyond is satisfiable" (ADR-0170).

## Retrospective (fill at campaign close)

_(Tier reached? new debt? spec-corpus pass rate? sample-projects green on 3
hosts? Revision note on `component_model_survey.md`.)_
