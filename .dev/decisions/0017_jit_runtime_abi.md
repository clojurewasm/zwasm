# 0017 — Adopt explicit JitRuntime ABI: X0 = `*const JitRuntime`

- **Status**: Accepted
- **Date**: 2026-05-04
- **Author**: Shota / autonomous loop
- **Tags**: jit, abi, runtime, phase7

## Context

Phase 7 §9.7 / 7.3 sub-f1 onward introduced **caller-supplied
register invariants** (X24..X28) holding linear-memory base /
limit, table funcptr base, table size, typeidx base. These were a
"shortest-path-to-running-bytes" skeleton: the §9.7 / 7.4
inline-asm `entry frame` (sub-7.4c, commit `93e2f2c`) hand-loads
those five registers from a `RuntimeInvariants` struct before
BLR, and the JIT body reads them directly.

Three problems with the skeleton:

1. **Doc/impl divergence — silent misexecution risk** (D-NEW1).
   `abi.zig` documents X24..X28 as "NOT in the regalloc pool",
   but `allocatable_gprs` actually includes X19..X28. A function
   with ≥14 vregs trips `slotToReg(14..16) → X26..X28` and
   silently overwrites the caller invariants. Currently latent
   because tests use ≤2 slots. ADR-0018 fixes the pool side; this
   ADR fixes the calling-convention side.
2. **Per-arch hack**. The inline-asm shim is Mac aarch64 only.
   x86_64 (ADR-0019) needs a different register set; copying the
   shim pattern produces drift.
3. **D-014 (Runtime injection point) deferred indefinitely**. The
   debt row has been "design later" since §9.6. Five separate
   X-register invariants is enough surface area to demand a
   structural answer.

## Decision

Define a **load-bearing JIT calling convention** for Wasm
functions executed under the JIT, parameterised by a single
runtime pointer.

### `JitRuntime` struct (`src/runtime/jit_abi.zig`, Zone 1)

```zig
pub const JitRuntime = extern struct {
    vm_base:       [*]u8,         // linear-memory base
    mem_limit:     u64,           // linear-memory size in bytes
    funcptr_base:  [*]const u64,  // table 0 funcptr array
    table_size:    u32,           // table 0 entry count
    _pad0:         u32 = 0,
    typeidx_base:  [*]const u32,  // table 0 typeidx side-array
    // Future: trap_buf, host_call_dispatch, etc. (Phase 8+).
};
```

`extern struct` keeps the layout deterministic across Zig versions
+ across the ABI boundary the JIT-emitted prologue depends on.

The module exposes **comptime-checked byte-offset constants** for
emit consumption:

```zig
pub const vm_base_off:      u12 = @offsetOf(JitRuntime, "vm_base");
pub const mem_limit_off:    u12 = @offsetOf(JitRuntime, "mem_limit");
pub const funcptr_base_off: u12 = @offsetOf(JitRuntime, "funcptr_base");
pub const table_size_off:   u12 = @offsetOf(JitRuntime, "table_size");
pub const typeidx_base_off: u12 = @offsetOf(JitRuntime, "typeidx_base");
```

Each fits in `LDR`'s imm12 (×8 scaling for X-form, ×4 for W-form),
so the prologue's loads are 1 instruction each. A static assert
verifies all five offsets fit in their imm12 budget; reordering or
extending `JitRuntime` past 32 KiB triggers a comptime error.

### Calling convention (per-arch, AAPCS64 first)

A JIT-compiled Wasm function `(params...) → results...` becomes
a native function with the following ABI:

- **X0** (or x86_64 `RDI`) carries `*const JitRuntime`.
- Wasm parameters occupy the **remaining** AAPCS64 arg slots:
  - GPR (i32/i64) args → X1, X2, ..., X7 — **7 GPR-arg slots**
    (one fewer than vanilla AAPCS64 because X0 is reserved for
    the runtime ptr); 8th+ Wasm GPR arg spills to stack.
  - FP (f32/f64) args → V0, V1, ..., V7 — **8 FP-arg slots**,
    unaffected by the X0 reservation.
- X8 (indirect-result-location pointer in AAPCS64) is **not used
  for Wasm args**; reserved for future multi-result returns
  (Wasm 2.0+).
- Results return in W0/X0 (i32/i64) or S0/D0 (f32/f64) per
  AAPCS64.

The body's prologue loads the five invariants from `*X0`:

```
LDR X28, [X0, #vm_base_off]
LDR X27, [X0, #mem_limit_off]
LDR X26, [X0, #funcptr_base_off]
LDR W25, [X0, #table_size_off]   ; w-form, upper 32 cleared
LDR X24, [X0, #typeidx_base_off]
```

