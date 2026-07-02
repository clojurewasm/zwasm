# 0066 — Per-import bridge thunks for cross-module function-import dispatch

- **Status**: Closed (implemented; amended 2026-05-17 §A1 + 2026-05-18 §A2 — bridge thunk shape extended to save caller's full pinned reserved-invariant cohort: §A1 added X19 / R15 per D-142 fix (A); §A2 extended arm64 to X19 + X24..X28 per D-144 fix; x86_64 unchanged at R15 per ADR-0026's single-pin design. See Amendments §A1 + §A2 below.)
- **Date**: 2026-05-17
- **Author**: zwasm v2 maintainer (Phase 9 §9.9-III Cat III work)
- **Tags**: phase-9, cat-iii, cross-module, host-imports, jit, abi, instance, store, dispatch, thunks, callee-saved, aapcs64

## Context

ADR-0065 absorbed Wasm 1.0 cross-module / instance / linker work
into Phase 9 (§9.9-III). Sub-chunks (c)-1a / (c)-1b / (c)-1c
landed the foundation: `Store.register` (name → `*Instance`
opaque), `hostImportTrapStub` spectest no-op (binary-no-op
return), and runner `(register "M" $inst)` directive parsing.

The cross-module **call dispatch** (sub-chunk (c)-2) is the next
piece. Today's emit path (chunk 7.9-d, `op_call.zig:emitCall`)
routes every `call N` with `N < num_imports` through the
shared `host_dispatch_base` table:

```text
ARM64:
  LDR  X16, [X19, #host_dispatch_base_off]   ; ptr-of-ptrs
  LDR  X16, [X16, #(idx*8)]                  ; fn ptr at slot
  ORR  X0,  XZR, X19                         ; X0 = caller's JitRuntime
  BLR  X16                                    ; indirect call

x86_64:
  MOV  RAX, [R15 + host_dispatch_base_off]
  MOV  RAX, [RAX + idx*8]
  MOV  RDI, R15                              ; RDI = caller's JitRuntime
  CALL RAX
```

