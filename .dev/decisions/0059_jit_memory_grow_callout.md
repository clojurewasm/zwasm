# 0059 — Adopt a `JitRuntime` callout pattern for `memory.grow`

- **Status**: Accepted
- **Date**: 2026-05-13
- **Author**: autonomous /continue loop (Shota Kudo)
- **Tags**: jit, abi, runtime-callout, memory.grow, phase9

## Context

`§9.9 / 9.9-l-1b` (Wasm 2.0 spec corpus) surfaced D-093 cluster (a):
six fails across `nop:as-memory.grow-{first,last,everywhere}`,
`block:as-memory.grow-value`, `loop:as-memory.grow-value`, and
`local_tee:as-memory.grow-size`. These fixtures call
`(memory.grow (i32.const N))` and expect the return value to be
the previous page count. The current JIT skeleton (introduced in
the Phase 7 JIT v1 baseline; see `arm64/emit.zig:1310` and
`x86_64/emit.zig:1405`) unconditionally emits `MOVN Wd, #0` /
`MOV r32, -1`, which is spec-conformant for hosts that refuse
growth but does not satisfy these tests.

Implementing the operation requires a callback from JIT-compiled
code into host-managed storage so the linear-memory buffer can be
reallocated and the prologue-cached `vm_base` / `mem_limit`
invariants refreshed. zwasm v2 has no such callout mechanism yet
— the existing host-import dispatch (`host_dispatch_base` array
of `[*]const usize`, chunk 7.9-d) targets Wasm `call`/`call_indirect`
through a fixed name space, not runtime-builtin helpers.

The 2026-05-13 Step 0 survey covered v1 zwasm, wasmtime Cranelift
+ Winch, wasmer singlepass, wazero, and WAMR fast-JIT. All five
implementations converge on a function-pointer-in-context pattern
(field on the JIT context struct, C ABI invocation, post-call
reload of cached base/limit). Variations are in (a) whether the
fn ptr lives in a dedicated slot or a generic builtin-table, (b)
how multi-memory is threaded, and (c) where the host-owned
allocator state hangs off the context.

This decision picks the per-callout-named-slot variant for the
**MVP** because it is the cheapest extension to JitRuntime's
existing offset-driven design (every callout adds one
`@offsetOf`-derived constant; no per-table indirection) and
forms a clean foundation for follow-on callouts (`table.grow`,
GC alloc, EH trap dispatcher).

## Decision

Extend `JitRuntime` (`src/engine/codegen/shared/jit_abi.zig`)
with two tail fields and a paired pattern:

```zig
/// Opaque pointer to host-managed state needed by runtime callout
/// fn ptrs (allocator, back-reference to the canonical backing
/// buffer the JitRuntime aliases). The host sets this at JIT-frame
/// construction; each callout's fn ptr knows how to interpret it.
/// Independent of the per-callout slots so multiple callouts can
/// share the same host-state without one being privileged.
host_state: ?*anyopaque = null,
/// `memory.grow mem=0` callout. Args:
///   - `rt: *JitRuntime` — the JIT context (caller's invariants
///     live here; the callout MUST update `vm_base` + `mem_limit`
///     in place when growth succeeds so the JIT body's
///     post-call reload sees the new values).
///   - `delta_pages: u32` — Wasm 1.0 page count (1 page = 64 KiB).
/// Returns:
///   - old page count on success (`u32` widened to i32).
///   - `-1` on failure (spec sentinel; matches interp's
///     `pushOperand(.{ .i32 = -1 })` path).
/// Calling convention: C-ABI (SysV on Linux/macOS x86_64 + Win64
/// on Windows; AAPCS64 on arm64). The fn MUST preserve all
/// callee-saved registers per the host ABI; the JIT body relies
/// on this so `X19..X28` (arm64) and `RBX,R12..R15` (x86_64) are
/// stable across the call.
memory_grow_fn: ?*const fn (rt: *JitRuntime, delta_pages: u32) callconv(.c) i32 = null,
```

JIT emit (this ADR's `Decision` is the ABI surface; the per-arch
emit recipes land in follow-on chunks `9.9-l-1b-d093-d8b` arm64
and `9.9-l-1b-d093-d8c` x86_64) follows the host_dispatch_base
pattern:

- **arm64**: pop delta vreg → load into `W1`; restore `X0 = X19`
  (runtime_ptr per ADR-0017 sub-2d-ii); `LDR X16, [X19,
  #memory_grow_fn_off]`; `BLR X16`; reload `X28 ← [X19,
  #vm_base_off]` and `X27 ← [X19, #mem_limit_off]` (the prologue-
  cached invariants from ADR-0017's 5 LDRs); capture `W0` to the
  result vreg via `captureCallResult`-equivalent path.
- **x86_64**: pop delta vreg → marshal into `ESI` (SysV) / `EDX`
  (Win64); `MOV <entry_arg0>, R15`; `MOV RAX, [R15 +
  memory_grow_fn_off]`; `[Win64 shadow alloc]`; `CALL RAX`;
  `[Win64 shadow free]`; capture `EAX`. x86_64 does NOT cache
  vm_base / mem_limit in reserved registers (per ADR-0017
  asymmetry — every memory op re-reads `[r15+vm_base_off]`), so
  no post-call invariant reload is needed; the next memory op
  picks up the updated `vm_base` / `mem_limit` naturally.

`usage.zig:usesRuntimePtr` already includes `.memory.grow` in its
whitelist (per `D-087/D-088` discharge at §9.9 / 9.9-m-5); the
prologue therefore loads R15 for any function containing the
op, so the `[R15 + memory_grow_fn_off]` indirect call is valid
without prologue changes.

The MVP is **single-memory** (`mem_idx = 0`); the fn signature
deliberately omits a `mem_idx` parameter so Wasm 3.0 multi-memory
adoption splits cleanly into a `memory_grow_fn_v2` slot or a
generic dispatch-table when that proposal stabilises (see
"Neutral / follow-ups").

## Alternatives considered

### Alternative A — Builtin-function index table (Cranelift / wasmer pattern)

- **Sketch**: Add `builtin_fns: [*]const usize` (parallel to
  `host_dispatch_base`) with named indices (`MEMORY_GROW = 0`,
  `TABLE_GROW = 1`, `GC_ALLOC = 2`, …). Each callout site emits
  `LDR X16, [X19, #builtin_fns_off]; LDR X16, [X16, #(idx*8)]`.
- **Why rejected**: Two extra indirections per call (load array
  base + load slot) vs one direct field load. The runtime-builtin
  set is small (≤ 8 entries projected through Phase 12); the
  indirection cost outweighs the marginal flexibility. Adopting
  the table can be revisited at Phase 10 or 11 when more callouts
  exist; the migration is local (replace `[r15+memory_grow_fn_off]`
  with `[r15+builtin_fns_off][MEMORY_GROW*8]`).

### Alternative B — Trap-stub-style PC fixup (mirror of `bounds_fixups`)

- **Sketch**: Emit a placeholder `CALL 0` at the memory.grow site;
  the linker patches it with the relative offset to a per-module
  trampoline that loads the helper from a fixed location.
- **Why rejected**: Adds a per-callout fixup type to the linker;
  the existing `bounds_fixups` infrastructure is specialised to
  branch-to-tail-trap-stub (BCond/JCC, not BL/CALL); generalising
  it to function-call fixups is a larger refactor than the field-
  addition path. The `host_dispatch_base` pattern (chunk 7.9-d)
  already proved field-load-indirect-call is fast enough for the
  host-import path; no reason to deviate for builtins.

### Alternative C — Synthesize the realloc inline in JIT

- **Sketch**: Emit the realloc logic (mmap remap / fallback) as
  inlined JIT machine code, avoiding the call out entirely.
- **Why rejected**: Allocator choice is a host-side concern (zwasm
  is an embeddable runtime; the host may pin a specific allocator
  per `c_api.zig`'s Runtime construction). Inlining hardcodes the
  allocator into emitted code, breaking the
  separation-of-concerns invariant. Also significantly larger
  emit (`mmap` + bookkeeping + zero-fill loop) than a single CALL.

### Alternative D — Use the interp's `memoryGrow` directly (re-enter the dispatch loop)

- **Sketch**: The callout boots the interpreter dispatch loop on
  a synthesised `memory.grow` ZirInstr.
- **Why rejected**: Layer-inversion (JIT calling interp); creates
  a circular import between Zone 2's `engine/codegen` and Zone 2's
  `interp/`; the interp's `memoryGrow` reads from
  `Runtime.popOperand` which doesn't exist in the JIT-execution
  context. Cf. `lessons/2026-05-08-validator-dead-code-in-runtime.md`
  for the analogous validator-wiring case study.

## Consequences

### Positive

- Closes the D-093 cluster (a) — 6 spec fails on Wasm 2.0 corpus
  flip to PASS when `nop / block / loop / local_tee` are re-added
  to `scripts/regen_spec_2_0_assert.sh` NAMES (the deferred
  follow-up chunk).
- Introduces a generic runtime-callout pattern reusable for
  `table.grow` (currently emits via a similar skeleton; D-093
  cluster's siblings), GC alloc (Phase 10), EH dispatcher
  (Phase 10), atomic.wait/notify (Phase 14).
- ABI-tail extension only: no prologue-offset shift, no test-
  fixture churn (the prologue's 5 LDRs at offsets 0/8/16/24/32
  stay; `memory_grow_fn_off` lands at offset 200+ with the same
  comptime guards as prior field additions).

### Negative

- `host_state` is `?*anyopaque` — type-erasing the host's struct
  shape. The fn ptr's contract names what the host_state cast
  target should be; mismatched casts are silent UB. Mitigation:
  the spec runners (the only callout-using consumers in Phase 9)
  pair `memory_grow_fn` and `host_state` initialisation in one
  helper (e.g. `wireMemoryGrow(rt: *JitRuntime, host: *MyHost)`)
  so the cast target is determined by the fn ptr's identity, not
  by callsite convention.
- arm64 reloads `X28` + `X27` from `JitRuntime` after every
  successful grow — two extra LDRs per `memory.grow` call. This
  is unavoidable (the C-ABI fn modifies the JitRuntime fields;
  the prologue-cached register values become stale). Cost is
  ~3 cycles on M1 / Cortex-A77; negligible compared to the
  realloc itself.

### Neutral / follow-ups

- Wasm 3.0 multi-memory: when stabilised, add `memory_grow_fn_v2`
  with a `mem_idx: u32` arg, OR migrate to Alternative A's
  builtin-fn-table at the same time. Either path keeps the
  MVP slot working until consumers opt in.
- Spec-runner wiring (`test/spec/spec_assert_runner_base.zig`):
  the existing `makeJitRuntime` helper takes a fixed-size scratch
  buffer; growth requires an allocator-managed buffer. The d-8b
  chunk lands a `makeJitRuntimeGrowable` variant (or extends the
  existing helper) that the four affected fixtures (`nop` /
  `block` / `loop` / `local_tee` once added to NAMES) consume.
- Lessons / debt: no new debt expected from this ADR. The
  `host_state` type-erasure caveat is observational, not load-
  bearing; if a future cast bug bites, file a lesson then.

## References

- ROADMAP § 9.9 / 9.9-l-1b-d093-d8 (this chunk's row).
- Related ADRs:
  - 0017 — JIT v1 ARM64 baseline (JitRuntime + prologue 5 LDRs).
  - 0026 — x86_64 entry_arg0 + R15 runtime_ptr_save_gpr.
  - 0029 — Path B skip-impl == 0 enforcement.
  - 0045 — Spec-runner scratch-buffer-direct path.
  - 0056 — Phase 9 scope extension to Wasm 2.0 full.
- Lessons:
  - `2026-05-08-validator-dead-code-in-runtime.md` — same layer-
    inversion shape (validator inlined into JIT) rejected for
    the same reason.
- Survey: 2026-05-13 textbook survey covering v1, wasmtime
  (Cranelift `crates/cranelift/src/func_environ.rs:3246-3275`
  + builtin macro `crates/environ/src/builtin.rs`), Winch
  (`winch/codegen/src/visitor.rs:1934-1961`), wasmer singlepass
  (`lib/compiler-singlepass/src/codegen.rs:2878-2905`), wazero
  interpreter (`internal/engine/interpreter/interpreter.go:1095-1102`),
  WAMR fast-JIT (`core/iwasm/fast-jit/fe/jit_emit_memory.c:590-625`
  + core `core/iwasm/common/wasm_memory.c:1657-1750`).
- v1 reference: `src/jit.zig:4038-4063, 7701-7708` (jitMemGrow).