Each `LDR` is one instruction; total prologue overhead is 5
instructions (~5 cycles uncached). Acceptable per ROADMAP §2 (P3
cold-start prioritises predictable dispatch over absolute peak
throughput; P7 backend equality is enforced operationally per
ADR-0019).

### `entry` frame becomes trivial

A JIT-emitted Wasm function's Zig-level type is:

```zig
*const fn (rt: *const JitRuntime, args...) callconv(.c) ResultT
```

For the no-arg `() → i32` shape used by sub-7.4c's smoke test,
this is `*const fn (*const JitRuntime) callconv(.c) u32`. The
inline-asm entry shim collapses to a normal function-pointer
call:

```zig
const f = module.entry(idx, *const fn (*const JitRuntime) callconv(.c) u32);
return f(&runtime);
```

No per-thread reg setup, no inline-asm clobber list. Calling
convention is the standard AAPCS64 / System V, so Zig's normal
function-pointer call works directly. Per-arch trampolines are
unnecessary for entry; the same Zig source compiles for both
backends.

### regalloc pool consistency

The five invariant regs leave the regalloc pool entirely (per
ADR-0018). Prologue loads them once per function, body reads
them, body never writes them. Callee-saved nature (X24..X28 per
AAPCS64) is preserved — the JIT body's epilogue does NOT need to
spill them because the body never modified them; AAPCS64
"untouched" path applies.

## Alternatives considered

### Alternative A — Keep caller-supplied skeleton

- **Sketch**: Continue with inline-asm entry shim; declare the
  pattern "good enough" since tests pass.
- **Why rejected**: silent overwrite risk grows with regalloc
  pressure; per-arch shim duplicates with x86_64 (ADR-0019);
  D-014 stays open indefinitely.

### Alternative B — Pass invariants in callee-saved-spill slots

- **Sketch**: Wasm function's prologue saves X19..X23 (its own
  callee-saved usage) AND the invariants from the caller. Wasm
  args remain in X0..X7.
- **Why rejected**: reverses the load-direction. Caller still
  needs to materialise five values, and the body still trusts
  them — same silent-overwrite class. Saves no instructions vs.
  loading from `*X0`.

### Alternative C — Per-function "captured" environment via closure

- **Sketch**: Each compile() bakes vm_base etc. as immediate
  constants directly into the body via MOVZ+MOVK staging.
- **Why rejected**: invariants change per Instance, even per
  `memory.grow` call. Re-emitting code on every grow is
  unworkable. Only feasible for small constants like
  table_size known at compile time.

### Alternative D — Use X18 (platform reg) for runtime pointer

- **Sketch**: Set X18 = `*const JitRuntime` in entry; body uses
  X18 directly without prologue load.
- **Why rejected**: X18 is platform-reserved on Apple/Darwin
  (per AAPCS64 + Darwin convention); using it as application reg
  is undefined behavior on Apple Silicon.

## Consequences

### Positive

- **D-014 dissolves**. Runtime injection has a structural answer.
- **Per-arch parity by construction** (P7, operationalised by
  ADR-0019). x86_64 (ADR-0019)
  uses the same `JitRuntime` shape with arch-specific reg
  assignments (RDI = runtime ptr, etc.).
- **Inline-asm entry shim retired**. Standard function-pointer
  call replaces 30 lines of inline asm + clobber list.
- **regalloc/reserved overlap structurally impossible** combined
  with ADR-0018: the 5 invariant regs are loaded from `*X0` per
  function, used as live values inside the body's regalloc
  pool — but the body's regalloc pool excludes them entirely
  (ADR-0018), so no overlap can occur.
- **memory.grow integration becomes natural**: the host updates
  `vm_base` / `mem_limit` in the `JitRuntime` struct.
  - **Cross-call**: subsequent function calls re-load via
    prologue. No code re-emission.
  - **Within-call**: a `memory.grow` op handler must re-LDR
    X28 + X27 from `*X0` immediately after the host-call returns
    (the host updates the struct in-place); subsequent memory
    ops in the same function then see the new values. ADR-0017
    requires sub-f3 to be amended for this re-load (deferred
    follow-up at the implementation cycle).

### Negative

- **5-instruction prologue overhead per call**. ~5 cycles
  uncached, ~1 cycle cached. Not a concern for cold-start
  Phase 7; Phase 15 (optimisation) can elide loads when the
  function provably doesn't touch memory/tables.
- **Wasm arg-reg shift**: X1..X7 instead of X0..X7 means one
  fewer GPR arg slot. Functions with 8+ GPR args spill the 8th+
  to stack one Wasm-arg sooner than vanilla AAPCS64. Rare in
  practice (most Wasm functions have ≤4 args).
