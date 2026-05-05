# 0025 — Zig library surface (host-API for `@import("zwasm")` consumers)

- **Status**: Accepted
- **Date**: 2026-05-05
- **Author**: Shota / Zig host-API gap surfaced post-ADR-0024
- **Tags**: roadmap, api, library, surface, phase8, breaking-changes-allowed

## Context

ROADMAP §10 documents the CLI surface (`zwasm run / compile /
validate / inspect / features / wat / wasm`) and §4.4
documents the C ABI surface (`include/{wasm,wasi,zwasm}.h`).
**The Zig library surface — what a Zig host writes when it
imports the project as a Zig package — was never explicitly
designed.** ADR-0024 incidentally produced a working hierarchical
re-export tree (`src/zwasm.zig` exposing `parse / validate / ir /
runtime / instruction / feature / engine / wasi / api / cli /
diagnostic / support / platform`), but that surface is the
**internal module-graph shape**, not a curated public API.

This ADR designs the public Zig host surface explicitly. Per
the user's framing: **breaking changes from v1 are allowed**;
ClojureWasm v1 (the only Zig consumer) will be migrated to the
new surface. v0.1.0 is pre-release and the surface is free to
re-design — the goal is "嬉しい / シンプル", not bug-for-bug
compatibility with v1.

### Survey findings (informs the Decision)

Investigated 2026-05-05 against on-disk reference codebases +
authoritative web sources:

**Wasm-runtime host APIs compared** (smallest "load wasm bytes →
call exported `fib(10)` → get `i32`" snippet):

| Runtime | Lines | Core type | Verdict |
|---|---|---|---|
| **wazero (Go)** | ~3 | Fused `Runtime` (Engine+Store hidden) | **Gold standard** — minimal ceremony, fluent |
| **zwasm v1 (Zig)** | ~4 | Fused `WasmModule` (load → invoke) | Excellent for v1; untyped `[]u64` is the gap |
| **Wasmtime (Rust)** | ~8 | Engine + Store + Module + Instance + Linker | Safe-first, type-safe `TypedFunc<P,R>`, but verbose |
| **Wasmer (Rust)** | ~10 | Engine+Store+Module+Instance + `imports!` macro | Macro is nice; `Store::default()` is a smell |
| **WasmEdge (C++)** | ~12 | All-in-one VM (`VMRunWasmFromBytes`) | Single-shot fast-path; inflexible for repeat calls |
| **WAMR (C)** | ~16 | Module → Inst → ExecEnv (8 mandatory steps) | Anti-pattern (embedded-focused, embedder-hostile) |

**Zig-idiomatic public-surface conventions** (web survey of
ziglang.org / ziggit.dev / std + zware / bun / ghostty source):

- **Top-level flat re-exports** (`zwasm.Runtime`, not
  `zwasm.runtime.Runtime`) is the bun-and-zware pattern.
  Mirrors std (`std.ArrayList`, `std.heap.ArenaAllocator`).
- **Allocator-first, options-last** with `.{}` empty-default
  initialiser is the std convention.
- **Stack-return `init` / by-value `deinit`** (no heap-boxed
  `*Self`) — std's ArenaAllocator shape.
- **0.15+ Unmanaged-by-default** for collections that allocate
  during ops (allocator passed per-call, not stored as field).
- **Method calls with clear receivers** (`module.instantiate(...)`)
  for owned operations; "method on the type" (`Module.parse(alloc,
  bytes)`) for constructors.
- **Error union all the way** (`Trap!void`) — out-params and
  union returns are anti-patterns in pure-Zig APIs.
- **Internal-vs-public**: module-level discipline (don't
  re-export at `src/zwasm.zig`) — Zig has no field privacy
  by design (issue #9909).
- **Anytype tuple + slice-of-Value 2-layer**: typed comptime
  call (`f.call(.{ 1, 2 })`) on top, untyped `invoke(name,
  args[], results[])` as the load-bearing fallback.

### Why zwasm v1 isn't the answer

zwasm v1's `WasmModule.load(alloc, bytes)` + `module.invoke(name,
&u64_args, &u64_results)` is the closest to what we want, but:
- Untyped `u64`-slot args/results lose Zig's compile-time type
  benefits.
- The fused `WasmModule` conflates the **module** (parsed bytes,
  shareable across instances) with the **instance** (linked
  + memory + globals). v2 needs them separate to support
  cross-module imports cleanly (ADR-0014's Wasm 2.0 work).
- `loadLinked()` for cross-module is bolted-on rather than
  primary; v2's Wasm 2.0 import semantics deserve first-class
  treatment.

## Decision

### D-1 — Three top-level types: `Runtime`, `Module`, `Instance`

Mirror **wazero's fused Engine+Store** in a `Runtime` handle, but
keep `Module` (parsed/validated bytes) and `Instance`
(instantiated state) as separate types so cross-module imports
and module re-instantiation stay first-class. Three top-level
types (per ADR-0024's `src/zwasm.zig` library root):

```zig
pub const Runtime = ...; // Engine + Store + allocator-of-record (fused per wazero)
pub const Module = ...;  // Parsed + validated bytes (immutable, shareable)
pub const Instance = ...;// Instantiated runtime state (mutable, callable)
```

`Trap`, `Value`, `WasiConfig`, `ImportEntry`, `TypedFunc`,
`ParseError`, `InstantiateError` round out the public symbols
at the root.

**Zone placement** (review-fix per self-review Issue 2): the
public `zwasm.Runtime` / `zwasm.Module` / `zwasm.Instance` are
**thin facade structs defined in `src/zwasm.zig` itself** —
they wrap the existing internal Zone-1 types (`runtime/runtime
.zig:Runtime`, `runtime/module.zig:Module`,
`runtime/instance/instance.zig:Instance`). `src/zwasm.zig` is
the library-surface file (per ADR-0024 D-2) classified as `lib`
in zone_check.sh — it may pull every zone, so the facade can
freely reference the internal Zone-1 types without violating
the zone-dependency rule. The facade pattern keeps the public
API stable (D-7) while letting the internal types evolve.

### D-2 — Three-line happy path

The "嬉しい" target — bytes to call in 3 host-side statements:

```zig
const zwasm = @import("zwasm");

// 1. Runtime: per-host singleton (allocator-of-record, dispatch
//    table, default WASI = none).
var rt = try zwasm.Runtime.init(alloc, .{});
defer rt.deinit();

// 2. Module: parse + validate + lower in one call. Reusable
//    across multiple Instance constructions (cross-module
//    sharing is the same shape).
var module = try zwasm.Module.parse(&rt, wasm_bytes);
defer module.deinit();

// 3. Instance: instantiate + auto-call entry, OR explicit call.
var instance = try module.instantiate(.{});
defer instance.deinit();

// 4. Call (untyped, runtime-typed via Value slice — load-bearing).
var args = [_]zwasm.Value{ .{ .i32 = 10 } };
var results = [_]zwasm.Value{ .{ .i32 = 0 } };
try instance.invoke("fib", &args, &results);
const fib10 = results[0].i32;
```

### D-3 — Two-layer call API: `invoke` (untyped) + `TypedFunc` (comptime-typed)

`invoke(name, args, results)` is the load-bearing API — works
for any module whose signatures are only known at runtime
(spec runner, host fixtures, generic tools).

`TypedFunc(Params, Results)` is the ergonomic layer for hosts
that know the signature at compile time:

```zig
const fib = try instance.getTyped("fib", fn (i32) i32);
const r = try fib.call(.{ @as(i32, 10) });
```

Implemented via `std.meta.ArgsTuple` + comptime signature
reflection. **Constant overhead** (review-fix per self-review
Issue 3): the typed wrapper boxes/unboxes through `Value` once
per parameter / result at the call boundary, then delegates to
the same `instance.invoke(name, args, results)` path that the
untyped API uses. Internally the call still goes through the
dispatch table (`engine/runner.zig` → `engine/interp/loop.zig`
or the JIT entry frame), so "zero overhead" is **not** the
right framing — the typed wrapper trades a small compile-time-
known box/unbox cost for type safety. Args/results live in
stack-allocated `Value` arrays sized at comptime; no heap
allocation per call.

### D-4 — `WasiConfig` is an option on `Module.instantiate`

```zig
var instance = try module.instantiate(.{
    .wasi = .{
        .argv = &.{ "prog", "arg" },
        .stdout = .inherit,
        .stdin = .none,
        .preopens = &.{},
    },
    .imports = &my_imports,
});
```

`.wasi = null` (default) → no WASI host wired. Setting `.wasi`
to a non-null config wires the WASI thunks and host context
internally per ADR-0023 §7 item 5 (Step A2)'s `ImportBinding`
pattern. WASI is **not** a separate `attachWasi()` step — that
shape introduced ordering bugs in v1 per the v1-investigation
notes.

**Implementation prerequisite** (review-fix per self-review
Issue 8): the existing `wasi/host.zig:Host` struct exposes
`stdin_bytes: ?[]const u8` and `stdout_buffer:
?*std.ArrayList(u8)` as the only IO surfaces. The proposed
`.stdout = .inherit` / `.stdin = .none` tagged-union variants
do **not** yet exist; they are part of the B-3 work. The B-3
commit must:

1. Add a tagged union `WasiStdio = union(enum) { none, inherit,
   buffer: *std.ArrayList(u8), pipe: ... }` to `wasi/host.zig`
   (or a new sibling `wasi/config.zig`).
2. Wire `Host.init` to accept the union and configure the
   underlying `stdin_bytes` / `stdout_buffer` slots from it.
3. Then expose the public `WasiConfig` in `src/zwasm.zig` that
   marshals into the new internal type.

The B-3 row in the implementation table reflects this scope.

A convenience `.runWasi()` runs the `_start` / `main` entry and
returns the WASI exit code:

```zig
const exit_code = try instance.runWasi();
std.process.exit(exit_code);
```

### D-5 — `ImportEntry` struct + cross-module by `*Instance` reference

For host-supplied imports + cross-module imports, keep zwasm
v1's struct-list shape (composable, comptime-friendly):

```zig
const imports = [_]zwasm.ImportEntry{
    .{ .module_name = "env", .field_name = "log",
       .source = .{ .host_func = .{ .fn_ptr = logFn, .ctx = ctx } } },
    .{ .module_name = "math_helpers", .field_name = "@instance",
       .source = .{ .instance = &other_instance } },
};
var instance = try module.instantiate(.{ .imports = &imports });
```

**Why `*Instance`, not `*Module`** (review-fix per
self-review Issue 1): cross-module dispatch per ADR-0014
§6.K.3 wires through the source's **live** `Runtime` —
`host_calls[i]` thunk pops args from the importer's operand
stack and pushes onto the source instance's stack. A `Module`
is the immutable parsed/validated artifact and has no operand
stack, so it cannot serve as an import source on its own.
Hosts that want to instantiate the source first to supply
its exports do so explicitly: `try other_module.instantiate(
.{})` → use the resulting `Instance`.

The internal conversion path: the public `ImportEntry` slice
is converted to `runtime/instance/import.zig`'s
`ImportBinding` union (per ADR-0023 §7 item 5 Step A2)
inside `module.instantiate`. The conversion lives in
`src/zwasm.zig` (the facade layer) so the runtime side
keeps its Zone-1-native types unchanged.

The `.host_func` variant maps to `ImportBinding.host_func`;
the `.instance` variant fans out per-export to
`ImportBinding.cross_module` rows. Ownership: the binding
slice is allocated on the instance's per-instance arena
(per ADR-0014 §6.K.2) and lives until `instance.deinit()`.

### D-6 — Three error sets, scoped by failure phase

```zig
pub const ParseError = error{ ... };       // Module.parse: malformed / invalid bytes / decode failure
pub const InstantiateError = error{ ... }; // Module.instantiate: link failure, OOM, missing imports, type mismatch
pub const Trap = error{                    // Instance.invoke: runtime-only trap
    Unreachable, DivByZero, IntOverflow, InvalidConversionToInt,
    OutOfBoundsLoad, OutOfBoundsStore, OutOfBoundsTableAccess,
    UninitializedElement, IndirectCallTypeMismatch,
    StackOverflow, CallStackExhausted, OutOfMemory,
};
```

Three precise error sets so callers can `catch` with full
exhaustiveness checking. `Trap` mirrors the Wasm 2.0 trap
catalogue 1:1 — it is identical to `runtime.Trap` (the existing
internal type, simply re-exported as `zwasm.Trap`).

### D-7 — Stability boundary: 9 stable symbols at the top level

The **stable surface** comprises these top-level symbols
(review-fix per self-review Issue 6 — error sets added):

| Symbol | Stability promise |
|---|---|
| `Runtime` | shape stable; new fields may be added |
| `Module` | shape stable; new methods may be added |
| `Instance` | shape stable; new methods may be added |
| `Trap` | error set is **open** (new variants may be added in v0.2.0+); existing variants stable |
| `Value` | extern-union shape stable per ADR-0014 §6.K.5 |
| `WasiConfig` | shape stable; fields may be added with sensible defaults |
| `ImportEntry` | tagged-union variants stable; new `source.X` variants may be added |
| `TypedFunc(P, R)` | reflection-based; stable as long as Zig comptime semantics hold |
| `ParseError` / `InstantiateError` | error sets are **open** (new variants may be added); existing variants stable |

Everything else reachable through deep
`@import("zwasm").engine.codegen.arm64.emit` or
`@import("zwasm/engine/codegen/arm64/emit.zig")` paths is
**internal** — power users / the spec runner / tests can reach
it, but break-without-deprecation is allowed across releases.

`src/zwasm.zig` re-exports only the stable surface at the top
level via flat `pub const` (per ADR-0024 D-2 + the bun /
zware / std-lib idiom). Nested namespaces (`zwasm.parse`,
`zwasm.engine`, etc.) that ADR-0024 introduced for the
module-graph stay accessible but are **not** part of the
host-API stability promise — they exist for the build system
+ the test runners.

### D-8 — Allocator threading: stored on Runtime, back-referenced by Instance

(Review-fix per self-review Issue 4 — clarified rationale and
the Instance → Runtime back-reference.)

`Runtime` stores the host allocator. `Module` and `Instance`
each hold a back-reference to their owning `Runtime` (mirroring
ADR-0014 §6.K.2's existing `runtime.instance` opaque
back-pointer pattern):

- `Runtime.init(allocator, .{})` — allocator stored on Runtime;
  used for setup-time allocations (`Module.parse`,
  `module.instantiate`).
- `Module.parse(*Runtime, bytes)` — uses `runtime.gpa`
  internally; the parsed Module holds a `*Runtime` back-ref.
- `module.instantiate(...)` — allocates the per-instance arena
  via the Module's `*Runtime`; the resulting Instance holds the
  same back-ref.
- `instance.invoke(name, args, results)` — does **not**
  allocate during dispatch in the current interp implementation
  (per `runtime.Runtime`'s pre-allocated `operand_buf` /
  `frame_buf` `undefined`-initialised fixed-size arrays). The
  no-allocator-arg signature reflects the current reality, not
  a "too hot" optimisation.
- `module.deinit()` / `instance.deinit()` — no allocator arg;
  each resolves the allocator from its `*Runtime` back-ref to
  free its per-instance arena.

This shape is **not** strict Unmanaged-by-default — the std
0.15+ idiom has the caller pass the allocator at every
mutating call. The deliberate departure: Wasm hosts treat
`Instance` like a long-lived handle (parse once, call many
times). Threading the allocator through every `invoke` would
make the typed-call ergonomics worse without buying anything,
since the dispatch path doesn't allocate. If a future
extension (e.g. Phase 8 GC) does allocate per-call, the
`Runtime`'s allocator is the natural source.

## Alternatives considered

### Alternative A — Mirror wasm-c-api 1:1: `Engine + Store + Module + Instance`

Expose all four wasm-c-api handles as Zig types so the Zig and C
APIs map symbol-for-symbol.

**Why rejected**: wasm-c-api was designed for C, where heap-
boxing every handle is the only stable representation. In Zig
the four-handle model is overhead — wazero proved that hosts
don't need to know about Engine/Store separation. The user
explicitly asked for "C API mapping にしばられない", so this
alternative is rejected even though it's the most "obvious"
port.

### Alternative B — Single fused `WasmModule` (zwasm v1's design)

Keep the v1 shape: `WasmModule.load(alloc, bytes)` returns a
fully-instantiated, callable handle.

**Why rejected**: Conflates Module (immutable, parseable once,
shareable) with Instance (mutable, per-instantiation state).
Wasm 2.0 cross-module imports + multi-instantiation of the same
module need the two separated. v1's `loadLinked()` bolt-on for
cross-module is exactly the shape this ADR avoids.

### Alternative C — wazero's 2-stage `Runtime + Module-as-instance` (`r.Instantiate(bytes)` returns instance)

Hide Module entirely; `runtime.instantiate(bytes)` returns an
instance that internally cached the parsed module.

**Why rejected**: When the same module is instantiated twice
(common in test runners + the differential gate), this shape
re-parses every time. Zwasm v2's parse + validate + lower path
is non-trivial cost; explicit `Module` lets hosts cache it. The
3-stage + 3-line entry path (D-2) buys cache-friendliness with
minimal extra ceremony.

### Alternative D — Builder pattern (`runtime.compile(bytes).withWasi().instantiate()`)

Method-chained builder all the way through.

**Why rejected**: Builders work in Rust where moves are cheap
and types can be replaced mid-chain. In Zig, intermediate
values would need to outlive their `with*` call (or be
returned by value, paying an unnecessary copy). The
options-struct-on-instantiate (D-4) gets the same composability
without the temp-object dance.

## Consequences

### Positive

- Three-line happy path matches wazero's gold standard.
- `Module` / `Instance` separation supports cross-module
  imports + multi-instantiation cleanly (Wasm 2.0).
- Two-layer call API (`invoke` + `TypedFunc`) covers both the
  spec-runner / generic-tool case and the typed-host case
  with zero overhead.
- Single error-set discipline (`Trap`, `ParseError`,
  `InstantiateError`) makes `catch` exhaustive and grepable.
- WASI-as-option (D-4) avoids v1's attach-after-construction
  ordering bugs.
- Stability boundary (D-7) is explicit: callers know what's
  safe to depend on across v0.1.0 → v0.2.0.

### Negative

- Breaking change vs v1: `WasmModule.load(alloc, bytes)` →
  `Runtime.init + Module.parse + module.instantiate`. ClojureWasm
  v1 (only known external Zig consumer per CLAUDE.md "not
  authoritative" notes) needs migration. **Accepted by user
  upfront** — ClojureWasm v1 改修 is in scope.
- Three top-level types is more than wazero's one (`Runtime`).
  Mitigated by the 3-line entry path being approximately as
  short as wazero's; the cost is one extra type name per
  module compile.
- `TypedFunc(Params, Results)` requires comptime reflection —
  small comptime cost at the call site (opaque to runtime).
- The "stable surface" promise (D-7) commits to API discipline
  that the project hasn't formally tracked before. Mitigated
  by ADR-0023 §3 P-A "single source of truth" already
  pointing this direction.

### Neutral / follow-ups

- A `runtime.printStats()` debug helper (line counts, parse
  times) could land later as a stable but optional API.
- v0.2.0 may add `Module.serialize()` / `Module.deserialize()`
  for AOT-compiled module caches — consistent with the
  Module-as-immutable design.
- The C API surface (`api/wasm.zig`) remains independent;
  changes here don't ripple to `wasm_engine_t` etc. Per
  ADR-0023 §3 P-A both surfaces share the same internal core
  types (`runtime.Runtime`, `runtime.Trap`, `runtime.Value`).

## Implementation phases

This ADR's implementation is **mostly independent of Phase 7**
(emit-split + x86_64) — the Zig surface is a thin facade over
existing internal types and needs no IR / regalloc / emit
changes. **One dependency** (review-fix per self-review Issue
5): B-4's `ImportEntry → ImportBinding` conversion requires
that `runtime/instance/import.zig:ImportBinding` is in place.
ADR-0023 §7 item 5 Step A2 introduces this type; verify
landing before starting B-4. If B-4 is started before A2 has
landed, B-4 must include the ImportBinding promotion as a
prereq commit.

| Phase | Scope | Estimated commits |
|---|---|---|
| **A** (this ADR) | Design + ADR-0025 + ROADMAP §X new section + handover sync | 1 commit |
| **B-1** | Thin facade in `src/zwasm.zig`: `Runtime` / `Module` / `Instance` constructors + `invoke` | ~3 commits |
| **B-2** | `TypedFunc(P, R)` comptime layer + `getTyped` | ~2 commits |
| **B-3** | WASI subsystem surface change in `wasi/host.zig` (tagged-union `WasiStdio`) + public `WasiConfig` integration via `instantiate(.{ .wasi = ... })` + `runWasi()` | ~3 commits (was 2; expanded per Issue 8) |
| **B-4** | **Prereq**: confirm `runtime/instance/import.zig:ImportBinding` is in place (per ADR-0023 §7 item 5 Step A2). Then `ImportEntry` slice + cross-module wiring per D-5 — facade-side conversion `ImportEntry → ImportBinding`, sourced from a live `*Instance`. | ~2 commits |
| **B-5** | `examples/zig_host/{hello, fib, wasi_run}.zig` + `zig build run-example -Dexample=<name>` | ~2 commits |
| **D** (release docs) | `docs/migration_v1_to_v2.md` Zig section — write **before** Phase C so consumers have a migration guide (review-fix per self-review Issue 7) | 1 commit |
| **C** (external) | ClojureWasm v1 改修 — migrate Zig consumer to new surface, guided by Phase D's migration doc | external repo |

Phase B is sequenced after the active Phase 7 work
(§9.7 / 7.5d sub-b emit-split + 7.6 x86_64 baseline) — Phase 8
or interleaved when Phase 7 hits a gate-wait.

## References

- **Survey reports** (2026-05-05):
  - on-disk: wasmtime / wazero / wasmer / WAMR / WasmEdge / zwasm v1 host APIs
  - web: Zig public-surface conventions (ziglang.org, ziggit.dev,
    std lib source, bun, zware, ghostty)
- **Wasm runtime references**:
  - [wazero — Go runtime, fused Runtime API](https://github.com/tetratelabs/wazero)
  - [wasmtime — Rust runtime, TypedFunc<P,R>](https://docs.wasmtime.dev/api/wasmtime/struct.Func.html)
  - [wasmer — Rust runtime, imports! macro](https://github.com/wasmerio/wasmer)
  - [zware — Zig runtime, top-level Store/Module/Instance](https://github.com/malcolmstill/zware)
  - [zwasm v1 — Zig runtime, fused WasmModule](../../../zwasm/src/types.zig)
- **Zig idiom references**:
  - [Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)
  - [Zig 0.15.1 — Unmanaged-by-default ArrayList](https://ziglang.org/download/0.15.1/release-notes.html)
  - [bun src/bun.zig — flat-index pattern](https://github.com/oven-sh/bun/blob/main/src/bun.zig)
  - [std/heap/arena_allocator.zig — init/deinit shape](https://github.com/ziglang/zig/blob/master/lib/std/heap/arena_allocator.zig)
  - [Zig issue #9909 — no field privacy by design](https://github.com/ziglang/zig/issues/9909)
- **Internal**:
  - ADR-0023 (src/ directory structure normalisation; §3 P-A)
  - ADR-0024 (module graph + library root + self-import)
  - ADR-0014 (FuncEntity + cross-module dispatch — informs D-5)
  - ADR-0007 (C ABI carve-out — informs D-7's Zig-vs-C-API
    independence)
  - ROADMAP §10 (CLI surface), §4.4 (C ABI surface) — Zig
    surface to be added as a sibling section per Phase A.

## Revision history

| Date       | Commit       | Why-class | Summary                                                                                                                                                                                                                                                                                                                                                                |
|------------|--------------|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-05 | `<backfill>` | initial   | Adopted; designs the Zig host-library surface explicitly (3-line happy path, fused Runtime, Module/Instance separation, dual-layer call API, WASI-as-option).                                                                                                                                                                                                          |
| 2026-05-05 | `<backfill>` | gap       | Self-review amendments (8 issues): D-1 zone placement clarified (facade in src/zwasm.zig, lib zone); D-3 "zero overhead" → "constant overhead" (corrected box/unbox cost); D-4 WASI prereq (wasi/host.zig WasiStdio union add) acknowledged; D-5 cross-module source `*Module` → `*Instance` (ADR-0014 §6.K.3 needs live runtime); D-7 ParseError+InstantiateError added to stable list; D-8 rationale updated (back-ref pattern + dispatch doesn't allocate); B-3 commit estimate +1; B-4 ImportBinding prereq stated; Phase C/D ordered as D before C. |
