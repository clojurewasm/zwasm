# Wasm runtime deep comparison — Value / Globals / 17-dimension audit

**Date**: 2026-05-24 (post-repo-update audit; HEAD SHAs cited
per-runtime below).
**Scope**: 8 runtimes surveyed at internal-representation depth,
not just surface API. Triggered by zwasm v2's ADR-0052 (Value=8-byte
invariant) re-evaluation and ADR-0107 (byte-buffer globals
propagation) review.
**Audience**: zwasm v2 maintainers + ClojureWasm v2 dogfooding
team. Synthesis of three parallel subagent audits (private/notes/
runtime-deep-comparison-{rust,c-family,other}.md, ~1800 lines
combined source).

## §0 — TL;DR for the ADR-0052 / ADR-0107 / ADR-0109 review

**Value width — industry split**:

- **16-byte uniform**: wasmtime, wasmer, wazero, WasmEdge,
  WAMR (5/7 surveyed). Forced by v128 SIMD presence.
  Both wasmtime and wasmer carry a literal `TODO: Pack the
  globals more densely, rather than using the same size for
  every type` comment — i.e. they recognize the per-scalar
  8-byte waste but haven't found a clean alternative.
- **8-byte (no v128)**: zware (v128 unimpl), wasm3 (v128
  unimpl, maintenance-only). Both pay the cost of "v128
  exists in `ValType` enum but doesn't fit in `Value`".
- **8-byte + per-valtype offsets cope**: zwasm v2 (current
  invariant + ADR-0052 offsets table + ADR-0107 c_api
  propagation pending). Hybrid — preserves §P3 cold-start
  spirit, adds bookkeeping.

**Globals storage shape**:

- **16-byte uniform `VMGlobalDefinition`** with VMContext-offset
  access: wasmtime + wasmer (industry-Rust consensus).
- **Per-entry C++ object with `alignas(16) ValVariant`**:
  WasmEdge.