- **`marshalCallArgs` rewrite**: caller-side arg marshalling
  (sub-g3b) loops over X0..X7 today. Becomes X1..X8 with X0 set
  to the runtime ptr.
- **Existing code rewrite**:
  - `src/engine/codegen/arm64/emit.zig`: prologue add 5 LDRs, arg
    marshalling shift X0→X1, end handler shift result reg
    (already in W0/X0; unchanged).
  - `src/engine/codegen/shared/entry.zig`: inline-asm shim → standard function
    pointer call.
  - `src/engine/codegen/arm64/abi.zig`: ABI doc rewrite.
  - All emit.zig tests with `params != []`: arg slot shift.

### Neutral / follow-ups

- **ADR-0018 (regalloc reserved set + spill)** is paired:
  removes X24..X28 from the pool, makes spill first-class.
- **ADR-0019 (x86_64 in Phase 7)** depends on this: defines the
  System V mapping (RDI = `*const JitRuntime`).
- **Future Phase 8+ extensions**: `trap_buf`, `host_call`
  dispatch table, `gc_root_set` ptr — all attach to
  `JitRuntime`'s tail without breaking the ABI.

## References

- ROADMAP §2 (P3 cold-start, P7 backend equality —
  operationalised within Phase 7 by ADR-0019)
- ROADMAP §9.7 (Phase 7 task table, post-ADR-0019 reshape)
- D-014 (`Runtime.io` injection point design — dissolved here)
- Related ADRs: 0014 (pre-Phase-7 redesign), 0018 (regalloc
  reserved set + spill), 0019 (x86_64 in Phase 7)
- `src/engine/codegen/arm64/abi.zig`, `src/engine/codegen/arm64/emit.zig`,
  `src/engine/codegen/shared/entry.zig` (current caller-supplied skeleton),
  `src/engine/codegen/shared/linker.zig`

## Revision history

- 2026-05-04 — Proposed. SHA: `<backfill at acceptance>`
- 2026-05-04 — **Amendment**: X19 reserved as runtime_ptr save
  register for multi-call functions. The original "Decision"
  section specified the calling convention (X0 = runtime ptr)
  but did not address X0 preservation across calls within a
  body. Per AAPCS64, X0 is caller-saved — clobbered by every
  BL/BLR. A body that calls 2+ other functions cannot pass
  the inherited X0 to the second+ call (junk by then).
  
  **Decision**: prologue saves runtime ptr to X19 (added to
  `reserved_invariant_gprs`); each call/call_indirect site
  restores X0 from X19 before BL/BLR. X19 is callee-saved per
  AAPCS64, so its value is preserved across calls without
  explicit save/restore. Pool size drops from 10 to 9
  (allocatable callee-saved becomes X20..X23).
  
  **Alternatives considered**: stack-save (1 STR in prologue +
  1 LDR per call vs. 1 MOV in prologue + 1 MOV per call;
  reg-save is cheaper and matches the register-resident
  invariant pattern of the rest of ADR-0017 + ADR-0018).
  
  Sub-2d-ii implementation cycle. SHA: `<backfill at acceptance>`

- 2026-05-05 — **Refinement (per `adr-revision-history-misuse`
  categorisation)**: the §"Per-arch parity by construction"
  paragraph (line ~184) read "x86_64 (ADR-0019) uses the same
  `JitRuntime` shape with arch-specific reg assignments (RDI =
  runtime ptr, etc.)", which implied the **load-once mirror
  reservation pattern** (X28..X24 + X19) would carry over to
  x86_64 with renamed registers. In practice that mirror is
  unworkable — x86_64 has only 6 callee-saved GPRs (vs ARM64's
  10), and reserving 5 for invariants while keeping RBP as the
  frame pointer collapses the regalloc pool to ~2 regs.

  **What changed**: x86_64's invariant strategy is now governed
  by **ADR-0026** (single-reservation, reload-from-runtime-ptr
  model). R15 alone holds the saved runtime ptr (mirror of
  X19); other invariants reload from `[R15 + offset]` at point
  of use. The shared contract from ADR-0017 (JitRuntime struct
  layout + offset constants + `*X0` / `*RDI` calling convention)
  is unchanged; only the **per-arch invariant residence
  strategy** diverges.

  This is a **refinement** rather than a gap — ADR-0017's
  shared contract still holds; ADR-0026 extends it with a
  per-arch reservation strategy that ADR-0017 conflated under
  "per-arch parity". Future arch ports (RISC-V, etc.) read
  ADR-0017 + ADR-0026 together to understand the pool-pressure
  vs reload-cost trade and pick a strategy. SHA: `<backfill>`