Each instance's `JitRuntime.host_dispatch_base` is a `[*]const
usize` indexed by import-function-idx. Today every slot points
at `hostDispatchTrap` (sets `trap_flag = 1`, returns 0) or, for
modules sharing the (c)-1b spectest stub, `hostImportTrapStub`
(returns 0 unconditionally).

**Critical observation**: the call site loads the *caller's*
`JitRuntime` pointer (X19 / R15) into the host stub's arg 0.
For a true host C function this is correct — the host stub
reads `*JitRuntime` to twiddle `trap_flag` / memory base / etc.
For a cross-module **Wasm** callee, this is wrong: the callee's
JIT body needs its own instance's memory / globals / table /
host_dispatch_base, all of which are reached through *its*
`JitRuntime`.

D-138 (filed 2026-05-17, lesson
[`cross-module-noop-stub-controlflow-hang`](../lessons/2026-05-17-cross-module-noop-stub-controlflow-hang.md))
documents the proof: a naive sub-chunk (c)-2 attempt routed
registered-alias function imports through the shared
`hostImportTrapStub` no-op (mirroring (c)-1b's spectest path).
The spec_assert runner hung past 180 s on
`zwasm-spec-wasm-2-0-assert` because cross-module callees are
arbitrary user code — they expect to mutate counter globals,
return non-zero control-flow signals, etc. — and a no-op stub
that returns 0 forever breaks the importer's loop-termination
contract. The fix needs **a per-import dispatch path that
actually executes the callee's JIT body in the callee's
instance context**.

A textbook survey of v1, wasmtime, zware, and wasm3 (see
2026-05-17 Step 0 survey) shows three viable approaches:

1. **Per-import lazy-compiled bridge thunk** (this ADR): each
   `host_dispatch_base[i]` slot points at a tiny native-code
   thunk that swaps the JitRuntime pointer (X0 / RDI) from
   caller's to callee's and tail-jumps to the callee's JIT
   entry. Caller-side emit is unchanged.
2. **No-thunk uniform convention**: caller pre-loads the
   callee's JitRuntime into X0/RDI from a parallel resolver
   table indexed by import_idx, then dispatches. Requires a
   second per-instance `[*]const *JitRuntime` array alongside
   `host_dispatch_base`, plus caller-side emit changes.
3. **Per-instance pre-compiled thunk module**: at instantiate
   time compile a complete "thunk module" with one bridge per
   import; same cost as #1 but eagerly compiled.

## Decision

Adopt **Alternative 1 — per-import lazy-compiled bridge thunks +
unchanged `host_dispatch_base` array slot**.

Concretely:

- **Slot layout**: `JitRuntime.host_dispatch_base[i]` stays a
  single `usize` per import-function. No new parallel arrays;
  no new caller-side metadata loads.
- **Slot contents**:
  - For a func import resolved against a registered exporter
    (`Store.lookup(import.module) != null`) and where the named
    export is a Wasm function: a pointer to a **bridge thunk**
    compiled into the importer instance's thunk arena.
  - For a func import resolved against a registered exporter
    whose named export is a **host C function** (future
    `wasm_func_new_with_env` integration): a direct pointer to
    that C function (no thunk; the host already speaks the
    `fn(rt: *JitRuntime, ...args) callconv(.c)` shape).
  - For a func import without a registered exporter (e.g.
    `(import "spectest" "print_i32" ...)` when no spectest
    bridge is installed): the existing `hostImportTrapStub` /
    `hostDispatchTrap` pointer.
- **Bridge thunk shape** (ARM64, ~32 bytes):

  ```text
  ; entry: X0 = caller's JitRuntime, X1..X7 = wasm args
    ADR  X16, .literals
    LDR  X0,  [X16]            ; X0 ← callee's JitRuntime
    LDR  X16, [X16, #8]        ; X16 ← callee's JIT entry
    BR   X16                    ; tail-call (callee's RET → caller)
  .literals:
    .quad <callee_rt_ptr>
    .quad <callee_entry_ptr>
  ```

  On x86_64 (~22 bytes):

  ```text
    MOV  RDI, <callee_rt imm64>
    MOV  RAX, <callee_entry imm64>
    JMP  RAX
  ```

  Tail-call semantics matter: the callee's `RET` returns
  directly to the importer's call site, so its return value
  sits in the callee's-ABI return register (X0/V0 on ARM64,
  RAX/XMM0 on x86_64). The caller's existing
  `captureCallResult` already reads that register per the
  callee's signature (known from `ctx.func_sigs[ins.payload]`).
- **Thunk arena**: per-instance JIT-allocated, mmap-ed RX,
  parallel to the function-body block. Sized at instantiate
  time to `num_func_imports * thunk_size`. Lives until the
  importer instance is destroyed (matching the
  `host_dispatch_base` lifetime).
- **Resolver wire-up** (the new code path):
  1. At `instantiateRuntime`, after parsing the import section
     and validating type compatibility against
     `Store.lookup(import.module).exports[import.name]`, walk
     each function import.
  2. If the exporter is a registered Wasm instance: emit a
     bridge thunk (ARM64 / x86_64 emitter shared via
     `engine/codegen/shared/thunk.zig`) into the thunk arena,
     planting (callee_rt, callee_entry) constants.
  3. Store `@intFromPtr(&thunk)` into
     `host_dispatch_base[import_idx]`.
  4. If the exporter is missing or the named export is missing:
     keep the existing default trap stub.
- **Linker `IMPORT_SENTINEL_OFFSET`**: unchanged. The sentinel
  still marks "function-table entries that name imports must
  not be reached via body-relative BL"; the thunk path is
  reached only via the `host_dispatch_base` indirect call,
  which the linker already handles.

## Alternatives considered

### Alternative 2 — No-thunk uniform convention with parallel resolver table

- **Sketch**: Add `JitRuntime.host_dispatch_rtptrs: [*]const
  *JitRuntime` parallel to `host_dispatch_base`. Per-import
  resolution writes `(callee_entry, callee_rt)` into the two
  arrays. ARM64 emit changes to:

  ```text
    LDR  X16, [X19, #host_dispatch_base_off]
    LDR  X16, [X16, #(idx*8)]      ; fn ptr
    LDR  X0,  [X19, #host_dispatch_rtptrs_off]
    LDR  X0,  [X0,  #(idx*8)]      ; callee's rt ptr
    BLR  X16
  ```

  No per-thunk native code; resolver table is plain data.

- **Why rejected**:
  - Adds two extra load instructions on the *call hot path*
    for every imported call. The bridge-thunk design keeps the
    call site at four instructions (LDR / LDR / ORR / BLR),
    paying the swap cost only when the call actually fires.
  - Adds a parallel data array to every `JitRuntime` shape,
    bloating the JitRuntime struct + `instantiateRuntime`
    bookkeeping. Bridge thunks live in a separate arena that's
    only allocated when ≥ 1 import resolves cross-module.
  - Loses the call-site uniformity for "host C fn vs Wasm
    cross-module fn" — host C fns don't need an
    rtptrs-array entry, so the resolver becomes "is this slot
    a C fn (skip rtptrs) or a Wasm fn (consume rtptrs)?"
    branching at instantiate time. Thunks make the call site
    uniform: every slot is just "indirect-call this address".
  - Caller-side emit needs to learn two new instructions and
    a new struct offset. Thunks change zero caller-side code.

### Alternative 3 — Per-instance pre-compiled thunk module (eager)

- **Sketch**: Same thunk shape as Alternative 1, but compile
  *every* possible thunk variant at instantiate time (one per
  import slot, regardless of whether the exporter has been
  registered yet). When `Store.register` runs later, patch the
  thunk's literals in-place.

- **Why rejected**:
  - Wasm 1.0 spec requires the importer's `(register ...)`
    targets to be registered **before** the importer is
    instantiated (the spec runner enforces this via wast
    directive order). So lazy compilation at instantiate time
    can always inspect the resolved exporter; no eagerness
    needed.
  - Eager compilation wastes thunk-arena space for imports
    that bind to host C fns (where no thunk is needed).
  - Patching mmap-ed RX memory in-place requires either an
    extra W writable mapping (double-map) or a `mprotect(...,
    PROT_READ | PROT_WRITE)` round-trip per `register` call.
    Lazy-compile-at-instantiate avoids the
    write-after-mmap-RX hazard entirely.

### Alternative 4 — Late-bind at call site (Wasmtime-style VMContext offsets)

- **Sketch**: Compile out per-import dispatch indirection
  entirely: at `instantiateRuntime` time compute the
  caller-import-idx → callee-instance-VMContext-offset mapping
  AOT and embed the resolved (rt, entry) constants directly
  into the importer's JIT body. Caller's `call N` for `N <
  num_imports` becomes a direct BL/CALL to the callee's entry.

- **Why rejected**:
  - Requires recompiling the importer's JIT body after the
    exporter is registered. Today's `instantiateRuntime` runs
    AFTER `compileWasm`, and the imports are already part of
    the produced byte stream (with `IMPORT_SENTINEL_OFFSET`
    sentinels). Re-emitting the import call site would mean
    keeping the JIT-emit pipeline addressable post-link, which
    is a much larger architectural change than this ADR.
  - Loses Wasm 1.0 spec idiom of late-binding: `(register
    "M" $inst)` after the importer is instantiated must still
    work (the spec testsuite uses this order in several
    fixtures). Wasmtime-style AOT-bake requires register
    before instantiate, which doesn't match the spec.
  - Wasmtime tolerates the AOT-bake because its module
    compilation phase is separate from instantiation. v2's
    JIT-first pipeline collapses both into `instantiateRuntime`,
    so AOT-bake would re-introduce a second compile phase.

## Consequences

- **Positive**:
  - Call-site emit (`op_call.zig`) is **unchanged**. Every
    chunk that previously consumed the `host_dispatch_base`
    indirect-call shape continues to work.
  - Per-call cost is the same as the existing host-import call
    (one indirect call + 3 register moves). The thunk adds a
    second indirect jump (BR/JMP) but no extra loads on the
    importer-side emit.
  - Thunk shape is **opcode-pinned** (4 ARM64 instructions / 3
    x86_64 instructions) — exactly the shape that the
    `audit_scaffolding §G.4` invariant-comment lint can sanity
    check without per-instance variation.
  - Bridge thunk arena is **per-instance**, so destroying the
    importer destroys its thunks cleanly. No global thunk
    registry; no GC needed.
  - Compatible with C-ABI host imports (slot points directly
    at the C fn) and Wasm-cross-module imports (slot points at
    a thunk) without a slot-side discriminator. The slot type
    stays `usize`.
- **Negative**:
  - New shared module `src/engine/codegen/shared/thunk.zig`
    (under [`shared/`](../../src/engine/codegen/shared/)) +
    per-arch sub-modules `arm64/thunk.zig` / `x86_64/thunk.zig`
    holding the encoder. Adds ~150 LOC per arch + ~100 LOC
    shared. Within the §A2 1000-LOC soft cap and well under
    the §14 hard cap.
  - Thunk arena allocation adds a per-`instantiateRuntime`
    `mmap(..., PROT_READ | PROT_EXEC, ...)` (or a sub-arena
    within the existing `JitModule.block`). Lifetime tied to
    instance lifetime; freed at instance destroy.
  - Per-thunk literal patching requires either:
    - A two-pass scheme (allocate thunk slot, then resolve +
      patch + mprotect-RX), or
    - A separate writable scratch arena that's `mremap`-ed RX
      after all thunks are emitted (one syscall, not per-
      import).
    The implementation chunks below pick the second.
  - Cross-arch thunk emitters must stay in step (W54 class).
    `audit_scaffolding §G.3` "Mac vs OrbStack thunk byte-shape
    parity" check goes on the post-implementation watchlist.
- **Neutral / follow-ups**:
  - **Implementation chunk plan** (each chunk is one commit;
    sequence per close-plan §6 step (c)-2):
    1. **(c)-2.1** — `shared/thunk.zig` skeleton + per-arch
       encoder unit tests. Lands the byte layout + the
       constant-poke API; no resolver wiring yet.
    2. **(c)-2.2** — `Instance`-level thunk arena allocation +
       `mmap` lifecycle. Plumbs the arena ptr into the
       `JitRuntime` shape (or a new sibling field, TBD by the
       implementer based on alignment constraints).
    3. **(c)-2.3** — Resolver wire-up in
       `instantiateRuntime`: walk imports, look up exporters
       in `Store.instances`, emit thunk per func import.
    4. **(c)-2.4** — spec_assert runner integration test: the
       smallest `(register ...)` + cross-module call fixture
       that exercises non-trivial callee behaviour (counter
       mutation / non-zero return). Expected: bit-identical
       Mac+OrbStack, +N PASS delta where N = number of
       previously-skipped `linking-Mf-call`-class assertions.
  - Host C function binding (`wasm_func_new_with_env` from
    wasm-c-api) reuses the same slot mechanism: slot points
    directly at the host fn pointer; the host fn already
    speaks the `fn(rt: *JitRuntime, ...) callconv(.c)` shape.
    No thunk allocation for that path. Wire-up is a separate
    sub-chunk under (c)-3 / (c)-4 (spectest host imports +
    other host bindings).
  - **D-079** (v128 cross-module imports, status `now` per
    ADR-0065 §9.9-III): the v128 result-class marshalling
    already works for cross-module-bound calls because the
    callee's RET goes straight to the importer's call site —
    the caller's `captureCallResult` reads V0 (ARM64) or
    XMM0 (x86_64) per the callee's signature, identical to
    a same-module call. (c)-2.4 includes one v128 fixture to
    verify.
  - **D-126** (`bulk.wast` call_indirect post-`table.copy` /
    `table.init` returns stale entries): orthogonal — the
    table-mutation path goes through `tables_jit_ci_ptr`, not
    through `host_dispatch_base`. ADR-0066 does not discharge
    D-126.
  - **D-138** (this ADR's seed): discharged when (c)-2.4
    lands and the prior naive-relaxation hang is replaced
    by working dispatch. Delete D-138 in the (c)-2.4 commit.

## Amendment §A1 (2026-05-17) — bridge thunk saves caller's pinned callee-saved register (D-142 fix (A))

### Why amend

D-142's 6-cycle investigation (lesson
[`2026-05-17-gamma3d-dispatch-write-segv-bisect.md`](../lessons/2026-05-17-gamma3d-dispatch-write-segv-bisect.md))
established that the original tail-call thunk shape adopted in
this ADR's `## Decision` § is **incorrect under v2's
callee-saved register pinning convention**. The auto-loaded rule
[`.claude/rules/abi_callee_saved_pinning.md`](../../.claude/rules/abi_callee_saved_pinning.md)
codifies the underlying principle; this amendment lands the
load-bearing ADR change that paired rule extraction warranted.

The original tail-call shape (BR X16 on arm64, JMP RAX on
x86_64) assumed the called function would preserve callee-saved
registers per AAPCS64 §6.4.1 / SysV §3.2.1. **It does not** —
v2's JIT prologue (per ADR-0017 sub-2d-ii on arm64; ADR-0026
Cc-pivot on x86_64) overwrites the pinned reg
(`runtime_ptr_save_gpr` = X19 on arm64, R15 on x86_64) with the
new `*JitRuntime` pointer at call entry, WITHOUT first
stack-saving the caller's value. This invariant is invisible
for same-module calls (caller_rt ≡ callee_rt, so the
"corruption" is a no-op) but **silently corrupts the caller's
pinned reg across cross-module bridge thunks** (caller_rt ≠
callee_rt). After the corrupted return, the importer's next
indirect dispatch via `[X19, #host_dispatch_base_off]` reads
the wrong rt's poisoned dispatch table — the Mac aarch64 SEGV
captured at fault address `0xAA...AA + 8 = 0xB2` was this
chain's terminal symptom.

D-142 fix (B) — landed `d543c646` 2026-05-17 — closed the
poison-sensitivity half of the chain (`SAFE_STUB_PTR_ADDR =
0x1000` replacing `undefined` field inits). Fix (A) below
closes the X19-corruption half by redesigning the bridge
thunk shape itself.

### Amended thunk shape — arm64 (~52 bytes, was 32)

Replace the original 4-instruction tail-call sequence with a
9-instruction call-and-return sequence that allocates its own
stack frame and saves the caller's X19 (= `runtime_ptr_save_gpr`)
before the callee can overwrite it:

```text
offset  encoding         disassembly
0x00    STP X29, X30, [SP, #-32]!     ; allocate 32-byte frame, save FP+LR
0x04    STR X19, [SP, #16]            ; save caller's X19 = caller_rt
0x08    ADR X16, .literals            ; X16 ← literal pool base (+24 from here)
0x0C    LDR X0,  [X16]                ; X0  ← callee_rt
0x10    LDR X16, [X16, #8]            ; X16 ← callee_entry
0x14    BLR X16                       ; CALL (not BR); LR ← post-BLR PC
0x18    LDR X19, [SP, #16]            ; RESTORE caller's X19
0x1C    LDP X29, X30, [SP], #32       ; restore FP+LR, pop frame
0x20    RET                           ; return to importer's call site
0x24    (padding, optional)           ; alignment to 8-byte literal boundary
.literals (at 0x28, 16-byte aligned via frame design):
0x28    .quad <callee_rt>
0x30    .quad <callee_entry>
```

`thunk_bytes` grows from `32` to `56` (9 instrs × 4 = 36 +
4-byte alignment pad + 16-byte literal pool). The literal pool's
position relative to the `ADR` at offset 0x08 is `+32` (since
literals start at 0x28 = ADR offset 0x08 + 0x20 = +32).

Why STR X19 at SP+16 specifically: the frame layout is `[SP+0]
= prev FP, [SP+8] = prev LR, [SP+16] = saved X19, [SP+24] =
unused (alignment)`. Slot 16 keeps the FP/LR pair contiguous at
the bottom (matching the AAPCS64 standard frame shape so a
stack unwinder can walk past the thunk frame) and leaves X19's
slot 8-byte-aligned without dirtying the LR's slot.

### Amended thunk shape — x86_64 (~24 bytes, was 22)

```text
offset  encoding         disassembly
0x00    PUSH R15                      ; save caller's R15 = caller_rt
0x02    MOV  RDI, <callee_rt imm64>   ; RDI = SysV arg0 (= *JitRuntime)
0x0C    MOV  RAX, <callee_entry imm64>; RAX = call target
0x16    CALL RAX                      ; SysV CALL (not JMP); saves return PC
0x18    POP  R15                      ; RESTORE caller's R15
0x1A    RET                           ; return to importer's call site
```

`thunk_bytes` for x86_64 grows from `22` to `27` bytes. (R15
is callee-saved per SysV §3.2.1, so the same pinning argument
holds; PUSH/POP R15 is the minimal preserve-restore on x86_64.
Win64 — when it lands per D-136 — follows the same shape but
the prologue must additionally allocate the 32-byte shadow
space per the Win64 calling convention; that is a follow-on
amendment scoped to D-136.)

### Why call-and-return, not "callee prologue saves X19"

Two alternative discharge paths exist (see
[`.claude/rules/abi_callee_saved_pinning.md`](../../.claude/rules/abi_callee_saved_pinning.md)
"Discharge patterns"):

- **Option B** (callee prologue saves pinned reg): every JIT
  function pays the cost. Pros: makes the v2 ABI fully
  AAPCS-compliant. Cons: 99 % of calls are same-module — the
  save/restore is pure overhead for the common case. Adds
  ~2 instructions to every function prologue.
- **Option C** (rename pinned reg to caller-saved scratch):
  substantial refactor of ADR-0017's pinning convention. Not
  chosen historically.

Option A (this amendment — bridge thunk pays the cost) is
correct because:

- **Cost paid only where divergence is possible** — only the
  bridge thunk knows caller_rt ≠ callee_rt is happening.
- **No prologue ABI break** — every JIT function's prologue is
  unchanged; existing same-module call paths remain at their
  current performance.
- **Localised blast radius** — the change is contained in
  `arm64/thunk.zig` + `x86_64/thunk.zig` (the two ~120-LOC
  files this ADR's `## Decision` § originally specified);
  same-module emission paths are not touched.

The cost ratio: a same-module call is roughly 10×–100× more
frequent than a cross-module bridge call in typical Wasm
modules (per the spec assertion corpus distribution), so
Option A pays the save/restore cost in the rare path where it
matters and avoids paying it in the common path where it
doesn't.

### Implementation sub-chunks (forward plan)

- **A.1** (this amendment) — ADR-0066 amend, no code change.
- **A.2** — arm64 thunk redesign: new `encStpPreIdxSp`,
  `encLdpPostIdxSp`, `encStrImmSp`, `encLdrImmSp`, `encBlr`
  encoders + `arm64/thunk.zig::emitThunk` rewrite + tests
  asserting the byte sequence above + `thunk_bytes = 56`.
- **A.3** — x86_64 thunk redesign: new `encPushReg`,
  `encPopReg`, `encCallReg` encoders + `x86_64/thunk.zig`
  rewrite + tests + `thunk_bytes = 27`.

After A.3 lands, γ-4 (relax `hasUnbindableImports` in
`test/spec/spec_assert_runner_base.zig`) can finally land —
the cross-module-on-Mac SEGV closes structurally and the
ubuntunote-side already-functional path is preserved.

### Consequences delta

- The original `## Consequences` § "Tail-call semantics
  preserve LR through BR" claim is **rescinded** for cross-
  module dispatch; the new thunk does a proper CALL/RET pair.
  Same-module call paths are unchanged.
- Cycle count per cross-module call grows from ~4 instrs
  (original) to ~9 instrs (amended) on arm64; ~3 instrs to
  ~6 instrs on x86_64. Cross-module calls are not on the
  bench's hot path in the current corpus (the
  spec-assertion runner exercises them O(1) per fixture
  module), so the perf delta is negligible at the gate scale.
- The new thunk requires the callee's prologue to leave FP/LR
  intact — it does (per ADR-0017 sub-2a/2d, every JIT
  function emits an FP-saving prologue). No prologue change
  needed.
- The thunk's own stack frame (32 bytes on arm64, 16 bytes
  on x86_64 via the PUSH alignment) is well-aligned to the
  ABI's SP-alignment requirement (16 on AAPCS64, 16 on SysV
  pre-call). Verified at A.2 / A.3 emit-byte tests.

### References — Amendment §A1

- D-142 (debt row, partial discharge — (B) landed
  `d543c646`).
- [`.claude/rules/abi_callee_saved_pinning.md`](../../.claude/rules/abi_callee_saved_pinning.md)
  — the auto-loaded rule capturing the cross-instance
  pinned-reg discipline.
- Lesson [`2026-05-17-gamma3d-dispatch-write-segv-bisect.md`](../lessons/2026-05-17-gamma3d-dispatch-write-segv-bisect.md)
  — full 6-cycle bisect chain.
- AAPCS64 §6.1.1 "Subroutine standard registers and their
  use" + §6.4.1 "Procedure call standard"
  (https://github.com/ARM-software/abi-aa/releases — Arm IHI
  0055).
- SysV AMD64 ABI §3.2.1 "Registers and the Stack Frame".

## Amendment §A2 (2026-05-18) — bridge thunk saves the full pinned reserved-invariant cohort (D-144 fix)

### Why amend

§A1 (2026-05-17) closed the X19 corruption half of the
cross-module bridge gap. D-144 (2026-05-18) surfaced that
§A1's fix was **necessary but not sufficient** — the same
"prologue overwrites a callee-saved register without first
stack-saving it" violation applies to **all six** of arm64's
reserved-invariant callee-saved registers, not just X19.

Per [`src/engine/codegen/arm64/abi.zig`](../../src/engine/codegen/arm64/abi.zig)
`reserved_invariant_gprs`, the cohort is:

- X19 — `runtime_ptr_save_gpr` (§A1-fixed)
- X24 — `typeidx_base` (table 0 — array of u32 typeidx values)
- X25 — `table_size` (W25, u32 count of entries)
- X26 — `funcptr_base` (table 0 — array of u64 funcptrs)
- X27 — `mem_limit` (linear-memory size in bytes)
- X28 — `vm_base` (linear-memory base pointer)

v2's arm64 prologue (per ADR-0017 sub-2d-ii + ADR-0018) loads
each of these from `*JitRuntime` in the entry sequence
without first stack-saving the caller's value. Like X19,
this is invisible same-module (caller_rt ≡ callee_rt) but
silently corrupts the caller's view across cross-module
bridge thunks.

The terminal symptom: `imports.1.wasm print64 i64:24` invoked
under γ-4 relax, after the cross-module call to imports.0's
`func-i64->i64` returned, observed `call_indirect (type
$func_f64) ... (i32.const 1)` trapping with **kind=3
(sig-mismatch)**. Root cause was caller's X24 still pointing
at the callee's (imports.0's) `typeidx_base` — a different
backing array than the caller's expected one. `typeidx_base[1]`
read read garbage; sig check failed; trap.

(The kind=3 vs kind=2 vs kind=1 disambiguation was made
possible by cycle 4's `JitRuntime.trap_kind` field + per-
fixup-class arm64 trap stubs — permanent diagnostic infra
landed alongside this amendment.)

### Amended arm64 thunk shape (96 bytes, was 56)

Extends §A1's save block from one STR (X19) to six STRs
(X19, X24, X25, X26, X27, X28). Frame grows 32 → 80 bytes
to accommodate the 48-byte save area.

```text
offset  encoding                          disassembly
0x00    STP X29, X30, [SP, #-80]!         ; alloc 80-byte frame, save FP+LR
0x04    STR X19, [SP, #16]                ; save caller's X19 = caller_rt
0x08    STR X24, [SP, #24]                ; save caller's X24 = typeidx_base
0x0C    STR X25, [SP, #32]                ; save caller's X25 = table_size
0x10    STR X26, [SP, #40]                ; save caller's X26 = funcptr_base
0x14    STR X27, [SP, #48]                ; save caller's X27 = mem_limit
0x18    STR X28, [SP, #56]                ; save caller's X28 = vm_base
0x1C    ADR X16, +52                      ; X16 ← literal pool (offset 0x50)
0x20    LDR X0,  [X16]                    ; X0  ← callee_rt
0x24    LDR X16, [X16, #8]                ; X16 ← callee_entry
0x28    BLR X16                           ; CALL
0x2C    LDR X19, [SP, #16]                ; RESTORE caller's X19
0x30    LDR X24, [SP, #24]                ; ... X24
0x34    LDR X25, [SP, #32]                ; ... X25
0x38    LDR X26, [SP, #40]                ; ... X26
0x3C    LDR X27, [SP, #48]                ; ... X27
0x40    LDR X28, [SP, #56]                ; ... X28
0x44    LDP X29, X30, [SP], #80           ; restore FP+LR, pop frame
0x48    RET                               ; return to importer
0x4C    (4-byte NOP pad to 16-byte align)
0x50    .quad callee_rt
0x58    .quad callee_entry
```

`thunk_bytes` arm64: `56` → `96` (19 instrs × 4 = 76 + 4-byte
pad + 16-byte literal pool). Frame layout: `[SP+0]=FP, [SP+8]
=LR, [SP+16]=X19, [SP+24]=X24, [SP+32]=X25, [SP+40]=X26,
[SP+48]=X27, [SP+56]=X28, [SP+64..72]=padding`.

### x86_64 — unchanged

The x86_64 thunk shape from §A1 (27 bytes, `PUSH R15 / MOV /
MOV / CALL / POP R15 / RET`) is **correct as-is**. Per ADR-0026
Cc-pivot, x86_64 pins only R15 (= runtime_ptr); other
invariants (vm_base / mem_limit / funcptr_base / table_size /
typeidx_base) are NOT in registers but reloaded from
`[R15 + offset]` at point of use. No additional callee-saved
register pinning, so no §A2 extension needed.

This asymmetry (arm64 saves 6 regs, x86_64 saves 1) reflects
the two architectures' different invariant-reservation
strategies. §A2 documents it explicitly so future readers
don't infer x86_64 has an analogous gap.

### Sibling-search discipline (lesson)

§A1's fix at X19 alone, missing X24-X28, repeated the same-
shape-cohort failure mode that `.claude/rules/bug_fix_survey.md`
exists to prevent. The lesson
[`2026-05-18-thunk-pinned-cohort-not-just-x19.md`](../lessons/2026-05-18-thunk-pinned-cohort-not-just-x19.md)
captures the discipline gap: when fixing one member of a
structural cohort (here: pinned-callee-saved regs), grep for
sibling members of the same axis before landing the fix. The
audit grep `grep reserved_invariant_gprs
src/engine/codegen/arm64/abi.zig` would have surfaced X24-X28
at §A1 time.

The auto-loaded rule
[`abi_callee_saved_pinning.md`](../../.claude/rules/abi_callee_saved_pinning.md)
is updated alongside §A2 to enumerate the full cohort (X19 +
X24..X28) so future thunk-shape edits cannot re-miss the
sibling set.

### References — Amendment §A2

- D-144 (the surfacing fail; row removed at closure 2026-05-18).
- Lesson [`2026-05-18-thunk-pinned-cohort-not-just-x19.md`](../lessons/2026-05-18-thunk-pinned-cohort-not-just-x19.md).
- Updated rule [`abi_callee_saved_pinning.md`](../../.claude/rules/abi_callee_saved_pinning.md).
- Closure commit `6dd40adef` (thunk 56 → 96 bytes + JitRuntime
  trap_kind field + per-fixup-class arm64 trap stubs).
- [`src/engine/codegen/arm64/abi.zig`](../../src/engine/codegen/arm64/abi.zig)
  `reserved_invariant_gprs` — single source of truth for the
  pinned-cohort list (the §A2 fix is a 1-to-1 mirror).

## References

- ROADMAP §9.9-III (Cat III absorption per ADR-0065)
- Related ADRs:
  - [`0017_jit_function_call_marshalling.md`](0017_jit_function_call_marshalling.md)
    — original ABI for in-module calls; this ADR extends the
    cross-module path without changing the in-module path.
  - [`0023_zone_split_post_phase_6.md`](0023_zone_split_post_phase_6.md)
    — Zone layering; `engine/codegen/shared/thunk.zig` lives
    in Zone 2 (`engine/`).
  - [`0027_globals_runtime_pointer_strategy.md`](0027_globals_runtime_pointer_strategy.md)
    — runtime-ptr reservation strategy that the thunk's X0
    swap relies on.
  - [`0049_per_chunk_gate_host_subset.md`](0049_per_chunk_gate_host_subset.md)
    — 2-host (Mac + OrbStack) gate discipline; (c)-2 chunks
    follow it.
  - [`0056_phase9_scope_extension_to_wasm2_full.md`](0056_phase9_scope_extension_to_wasm2_full.md)
    — 4-category exit predicate.
  - [`0065_wasm_1_0_instance_work_phase9_rescope.md`](0065_wasm_1_0_instance_work_phase9_rescope.md)
    — Cat III absorption.
- External:
  - Wasm 1.0 core spec §4.5 (Instances, Stores, Imports,
    Linking).
  - AAPCS64 (Arm IHI 0055) §6.4 call sequence; tail-call via
    `BR` preserves the link register from the caller's BL.
  - System V AMD64 ABI §3.2.3 calling convention; tail-call
    via `JMP` preserves RIP from the caller's CALL.
- Lessons:
  - [`2026-05-17-cross-module-noop-stub-controlflow-hang.md`](../lessons/2026-05-17-cross-module-noop-stub-controlflow-hang.md)
    (D-138 case study; the failure mode this ADR addresses).
- Debt:
  - D-138 (filed 2026-05-17, discharged at (c)-2.4 landing).
  - D-079 (v128 cross-module imports, sub-gap ii) —
    incidentally covered by (c)-2.4's v128 fixture.
- Phase-9 close plan: [`../phase9_close_plan.md`](../archive/phase9/phase9_close_plan.md)
  §6 step (c) — the umbrella for this ADR's implementation.

## Revision history

| Date       | SHA          | Note                                                                                                                       |
|------------|--------------|----------------------------------------------------------------------------------------------------------------------------|
| 2026-05-17 | `b0f3ec4f` | Initial accepted version (Phase 9 §9.9-III (c)-2 design).                                                                  |
| 2026-05-17 | `4e7a4646` | Amendment §A1 — bridge thunk shape extended to save caller's pinned callee-saved reg (X19 on arm64, R15 on x86_64) per D-142 fix (A). Tail-call shape rescinded for cross-module dispatch; same-module call paths unchanged. |
| 2026-05-18 | `6dd40adef`   | Amendment §A2 — arm64 bridge thunk extended from §A1's X19-only save to the full reserved-invariant cohort (X19 + X24..X28; thunk 56 → 96 bytes) per D-144 fix. x86_64 unchanged (R15 is the only pinned invariant per ADR-0026; other invariants reload from `[R15+off]` at use). Paired infra: `JitRuntime.trap_kind` field + per-fixup-class arm64 trap stubs (`kind=1` generic / `kind=2` cind bounds / `kind=3` cind sig) — permanent diagnostic infra enabling the §A1 → §A2 root-cause localisation. |