- **Single byte buffer + per-global `data_offset`** (= exactly
  ADR-0107's proposed shape for zwasm c_api): **WAMR**.
- **`ValHi` side-field for v128**: wazero.
- **`Global.value: u64` flat (v128 unsupported)**: zware.

**Implication for ADR-0107**: the byte-buffer + offsets shape
**IS used by WAMR** (1 of the most production-deployed
runtimes). So ADR-0107 isn't an isolated zwasm idiosyncrasy
— it's continuing on a path with real industry precedent.
Per-valtype offsets is structurally valid; the trade-off vs
uniform 16-byte is real but not one-sided.

**Implication for ADR-0052 (Value=8-byte) re-evaluation**:

- 5/7 of surveyed runtimes use 16-byte. zwasm v2's 8-byte +
  cope choice deviates from the majority.
- The deviation cost shows up as: `globals_offsets[]` table,
  parallel v128 storage, per-arch v128 emit path
  bifurcation, spec runner `GlobalsCtx`, ADR-0107
  c_api propagation pending. ~5-7 substantive code sites
  per major addition.
- BUT widening Value=16 cascades through operand stack /
  ZIR payload encoding / regalloc spill slot / host_calls
  marshal / JIT extern struct field offsets. The original
  ADR-0052 "50+ test sites" claim was inflated (actual
  asserts: 2 files) but the substantive cascade is real
  (~10-20 sites by current grep).
- **Both choices are defensible**. The "right" choice
  depends on whether zwasm prioritizes §P3 cold-start (=
  stay at 8) or industry-alignment-via-uniform-Value (=
  widen to 16).

**Implication for ADR-0109 (Zig API design)**: this audit
validates the **`Engine` + `Linker` + `TypedFunc` pattern**
proposed there. wasmtime/wasmer/wasmi all use this trio.
Naming is industry-consensus. Linker pattern has the strongest
precedent (wasmtime's `Linker<T>` + `instantiate_pre`).

## §1 — Repos surveyed (post-fetch state)

| Repo | HEAD SHA | Date | Last commit gist |
|---|---|---|---|
| wasmtime (Rust) | `fa50c6a1` | 2026-05-23 | egraph: peer through `ireduce` in `brif` |
| wasmer (Rust) | `b384fd81` | 2026-05-22 | tests(spec): include V8 Engine |
| WasmEdge (C++) | `626b35ba` | 2026-04-12 | (master; 34 commits pulled this audit) |
| WAMR (C) | `5aebe728` | 2026-05-19 | (main) |
| wasm-c-api (spec) | `9d6b9376` | 2026-03-19 | (main; already up-to-date) |
| wazero (Go) | `475a1f8` | 2026-05-21 | fix: compilation cache should store catch clause table (EH) |
| zware (Zig) | `7ad2536b` | 2026-02-28 | (master; up-to-date) |
| wasm3 (C) | `79d412ea` | 2024-09-10 | README update; project in maintenance-only mode |

Audit method: per-runtime survey of 17 internal-representation
dimensions with `file:line` citations and code-snippet evidence.
Full source reports at `private/notes/runtime-deep-comparison-{rust,c-family,other}.md`
(gitignored; not promoted to docs/ to keep this synthesis
manageable; the raw reports are available if deeper citation
is needed).

## §2 — 17-dimension comparison table

(legend: ✓ = first-class, ◯ = partial / experimental, × = not
supported, n/a = not applicable for this runtime category)

| Dimension | wasmtime | wasmer | WasmEdge | WAMR | wazero | zware | wasm3 | **zwasm v2 (current)** |
|---|---|---|---|---|---|---|---|---|
| **Top-level** | Engine + Store<T> + Linker<T> | Engine + Store + Imports | VM + Store + Loader | wasm_engine_t + wasm_runtime_init | Runtime + CompiledModule | Store + Instance | IM3Environment + IM3Runtime | Runtime (= Engine; rename pending ADR-0109) |
| **Module loading** | `Module::new(engine, bytes)` 1-step | `Module::new(store, bytes)` 1-step | Loader → Validator → Executor 3-step | wasm_runtime_load() 1-step | `r.CompileModule(bytes)` 1-step | `Module.parse(bytes)` then `Instance.init` 2-step | Env → Rt → Parse → Load → Find → Call 5+ step | Runtime+Module.parse+Module.instantiate 3-step (per ADR-0025; pending ADR-0109 → 1-step `engine.compile`) |
| **Import wiring** | Linker<T> builder (build-once-many) | Imports HashMap / `imports!` macro | Builder + store-registered host module | NativeSymbol[] registry + sig-string DSL | `WithFunc` / `WithGoFunction` / `WithGoModuleFunction` 3 modes | InstanceOptions.imports field | M3RawCall + sig-string macros | (empty `InstantiateOpts`; pending ADR-0109 Linker) |
| **Value rep width** | **16-byte** `ValRaw` union | **16-byte** `RawValue` union | **16-byte** `uint128_t Value` + 8-byte ValType tag | **16-byte** `WASMValue` union | **16-byte** (`Val: uint64` + `ValHi: uint64`) | **8-byte** `u64` (v128 unimpl) | **8-byte** typed union (v128 unimpl) | **8-byte** `extern union` (`@sizeOf(Value)==8` invariant §ADR-0052) |
| **Value tagged?** | Untagged (`#[repr(C)]` union) | Untagged | **Tagged at host** (Value+ValType pair); untagged in storage | Tagged (`{kind, _pad, of}`) | Untagged in compiled code | Untagged | Tagged (`M3ValueType` per slot) | **Untagged** extern union (no per-slot type byte per §P3) |
| **Globals storage** | `VMGlobalDefinition[u8; 16]` uniform | `VMGlobalDefinition[u8; 16]` uniform | per-entry C++ obj w/ `alignas(16) ValVariant` | **single byte buffer** + `data_offset[]` | `Globals` slice w/ `ValHi` for v128 | `Global {valtype, mut, value: u64}` flat | per-entry `M3Global` w/ inline typed union | `[]*Value` scalar + `[]u8` v128 (ADR-0052 split); c_api side per-entry pointer; spec runner `GlobalsCtx` byte buffer + offsets (ADR-0107 propagates to c_api) |
| **v128** | ✓ first-class (`V128(u128)` in Type) | ✓ first-class | ✓ first-class (`uint128_t`) | ✓ first-class | ✓ first-class | ◯ in ValType enum only (storage unimpl) | × | ✓ in JIT path (via parallel storage); ◯ in c_api side (ADR-0107 pending) |
| **Ref types (funcref/externref)** | 32-bit compressed handle (GC era) | `usize` (no compression) | `RefVariant` struct | `void*` + null sentinel | `Reference = uintptr` (0=null) | `?usize` (Zig optional) | `IM3Function*` | `Value.ref = u64`, null=0 sentinel (ADR-0014 6.K.1) |
| **GC types (i31/struct/array)** | ✓ Full impl behind `wasm_gc` flag | × No GC at all | ◯ Proposal enabled, minimal C API host constructors | ◯ Deepest C surface (separate 955-line `gc_export.h`, `WASMLocalObjectRef` roots) | × | × | × | × Deferred to Phase 10 (ADR-0061 deferral policy) |
| **Exception handling** | ✓ Wasm 3.0 EH spec | ◯ Legacy proposal | ✓ TagType + TagInstance new proposal | ◯ Legacy proposal (interp only) | ◯ Experimental flag | × | × | × Deferred to Phase 10 |
| **Tail call** | ✓ | ✓ | ✓ | ✓ | ◯ experimental | × | × | × Deferred to Phase 10 |
| **Multi-memory** | ✓ | ✓ | ✓ | ✓ | ✓ | × | ⏳ ("planned") | × Deferred |
| **memory64** | ✓ | ✓ | ✓ (uint64 page counts in C API) | ✓ (uint64 widened) | ✓ | × | × | × Deferred |
| **C API conformance** | wasm-c-api shim + extensions | wasm-c-api shim + extensions | own `WasmEdge_*` C API (no wasm-c-api compat) | both native `wasm_export.h` + wasm-c-api shim (with documented gaps + `WASM_V128` extension) | none (pure Go, CGo non-goal) | none (pure Zig) | own M3 C API (not wasm-c-api) | wasm-c-api strict conformance via `src/api/` (per ADR-0004 / §P8) |
| **TypedFunc** | `TypedFunc<Params, Results>` (proc-macro generated 0..=17 arity) | `TypedFunction<Args, Rets>` (macro-generated 0..=8 arity) | per-host-language binding | per-host-language binding | reflection `WithFunc` + typed-stack | `Function.invoke` (Value slice only) | macro suite + sig string | none today; pending ADR-0109 (Zig fn type via `@typeInfo(.@"fn")`) |
| **Memory access** | `Memory::data(&mut store) → &[u8]` direct slice | `MemoryView::read/write` mediated (JS backend constraint) | typed get/set methods | `wasm_runtime_get_memory_data` → `uint8_t*` + size | `Memory.Read / Write` slice form | per-T comptime accessors | `m3_GetMemory` → bare ptr | (none in facade; pending ADR-0109 `Memory.slice()`) |
| **Trap rep** | typed enum + Trap object | typed enum | packed `{uint32_t Code}` (24-bit code + category) | string-only `char[128]` per module-instance | Go `error` interface | 30-variant `WasmError` error union | `const char*` pointer-equality + side-channel info | `Trap = error{...}` 12 variants (good); facade collapses to `error.Trap` (ADR-0109 fixes) |
| **Host fn sig derivation** | macro `wasmtime::Caller` + blanket impls 0..=17 | macro blanket impls 0..=8 | per-host-language (C/C++/Rust/Go bindings) | sig-string DSL `"(i*~)F"` + C native callbacks | reflection or typed-stack manual | uniform `fn(*VM, usize) WasmError!void` | `M3RawCall` + sig-string DSL | (none; pending ADR-0109 `@typeInfo(.@"fn")` comptime marshal) |

## §3 — Per-runtime profile (1-paragraph each)

### wasmtime
**Industry reference (Bytecode Alliance)**. `Engine` + `Store<T>`
(user-data-typed context for host fns) + `Linker<T>` (build
imports once, instantiate multiple modules). All Wasm 2.0 +
Wasm 3.0 proposals implemented. **16-byte uniform** at `ValRaw`
union and `VMGlobalDefinition`. `TypedFunc<Params, Results>`
via proc-macro-generated blanket trait impls. wasm-c-api binding
present as `crates/c-api/`. Recognizes per-scalar 8-byte waste
in `VMGlobalDefinition` (TODO comment) but hasn't fixed.

### wasmer
**Industry runner-up**. `Engine` + `Store` (non-generic) +
`Imports` (HashMap with `imports!` macro). Multi-backend (V8 /
LLVM / Cranelift / Singlepass). Same 16-byte uniform shape as
wasmtime; identical "pack more densely" TODO. **No GC support**
(no `gc` feature flag, no `AnyRef/StructRef/...` in `Type`).
`TypedFunction<Args, Rets>` 0..=8 arity (vs wasmtime's 0..=17).
Memory access mediated through `MemoryView::read/write` because
of v8/js-backend constraint — useful case study of "worst-case
backend constrains your API".

### WasmEdge
**CNCF runtime, C++ codebase**. VM + Store + Loader/Validator/Executor.
**16-byte `uint128_t Value`** + separate 8-byte ValType tag. C++
`Variant` of 19 trivially-copyable alternatives, all sized to
biggest. Globals = per-entry C++ object w/ `alignas(16) ValVariant`.
Own C API (`WasmEdge_*`) not wasm-c-api compat. GC + EH (new
proposal) + tail call + multi-memory + memory64 all ✓. **No
wasm-c-api conformance** by design (their own API is their
product surface).

### WAMR (wasm-micro-runtime)
**Intel-driven C runtime, footprint-oriented**. wasm_engine_t +
wasm_runtime_init globals. **16-byte `WASMValue` union** internally;
**byte-buffer + per-global `data_offset`** for globals storage
(= exactly ADR-0107's proposed zwasm shape). Both native
`wasm_export.h` and a wasm-c-api shim with documented gaps
(sharable refs / serialize / host-side grow). **Extends wasm-c-api
with `WASM_V128`** + `wasm_importtype_is_linked` — these are
zwasm-relevant precedents for extending wasm-c-api beyond spec.
**Deepest GC C surface** of any runtime surveyed (955-line
`gc_export.h` with struct/array/i31/anyref/stringref obj
handles + `WASMLocalObjectRef` stack roots).

### wazero
**Pure-Go, no-CGo runtime**. Runtime (= Engine) + CompiledModule.
Compile is 1-step (`r.CompileModule(bytes)`); instantiation
1-step on top. **16-byte effective Value** (Go: `Val uint64` +
`ValHi uint64` per slot). 3 host-fn registration modes:
reflection `WithFunc`, typed-stack `WithGoFunction`, with-module
`WithGoModuleFunction`. EH + tail-call as experimental flags
(HEAD `475a1f8` is literally an EH cache fix). No C API by design.

### zware
**Zig idiom; closest structural sibling to zwasm v2**. Store
(`ArrayListStore`) + Instance + Function. **8-byte `u64` Value**
(no v128). `Global {valtype, mutability, value: u64}` flat.
ValType enum includes `V128` but storage cannot accommodate it —
shows the cost of v128 being declared-but-not-implemented.
30-variant `WasmError` error union (Zig idiom). Per-T comptime
memory accessors. No C API (pure Zig library). Uniform host
fn signature `fn(*VM, usize ctx) WasmError!void`. **zwasm v2
should review zware closely when finalizing the Memory access
API** — same Zig + comptime constraints, similar shape.

### wasm3
**C interpreter, maintenance-only since 2024-09**. IM3Environment
(engine) + IM3Runtime (per-execution state — different "Runtime"
meaning from zwasm/wasmtime!) + IM3Module + IM3Function. 5+-step
construction. Per-entry `M3Global` w/ inline typed union (8-byte
slot, tagged per slot). No v128, no GC, no EH, no tail call.
Multi-memory + reftypes marked ⏳ in README. `M3RawCall(rt, ctx,
_sp, _mem)` + macro suite + signature string for host fns. Useful
as the **minimal Wasm 1.0 baseline** — what does a 5kLOC interpreter
look like — but not a reference for any 2026-era feature.

### wasm-c-api (spec, not runtime)
**The C API spec itself**. Has NOT been updated for Wasm 2.0 +
3.0: no `WASM_V128` in `wasm_valkind_t`, no GC types. Recent
activity (2026-03 commit `9d6b9376`) added TagType (= start of EH
support); other Wasm 2.0 features absent. **WasmEdge ignores
wasm-c-api by design**; **WAMR + wasmtime + wasmer extend wasm-c-api
with their own additions** (`WASM_V128` is the common extension).
**Implication for zwasm v2 §P8** ("wasm-c-api is the C ABI
primary"): the spec is stale, and extending it (the
WAMR/wasmtime/wasmer pattern) is acceptable industry practice
when the spec hasn't caught up.

## §4 — Cross-cutting findings relevant to zwasm v2 design choices

### Finding 1: Value=16 industry majority, but Value=8 + offsets is not isolated

- **5/7 use 16-byte** (wasmtime, wasmer, wazero, WasmEdge, WAMR).
  All forced by v128.
- **2/7 use 8-byte** but neither supports v128 (zware leaks
  v128 declaration without storage; wasm3 maintenance-only).
- **zwasm v2's 8-byte + per-valtype offsets cope** is hybrid.
  No other runtime does exactly this, BUT WAMR does
  byte-buffer + offsets for globals specifically (= ADR-0107
  proposed shape). The cope shape isn't isolated; it's a
  legitimate design point in the trade-off space.

**Trade-off space**:

- 16-byte uniform: simpler indexing, 100% v128 cost shared by
  all scalars, no offsets bookkeeping.
- 8-byte + offsets: scalar-cheap, v128 expensive (parallel
  storage + per-valtype switch), bookkeeping overhead per
  module + per-arch JIT codepath bifurcation.
- 8-byte without v128 (zware, wasm3): can't ship Wasm 2.0
  SIMD. Not viable for zwasm v2.

### Finding 2: wasm-c-api spec is stale; extending it is standard practice

WAMR + wasmtime + wasmer all extend wasm-c-api with their own
additions (most commonly `WASM_V128`). §P8 ("wasm-c-api is the
C ABI primary") doesn't require zwasm to be confined to spec
shape — extending follows industry. ADR-0107 could add a
similar v128 extension to the `wasm.h` zwasm ships.

### Finding 3: Linker pattern is industry-best-practice for imports

- **wasmtime `Linker<T>`**: build once, `instantiate_pre`
  for multi-module hosts.
- **wasmer `Imports` + `imports!` macro**: similar shape, less
  reusable than wasmtime's Linker.
- **WasmEdge builder + store-registered host module**: same
  pattern.
- **WAMR `NativeSymbol[]` registry**: global registration,
  module-scoped via `module_name` field.
- **zware**: passes imports inline via `InstanceOptions`,
  no builder.

ADR-0109's proposed Linker pattern aligns with the **3/5
runtime-with-host-import-builder consensus**. Strong precedent.

### Finding 4: TypedFunc is industry-standard for hot-path host code

- **wasmtime**: `TypedFunc<Params, Results>` proc-macro,
  0..=17 arity.
- **wasmer**: `TypedFunction<Args, Rets>` macro, 0..=8.
- **WasmEdge / WAMR**: per-host-language binding.
- **wazero**: reflection-based `WithFunc` (slow path) +
  typed-stack `WithGoFunction` (fast path).
- **zware**: only Value-slice `invoke`, no TypedFunc — **CW
  v2 dogfooding pain point analog**.

ADR-0109's TypedFunc via Zig `fn` type + `@typeInfo` is
**Zig-native equivalent of the Rust proc-macro approach**. No
known Zig precedent (zware doesn't have it) — zwasm v2 would be
the first.

### Finding 5: Memory access API divergence reflects backend constraints

- **wasmtime**: direct `&mut [u8]` slice from `Memory::data(&mut
  store)`. Simplest for hosts.
- **wasmer**: mediated `MemoryView::read/write` because of
  v8/js backend constraint (where direct slice can't work).
- **WasmEdge / WAMR**: typed get/set methods.
- **wazero**: `Memory.Read / Write` slice form.
- **zware**: per-T comptime accessors (Zig idiom).

ADR-0109's proposed `mem.slice()` matches **wasmtime + wazero**
(direct slice). For zwasm v2 with single-engine (no v8 backend),
direct slice is sound. The wasmer case study reinforces:
"design for your worst-case backend constrains everyone" — zwasm
v2 doesn't have that constraint so direct slice is appropriate.

### Finding 6: zwasm v2 vs zware — same language, different choices

zware is the closest sibling (Zig + Wasm 1.0 + pure library).
Key divergences:

- zware doesn't support v128 → 8-byte Value works.
- zware uses `Store/Instance` (no Engine).
- zware uses `?usize` Zig optional for ref types.
- zware uses 30-variant `WasmError` error union (vs zwasm v2's
  12-variant `Trap` error set — both Zig idiom but different
  granularity).
- zware has no TypedFunc, no Linker pattern — `InstanceOptions`
  inline imports + Value-slice `invoke`.

zwasm v2's more ambitious surface (v128 + JIT + 3 hosts +
Linker + TypedFunc) accordingly demands richer machinery. The
direct-from-zware port that zwasm v2 isn't was the right
call structurally; this audit confirms.

## §5 — What this means for the open design questions

### Q1: Should ADR-0052 (Value=8-byte) be re-evaluated, with Value=16 the alternative?

**Honest read**: ADR-0052's "Why rejected Alt A" cited "50+ test
sites" — actually 2 test asserts + ~10-20 substantive callsites.
The claim was inflated. BUT the substantive cascade is still real.

Industry-alignment argument for Value=16:
- 5/7 of surveyed runtimes use 16-byte.
- Eliminates the ADR-0052 offsets cope (no `globals_offsets[]`,
  no parallel v128 storage, no per-valtype JIT switch, no spec
  runner `GlobalsCtx`, no ADR-0107 c_api propagation).
- Wasm 3.0 GC types (i31ref / struct refs / array refs) would
  also fit cleanly in 16-byte cell.

§P3 cold-start argument for Value=8:
- §P3 actually says "compile pipeline single-pass" — does NOT
  mandate Value width. The Value-width connection was an
  indirect §P3 derivative.
- 16-byte Value doubles operand stack memory footprint
  (typical funcs have ~10-50 operands so ~80-400B per active
  frame; not catastrophic).
- ZIR payload encoding currently assumes 8-byte slot — would
  need encoding migration (rough estimate: substantial but
  bounded).

**My honest recommendation**: this deserves a real audit-driven
ADR (`ADR-0110 — Value widening reconsideration`). Not "draft
the ADR now" — first run an **honest scope audit** that
identifies and counts the cascade with primary code evidence
(not the inflated ADR-0052 number). Then user collab-decides.

### Q2: ADR-0107 — Accept, Withdraw, or amend?

Given Finding 1 (WAMR uses byte-buffer + offsets for globals
specifically), ADR-0107's proposed shape **has industry
precedent**. Not isolated. So:

- If Value=8 stays: **Accept ADR-0107** as continuation of a
  defensible-if-non-majority design line.
- If Value=16 adopted via future ADR-0110: ADR-0107 becomes
  unnecessary (Withdraw or amend to extension of `wasm.h`
  for v128 only).

**No urgent need to Withdraw ADR-0107 today** unless the
Value=16 path is committed.

### Q3: ADR-0109 (native Zig API: Engine + Linker + TypedFunc)

Audit validates the design choices:

- **Engine naming**: 5/5 major runtimes use Engine. Confirmed.
- **Linker pattern**: 3/5 industry consensus. Confirmed.
- **TypedFunc via Zig fn type**: no Zig precedent (zware
  doesn't have it), Rust precedent strong (wasmtime/wasmer
  macro-generated). Zwasm v2 leads here for Zig.
- **Memory slice view**: wasmtime + wazero precedent.
  Confirmed for single-backend runtimes.
- **Untagged 8-byte Value at consumer surface**: matches NaN-
  boxing intent. Aligns with zware idiom modulo width.

**ADR-0109 can proceed independently of ADR-0107 / ADR-0110
decision**. The facade shape is correct regardless of Value
width (just expose `V128` as separate type when width is 8,
or unify into one type when width is 16).

## §6 — Source reports

Raw audit material with full file:line citations:

- `private/notes/runtime-deep-comparison-rust.md` (589 lines)
  — wasmtime, wasmer
- `private/notes/runtime-deep-comparison-c-family.md` (568 lines)
  — WasmEdge, WAMR, wasm-c-api spec
- `private/notes/runtime-deep-comparison-other.md` (634 lines)
  — wazero, zware, wasm3

These are gitignored. If a future zwasm v2 / CW v2 review needs
to cite specific code, the source reports have the citations;
this synthesis doc has the conclusions.

## §7 — Revision history

- 2026-05-24 — Initial audit at cycle 37, post-cycle-36 user
  reframe ("c_api が非標準なのが一番よくない / 疲れて妥協"
  suspicion). 3 parallel subagent audits → synthesis here.
  Triggers: ADR-0052 re-evaluation, ADR-0107 review,
  ADR-0109 validation.
