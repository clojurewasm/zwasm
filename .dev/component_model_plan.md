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
- [ ] **B6 — single-component instantiate + invoke end-to-end.** Embed core
  module(s) → `instantiate.zig` per module → wire canon trampolines → invoke an
  export. **Red**: a real wasm-tools/cargo-component component exporting a
  `string→string` func runs via zwasm and returns the expected string. **Exit**:
  Tier 1 core — "a component runs."

### Phase C — resources + linking (Tier 1 complete)

- [ ] **C1 — resource type + handle table.** `resource_table.zig`: own/borrow,
  `resource.new/drop/rep`, parent/child ownership + tombstones (the live table
  is the hard part). **Refs**: wasmtime `resource_table.rs`; spec resources.
  **Red**: own/borrow lifecycle + double-drop trap.
- [ ] **C2 — multi-component linking / instance graph + adapters.** **Red**: a
  2-component graph (one imports the other's interface) links + runs.

### Phase D — WASI Preview 2 (Tier 1 → 2)

- [ ] **D1 — P2 worlds + P2→P1 adapter (CLI subset).** `wasi_p2_adapter.zig`:
  name-map `wasi:cli/*`, `wasi:clocks/*`, … onto the existing preview1 impl
  (reuse wholesale, per survey). **Red**: a P2 `wasi:cli` component prints via
  the adapter. **Exit**: a P2 hello-world component runs through the zwasm CLI.
- [ ] **D2 — resource-modeled P2 interfaces** (stdio/clocks/random/filesystem
  as resources, not just name-map). **Red**: resource-typed P2 fs handle ops.
- [ ] **D3 — broader native P2 host** (full fs/poll; sockets last, where the
  corpus demands past the adapter shortcut). Spike sockets first.

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
