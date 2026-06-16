# zwasm → ClojureWasm v1 handoff (development paused 2026-06-08)

> **Doc-state**: ACTIVE
>
> zwasm v2 development is **intentionally paused** (branch `zwasm-from-scratch`),
> verified green on Mac aarch64 + ubuntu x86_64. The runtime is feature-complete
> for ClojureWasm v1's needs; further zwasm work is **demand-driven** — resume
> only when cw v1 development surfaces a concrete requirement (see "Resuming
> zwasm" below). No release is tagged (ADR-0156: tag/publish/`main`-cutover are
> manual, user-only).

### Demand-driven updates since the pause

- **2026-06-08 — musl portability fixed (handoff §A1).** `x86_64-linux-musl`
  ReleaseSafe `-Dwasm` builds now link: the Linux thread-stack query no longer
  hard-depends on the glibc `pthread_getattr_np` `_np` extension. It is
  `comptime`-gated behind `builtin.abi.isGnu()`, with a portable musl fallback
  that derives the main-thread stack bounds from `/proc/self/maps` +
  `RLIMIT_STACK` (the same method glibc and the LLVM sanitizers use). Verified:
  cljw's exact failing build links, and the fallback is runtime-checked on a
  real Linux musl-static binary. **This unblocks the single-static-binary edge
  deploy with `-Dwasm`.** (ADR-0178.) The leftover `'x86-64' is not a recognized
  processor` line under `-mcpu baseline` is a non-fatal zig/compiler-rt warning,
  not a zwasm error.

## What zwasm v2 gives you (maturity)

| Area | State |
|---|---|
| Core Wasm **1.0 / 2.0 / 3.0** | **100% spec testsuite, 0 skip**, 3-host green (Mac aarch64 · ubuntu x86_64 · windows x86_64) |
| v0.2 features | atomics (threads), wide-arithmetic, custom-page-sizes, relaxed-SIMD — all complete + official corpora |
| WASI **0.1 (preview1)** | Complete |
| **Component Model + WASI Preview 2** | Functional: a real `rustc --target wasm32-wasip2` component runs e2e through zwasm. Structural component validation (type-index / Canon / alias / ExternDesc bounds — ADR-0176). **Compile-in is on by default** (gated by `-Dwasi>=p2`; `-Dwasi=p1` opts out) |
| Engine | Single-pass JIT (aarch64 + x86_64 SysV/Win64) + interpreter. `-Dengine=jit\|interp\|both` |
| Surfaces | **C-API** (upstream wasm-c-api, `include/wasm.h`+`wasi.h`+`zwasm.h`) — gap-free vs the suite. **Zig API** (`src/zwasm.zig` facade). **CLI** (`zwasm run`, `zwasm compile`) |
| Memory safety | Sound across all areas (ASan/leak-checked); JIT now ReleaseSafe-clean on the host boundary (D-311) |

## How cw v1 consumes zwasm

**Zig embedder (recommended, ADR-0109 native-API inversion).** Path-dependency
in cw v1's `build.zig.zon` → `build.zig`:

```zig
const zwasm = b.dependency("zwasm", .{
    // .optimize / .target propagate; add feature flags as needed
}).module("zwasm");
your_module.addImport("zwasm", zwasm);
```

Public Zig facade (`src/zwasm.zig`): `Engine`, `Module`, `Instance`,
`TypedFunc`, `Memory`, `Global`, `Table`, `Linker`, `Caller`, `Value`,
`Trap`, `ExternKind`, `Import/Export` introspection. Typical flow:
`Engine.init` → `engine.compile(wasm_bytes)` → `Linker`/`Instance` →
`instance.invoke` / `TypedFunc`.

**Teardown / ownership (handoff §A4).** Lifetimes are caller-owned and
explicit — there is no GC finaliser, so deinit in reverse construction order:

- `Engine.init(alloc, .{})` → `engine.deinit()`. The `Engine` owns engine-level
  state and **outlives every `Module`/`Instance`/`ComponentInstance` made from
  it** — it is *borrowed* by them, never freed by their deinit. Deinit the
  engine **last**.
- `Module` / `Instance`: each has its own `deinit()`; free instances before the
  module, the module before the engine.
- `ComponentInstance.deinit()` / `ComponentGraph.deinit()` free their own core
  module + instance + decoded/type state, **but not** the borrowed `Engine`.
  So cw v1's `(wasm/load …)` finaliser should hold `{engine, instance}` and, on
  finalisation, call `instance.deinit()` then `engine.deinit()` (cw-side D-259
  leak: wire the finaliser to this pair).

