# Component Model — design-fit survey (A5 de-risk, 2026-06-05)

> **Doc-state**: ACTIVE
> Findings of the ADR-0161 §3 "馴染みサーベイ" — does Component Model force a
> large design pivot in zwasm v2, or bolt on cleanly? Survey only; no impl.
> Sources: v1 `~/Documents/MyProducts/zwasm/src/{component,wit,wit_parser,canon_abi}.zig`,
> wasmtime `crates/{wasmtime/src/runtime/component,environ/src/component}`,
> wasm-tools `crates/{wit-parser,wit-component}`, v2 ROADMAP §4.1 + `src/feature/component/`.

## Verdict: LOW–MEDIUM pivot risk

CM sits as a **NEW LAYER ABOVE the existing module runtime** — it does NOT
restructure Zone 0–3, ZIR/ZirOp, the module→instance model, or the runtime
`Value` model. v2 is **already shaped for it**: ROADMAP §4.1 reserves
`src/feature/component/` (today a 10-line README stub, build-rejected until
post-v0.2.0), CM is the listed v0.2.0 entry, ZIR slots are reserved. A component
= "a graph of core-module instances + adapters + a component-level type system"
that **consumes** `runtime/instance/instantiate.zig` + `Instance`, not alters them.

The MEDIUM half is **surface area, not structure**: the canonical ABI + WIT type
system + resource tables are a large, mostly-new subsystem (v1 ≈ 5,600 LOC;
wasmtime ≈ 28k runtime + 10k environ). The core stays put; the new zone is big.

## The 4 hardest pieces (for zwasm specifically)

1. **Canonical ABI lift/lower over linear memory** — strings (utf8/utf16/latin1),
   lists, records, variants/option/result, flags, with exact size/align/discriminant
   layout. v1 `canon_abi.zig` (1,165 LOC) is almost entirely this. Needs heavy
   boundary fixtures.
2. **Resource types + handle tables** (`own`/`borrow`, `resource.new/drop/rep`) — a
   genuinely NEW runtime primitive (cf. wasmtime `resource_table.rs`, parent/child
   ownership + tombstones). The live table is the hard part.
3. **WIT type system + parser** — v1 `wit.zig` (2,098) + `wit_parser.zig` (446):
   lexer + parser + resolver. Biggest single chunk, but a closed self-contained
   sub-language (clean module, Zone-1-ish).
4. **`cabi_realloc` contract** — the ONE real coupling into the core: lowering must
   call back into the guest to allocate (v1 `types.zig:739 WasmFn.cabiRealloc` →
   `module.invoke`). v2 = a `Runtime.invoke`-style callback in a `CanonContext`.
   Plus the component-binary decoder (`component.zig` 1,898 — a 2nd binary format).

## v1 as the existence proof (clean separate layer)

- 4 standalone files, ~5,600 LOC, **zero core-VM changes**. Drives the core as a
  black box: `ComponentInstance.instantiate()` extracts embedded core-module bytes
  → `WasmModule.loadWithOptions` + `instantiateWithImports` → `module.invoke` for
  lift/lower trampolines + `cabi_realloc`.
- P2 adapter = a thin **name-map** (`component.zig:799 WasiAdapter`, `p2_to_p1_map`):
  `wasi:cli/stdout`, `wasi:clocks/wall-clock`, … → the existing preview1 functions.
  Reuses the P1 WASI impl wholesale.

## Recommended zwasm-v2 shape

- **Where**: `src/feature/component/` (reserved slot), Zone 2, gated `-Denable=component`
  + `-Dwasi=preview2`. Sub-modules: `decode.zig` (component binary), `wit/`
  (lexer/parser/resolver), `canon.zig` (lift/lower), `resource_table.zig` (new),
  `wasi_p2_adapter.zig`.
- **Reuses (no core change)**: `runtime/instance/instantiate.zig` + `Instance` per
  embedded module, `runtime/instance/memory*` as lift/lower target, `Runtime.invoke`
  for `cabi_realloc` + trampolines, the **entire existing preview1 WASI** behind the
  P2→P1 name-map.
- **Genuinely new**: WIT parser, canonical ABI, resource/handle table, component
  decoder, a component-level value type kept **distinct from `runtime.Value`**
  (single-slot-dual-meaning rule). ZIR slots only if lift/lower become ZirOps
  (optional — v1 used host-side Zig, no new opcodes).

## WASI 0.2 relationship

CM is a hard prerequisite (ROADMAP §A1). Once CM exists, **WASI P2 is largely "just"
WIT worlds over CM** — but not purely: it needs the resource-table machinery (P2
models stdio/clocks/fs as resources) + either real P2 hosts OR v1's pragmatic P2→P1
adapter shortcut (proven viable for the CLI subset; a complete P2 with sockets +
full fs + poll is more than a name-map). **WASI 0.3 (async/streams)** is gated behind
stack-switching, separate — out of scope here.

## Implication for the program

CM is a **post-v0.1.0 "new layer"**, not a core rewrite — schedule it AFTER
preview1-full + all-engine WASI, sized ≈ v1's 5,600 LOC across a new
`src/feature/component/` zone. No architecture pivot required; the existing
instance/memory/WASI machinery is the foundation it stands on.
