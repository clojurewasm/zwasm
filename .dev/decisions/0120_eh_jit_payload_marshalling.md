# 0120 — JIT payload-marshalling shape for EH throw → catch propagation

- **Status**: Accepted (2026-05-28 — cycle 90 D5/D6 revision + autonomous flip per user direction "完成形がきれい" framing)
- **Date**: 2026-05-28
- **Author**: zwasm-from-scratch loop
- **Tags**: phase-10, exception-handling, codegen, abi

## Context

ADR-0114 D1 codified the runtime `Exception` extern struct with
inline payload (`payload: [*]Value`, `payload_len: u32`,
`param_count: u32`), and D6 codified the `zwasm_throw` thread-
local trampoline that stores `(tag, params, fp_at_throw,
pc_at_throw)` into a thread-local Exception slot before invoking
the FP-walk unwind.

What ADR-0114 did NOT specify is the **JIT-emitted byte sequence**
at the throw site and the catch landing pad that moves payload
values between the regalloc operand stack and the thread-local
Exception object. The integration plan
(`.dev/phase10_eh_integration_plan.md` §IT-3) flagged this as an
open design question:

> IT-3's payload marshalling shape: stack-region for N>2 payloads,
> or heap-Exception object? ADR-0114 D1 picked inline payload for
> the interp; codegen has more flexibility. Recommend: same inline
> shape for ABI symmetry.

The current state (HEAD `f37977df`): throw.emit marshals tag_idx
into W0/RDI and calls the trampoline; catch landing pad PC is
recorded in `HandlerEntry.landing_pad_pc` but the JIT emits no
code at that PC that pushes the payload onto the catch block's
operand stack. End-to-end probe with a 1-param tag confirms the
silent payload-drop: `throw $e0 (i32.const 88)` caught by
`catch $e0` → catch block reads stack and returns 0 (uninitialized
slot), not 88.

This ADR codifies the choice so the IT-3 / IT-2 follow-on impl
cycles can proceed without re-litigating the design.

## Decision

**Per-Runtime payload buffer pre-sized at instantiate time** (no
magic cap; cleanly admits v128 + exnref). Throw-side store, catch-
side load via runtime-pointer offset.

Cycle-90 revision: the original draft proposed a hardcoded
`[16]u64` inline buffer (v1-zwasm precedent). The survey under
`completed-design-form` lens (wasmtime: heap GC object; wazero
wazevo JIT: heap `[]uint64` slice; v1 zwasm: `[16]u64` inline)
found three considerations the v2 design should integrate:

- **No magic cap**: spec defines no max payload arity; the cap
  is implementation-side. Pre-computing `max_arity` at instantiate
  time gives an exact fit without arbitrary 16-slot limit.
- **v128 admissibility**: a tag with `(param v128)` needs 16 bytes
  per slot. Slot-counting in u64-units (`v128 = 2 slots`) keeps
  the buffer uniform-stride without requiring an `[N]u128` layout.
- **exnref reification**: `catch_ref` / `catch_all_ref` semantics
  produce an opaque exnref handle; lazy heap-allocate on the
  catch_ref path (rare relative to plain `catch`) — keeps the
  common-throw fast path zero-allocation.

1. **Per-Runtime field** (Zone 1, `src/runtime/runtime.zig`):
   ```zig
   /// EH payload staging region — written by JIT throw sites
   /// (each pops N vregs and stores them here, slot-counted in
   /// u64 units: i32/i64/f32/f64 = 1 slot, v128 = 2 slots), read
   /// by JIT catch landing pads (load each value back, push as
   /// fresh vregs into the catch block's operand stack).
   ///
   /// Slice pointer + len are pre-sized at instantiate time:
   /// `eh_payload.len == sum(tag.param_slot_count for each tag)`.
   /// The slice is stable for Runtime lifetime; the JIT can
   /// literal-pool the pointer once per compile.
   eh_payload: []u64 = &.{},
   eh_payload_len: u32 = 0,
   ```

   Slot width = `u64`. Per-tag param-slot encoding rules:
   - i32 / i64 / f32 / f64 / funcref / externref → 1 slot
   - v128 → 2 slots (low 8 bytes at index `i`, high at `i+1`)
   - exnref → not in v0.1 tag params; rejected at module-load
     time when `(tag $t (param exnref))` declared.