**C host.** Link `libzwasm.a` + the vendored `include/wasm.h` (standard
wasm-c-api). Drop-in for hosts already targeting that interface.

**CLI.** `zig build` → `zig-out/bin/zwasm run <file.wasm>` /
`zwasm compile <file.wasm>`. Component Model / WASI-P2 is on by default
(default `-Dwasi=p2`); `-Dwasi=p1` for a lean core+P1 build.

**Build flags** (`zig build -D…`): `wasm=1.0|2.0|3.0` (default 3.0),
`wasi=none|p1|p2|p3` (default p2; ordered tier — p2 = Component Model / WASI-P2,
p3 = + Preview-3 async), `engine=jit|interp|both` (default both),
`gc=true` (WasmGC compile-in, default off), `strip`, `sanitize`. ADR-0193 folded
the former `component=true` flag into `-Dwasi>=p2`.

See also: `docs/tutorial.md`, `docs/migration_v1_to_v2.md` (v1→v2 surface map).

## Long-tail / known gaps (only matter if cw v1 hits them)

- **Component Model embedding API (handoff §A2)**: the surface cljw uses lives
  in `src/api/component.zig` — `component.instantiate(engine, alloc, bytes)
  → ComponentInstance`, `ComponentInstance.invokeStringExport` / `.invokeFlat`,
  and `component.instantiateGraph → ComponentGraph` (cross-component). These
  signatures are functional and the e2e path is proven. The `IT-1/2/3` labels in
  that file's comments/test names are **campaign stage-markers, not signature
  churn**. Execution is functional (real component e2e), but the embedding API
  is **not yet frozen** (gated by `-Dwasi>=p2`, on by default): it may still change
  when the deeper-conformance thread resumes. Recommendation:
  pin core-Wasm FFI now (stable); treat the CM embedding surface as a spike until
  it's frozen. Demand a freeze when cw v1 commits to a CM spike.
- **Component Model deeper conformance**: structural validation done (4 rules);
  *deep* validation (name kebab-case/extern-name — fixtures need binary
  extraction from the official `.wast`; full subtyping; canon-ABI lowering
  constraints) is deferred. The official `component-model/test/wasm-tools`
  corpus is 365 `assert_invalid` + 17 `assert_malformed`; the structural
  subset is covered, the rest enumerated for later. See `.dev/component_model_plan.md`.
- **WASI-P2 sockets** (`wasi:sockets/*`): not implemented (spike-first).
- **Cross-toolchain proof**: Rust wasm32-wasip2 proven; Go/tinygo component
  proof is toolchain-gated (wit-bindgen-go not in the gen shell), opportunistic.
- **`call_ref` / function-references runtime**, and various future-proposal
  rows: tracked `blocked-by` in `.dev/debt.yaml` (32 entries) — mostly correct
  long-tail deferrals, not bugs.
- **D-299**: an x86_64 W^X / JIT atomic-alignment item, env-constrained
  (deferred, env-blocked, not a correctness gap on the supported path).
- Component compile-in is gated by the WASI tier `-Dwasi>=p2` and is **on by
  default** (default `-Dwasi=p2`); pass `-Dwasi=p1` for a lean build if cw v1
  does not need the Component Model / WASI P2 (ADR-0193 removed `-Dcomponent`).

None of these block core-Wasm / WASI-P1 embedding, which is complete.

## Iteration speed (for whoever resumes)

Integration test runners build **ReleaseSafe** by default (ADR-0177): `zig
build test-all` runs the spec/realworld/wast corpora optimized (fast) while
unit `zig build test` stays Debug. No flag needed.

## Resuming zwasm development

The repo carries a self-driving loop. To resume:
1. Read `.dev/handover.md` (current state + the parked work pointers).
2. `.dev/ROADMAP.md` is the single source of truth (phases, principles).
3. The `/continue` skill (`.claude/skills/continue/SKILL.md`) drives the
   autonomous TDD loop; the parked **CM-validation** bundle (deeper component
   conformance) is the natural next thread if cw v1 needs richer CM.
4. 3-host gate discipline + ADRs in `.dev/decisions/` explain every
   load-bearing decision.

**Frozen invariants** (unchanged): no autonomous release (ADR-0156); never
push `main`; `--force` forbidden; v1 ABI compatibility out of scope (ADR-0156).