2. **Throw-site emit shape** (per-arch
   `src/engine/codegen/{arm64,x86_64}/ops/wasm_3_0/throw.zig`):
   ```text
   For each i in [0, N): pop vreg, store value at
   [runtime_ptr + eh_payload_buf_off + i*8]
   Store N at [runtime_ptr + eh_payload_len_off]
   MOV tag_idx into argreg-0 (existing IT-3 step 2)
   BLR / CALL trampoline (existing)
   ```

   N = `tag_param_counts[tag_idx]` — read from EmitCtx at emit
   time (compile-time-known per ZirFunc's referenced tag-section
   data; threaded from CompiledWasm.tag_param_counts through
   EmitCtx.InitArgs).

   For N=0 (e.g., the existing IT-6 `throw $e1 → catch $e1
   returns 77` test's `(tag $e1)` shape), the payload-write loop
   degenerates to a single `STR Wzr` for `eh_payload_len = 0`;
   the regalloc operand stack is undisturbed.

3. **Catch-landing-pad emit shape** (synthesized by
   `op_exception_handling.try_table.emit` at the per-catch
   landing_pad_pc — i.e., immediately after the `end` of the
   try_table block, before the catch's target-block body):
   ```text
   For each i in [0, N): LDR W/X, [runtime_ptr + eh_payload_buf_off + i*8]
   → STR into next available regalloc spill slot (push as fresh vreg)
   For catch_ref / catch_all_ref: additionally LDR exnref pointer
   from thread-local Exception slot + push as a fresh vreg
   ```

   N = same `tag_param_counts[tag_idx]` for `catch_` /
   `catch_ref`; N=0 for `catch_all` / `catch_all_ref`.

4. **EmitCtx threading**: add `tag_param_counts: []const u32 =
   &.{}` field to per-arch EmitCtx (mirrors `globals_offsets` +
   `memory0_idx_type` default-empty pattern). Initialised by
   `compile()` from `CompiledWasm.tag_param_counts`. Default-empty
   keeps all 36+ existing EmitCtx call sites behaviour-preserving;
   only EH-touching paths consult it.

5. **Invariant** (mechanised via `comment_as_invariant.md` + a
   debug-assert in `instantiate()`): `eh_payload.len ==
   sum(slot_count(tag.params)) for tag in module.tag_section`.
   No magic cap; the slice is precisely sized at instantiate.
   ADR-0114 D1's `Exception.payload` inline cap is a separate
   ABI invariant (interp side); the JIT-side `eh_payload` slice
   is shape-decoupled from interp's inline buffer.

6. **D5 — v128 slot accounting**. At module-load time, compute
   `tag_param_slot_counts[i] = sum(slot_count(p) for p in
   tag[i].params)` where `slot_count(v128) = 2`, others = 1. The
   JIT emits N stores at throw site (N = slot count, NOT param
   count). The catch landing pad emits N loads + a per-slot type
   demux: for v128 params, the catch prelude loads 2 consecutive
   u64 slots into a single v128 vreg (`LDP X.., X..` arm64 / two
   `MOV` + shuffle on x86_64). The runtime-side `eh_payload` is
   uniformly `[]u64`; v128 demultiplex is JIT-side only.

7. **D6 — `catch_ref` / `catch_all_ref` exnref reification**.
   When the JIT compiles a `try_table` that has any `_ref`-suffixed
   catch clause, the catch landing pad additionally calls the
   `zwasm_reify_exnref` runtime helper which:
   - Heap-allocates an `Exception` object (per ADR-0114 D1 shape)
     via the Runtime arena allocator.
   - Copies tag_idx + the live `eh_payload[0..N]` slots into the
     allocation.
   - Returns the `*Exception` as a 64-bit handle, pushed as a new
     vreg onto the regalloc operand stack.

   Allocation cost is paid only on the `_ref` path (rare relative
   to plain `catch`); plain catch path stays zero-allocation. The
   exnref is GC-traceable per ADR-0114 D2.

   When no `_ref` clauses appear in any `try_table` of any
   compiled function, the `zwasm_reify_exnref` symbol is not
   referenced and DCE'd from the runtime binary.

## Alternatives considered

- **A. Stack region per try_table** — reserve N words just below
  the try_table's `fp + frame_bytes` boundary; throw writes,
  catch reads. Rejected: requires the throw emit to know which
  enclosing try_table the throw lies in at emit time (currently
  determined by the unwinder at dispatch time via the
  ExceptionTable PC range lookup); the throw doesn't have
  per-try_table frame metadata at emit. Forcing this would
  pessimise the existing IT-6 trampoline path's "throw-site is
  PC-only" invariant.

- **B. Per-Exception heap payload** (mirror wasmtime's
  `Exception` heap object). Rejected: heap allocation on every
  throw breaks ADR-0114's "throws should be on par with
  bounds-trap dispatch latency" target; zwasm v2's per-Runtime
  arena gives a sub-cycle pointer-bump alternative, but then the
  throw site must call into the runtime to claim a payload slot
  rather than writing to a fixed buffer — extra dispatch overhead
  with no benefit when payloads are bounded by N ≤ 16.

- **C. Pass payload via dispatcher argregs**. Rejected: dispatcher
  is a Zig function with fixed signature (`dispatchThrow(table,
  code_map, site, max_depth)`); extending it to varargs-per-N
  payloads would force per-N specialisations OR
  in-band-with-tag_idx packing. Both worse than the dedicated
  buffer.

## Consequences

1. **Bundle-friendly impl ordering**: the cycle sequence is
   - Cycle 1 (this bundle's first impl chunk after the ADR
     lands): add `eh_payload_buf` + `eh_payload_len` fields to
     `Runtime`; add `tag_param_counts` field to EmitCtx;
     thread through `compile()`. Same-cycle observability via a
     unit test that constructs Runtime + verifies the fields'
     default zero/empty state.
   - Cycle 2: throw.emit reads `tag_param_counts[tag_idx]`,
     emits the pop+store sequence (arm64 first; x86_64 follows
     same cycle bundled per the established arch-symmetry
     rhythm).
   - Cycle 3: try_table.emit synthesizes the catch-landing-pad
     prologue (load payload values + push to regalloc operand
     stack). Same cycle: end-to-end test `throw + catch_ with
     i32 payload returns 88` (currently silent-drops, returns 0).
   - Cycle 4: catch_ref / catch_all_ref exnref push. Builds on
     the interp 10.E-exnref-b path's exnref dispatch shape.
   - Cycle 5: spec-corpus runner wiring + close 10.E.

2. **Throws with N=0 tags pay zero extra emit cost**: the
   per-i loop has 0 iterations; the `STR Wzr` for
   `eh_payload_len = 0` is 4 bytes per throw site. Net delta on
   the existing `throw + catch_all returns 42` IT-6 test: +4
   bytes per throw, no semantic change.

3. **v128 admissible from v0.1** (D5): a tag with `(param v128)`
   is supported through the 2-slot encoding. catch landing pad's
   v128 demux is 2 LDR + an arm64 INS or x86_64 PINSRQ; the JIT
   emit handler treats v128 as the natural extension of the
   uniform-slot pattern.

4. **exnref reification on-demand only** (D6): `catch_ref` /
   `catch_all_ref` allocates an Exception object lazily on the
   catch path; plain `catch` stays zero-allocation. The
   `zwasm_reify_exnref` runtime helper symbol is DCE'd from
   builds with no `_ref` clauses in any compiled function.

5. **Thread-locality**: `eh_payload` is a per-`Runtime` field,
   not thread-local. v2's current single-threaded model makes
   this safe; multi-threaded guests (Phase 14+) need per-thread
   payload bufs paired with the per-thread Exception slot, but
   the slice-shape stays the same — just promoted to a
   `[*]ThreadLocal` lookup.

6. **Industry alignment** (cycle-90 survey-informed): the v2
   slice-shape JIT emit (`STR [runtime_ptr + payload_ptr_off +
   i*8]` after dereferencing the slice pointer) matches wazero
   wazevo JIT's `[paramsPtr + i*8]` shape exactly. The only
   difference is wazero stores the pointer in execCtx then
   dereferences per access; v2 stores the pointer in Runtime
   then dereferences per access. Equivalent emit + same
   industry-precedent.

## References

- ADR-0114 D1 (Exception extern struct + inline payload cap=16)
- ADR-0114 D6 (zwasm_throw thread-local trampoline)
- ADR-0119 (naked-Zig trampoline impl shape)
- `.dev/phase10_eh_integration_plan.md` §IT-3 (open question)
- `.dev/phase_log/phase10.md` §10.E-N-1 / §10.E-5c (interp-side
  precedent for payload pop + push via tag_param_counts)
- `src/runtime/runtime.zig:205-213` (existing
  `tag_param_counts` field)
- `src/engine/runner.zig:170` (CompiledWasm.tag_param_counts)
- `src/engine/codegen/shared/exception_table.zig:51`
  (HandlerEntry shape — landing_pad_pc consumes this ADR's emit
  sequence)
- `.dev/lessons/2026-05-28-spec-corpus-expansion-exhausted.md`
  (cycle-88 survey identifying ADR-0120 as one of three forward
  gates)
- Industry survey (cycle 90): wasmtime Cranelift (GC-heap
  Exception, `cranelift/src/func_environ/gc/enabled.rs:540-635`);
  wazero wazevo JIT (`internal/engine/wazevo/frontend/lower.go:
  3445-3525`, `[paramsPtr + i*8]` JIT shape — v2's structural
  precedent); WAMR interpreter (operand-stack-windowed, no JIT
  EH); v1 zwasm (`Vm.pending_exception [16]u64`, interp only).

## Revision history

| Date | Commit | Notes |
|------|--------|-------|
| 2026-05-28 | `73845cf0` | Initial Proposed (D1-D4 fixed [16]u64). |
| 2026-05-28 | `510eca36` | Accepted + D5 (v128 slot accounting) + D6 (exnref reification) added per cycle-90 industry survey. Decision body revised from `[16]u64` magic-cap to `[]u64` pre-sized at instantiate; "完成形がきれい" lens applied — no arbitrary cap, v128 admissible from v0.1, exnref reification lazy on _ref path only. |
