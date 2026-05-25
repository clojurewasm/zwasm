# 0114 — Exception Handling design: tag identity + FP-walk unwind + 2-edge callsite

- **Status**: Accepted (2026-05-25; Phase 10 / 10.D ADR round close)
- **Date**: 2026-05-25
- **Author**: claude (autonomous loop, /continue prep path)
- **Tags**: exception-handling, wasm-3.0, codegen, unwind, tag-identity,
  Phase 10 / 10.E
- **Paired ROADMAP row**: §10 / 10.E (impl), §10 / 10.D (this ADR's Accept gate)
- **Co-landed with**: ADR-0111 / 0112 / 0113 / 0115..0117 (Phase 10 / 10.D round)

## Context

The Wasm 3.0 exception-handling proposal introduces `try_table` /
`throw` / `throw_ref` / `tag` declarations + the `exnref` value
type. The proposal ships in production: emscripten-EH-enabled C++,
.NET Wasm AOT, and SpiderMonkey / V8 use the construct. ROADMAP §10
calls for EH land at row 10.E with this ADR Accepted at row 10.D.

The design follows `phase10_design_plan_ja.md` §3.4 — industry
references:

- **wasmtime** (`crates/wasmtime/src/runtime/vm/exception_handling.rs`
  + `crates/cranelift/src/translate/exceptions.rs`): 6-array
  per-callsite exception table (handler PCs + tag pointers + caught
  flags + stack-depth deltas + caller-saved-restore masks +
  locals-rewrite list). FP-walk unwind across the frame chain;
  Mac aarch64 / Linux x86_64 / Win64 share the same emit shape
  (NOT SEH for caught exceptions; SEH only for OS-level traps).
- **wasmer** (`lib/types/src/trap.rs` + the singlepass EH glue):
  similar shape; per-callsite table with handler-PC × tag pairs.
- **wasm3** does NOT implement EH (interp-only; skips proposal).
- **zwasm v1**: NO existing EH support — Phase 10 is first-touch.

Two correctness invariants drive the design:

1. **Tag identity is reference-equal, not structural.** Wasm spec
   §4.5.5 `tag.matching` is `tag_addr_a == tag_addr_b`; two
   structurally-identical tags imported from different modules
   are distinct exceptions. wasmtime's `*TagInstance` pointer is
   the canonical implementation; zwasm follows.

2. **`try_table` itself emits ZERO instructions.** The entry is
   pure metadata; control transfer happens only via `throw` or
   normal fall-through. wasmtime + wasmer both validate this
   via emit golden snapshots. zwasm follows via
   `emit_test_eh.zig` (snapshots try_table = empty diff).

EH is co-designed with ADR-0113 (callsite_metadata 3-axis) because
exception edges are a specialisation of the N-successor axis: a
`try_table` entry produces a Callsite with 1 normal-return edge +
N landing-pad edges (one per tag clause).

## Decision

Land EH with the following design choices (9 decisions per
`phase10_design_plan_ja.md` §3.4):

1. **`feature/exception_handling/` directory** (Zone 1 — runtime):
   ```
   tag.zig         — TagInstance heap object + import/export resolve
   exception.zig   — extern struct Exception (payload + tag pointer)
   register.zig    — try_table / throw / throw_ref dispatch register
   ```
   The runtime `Exception` is an `extern struct` (ABI-stable):
   ```zig
   pub const Exception = extern struct {
       tag: *TagInstance,
       payload: [*]Value,
       payload_len: u32,
       param_count: u32,
   };
   ```

2. **`engine/codegen/<arch>/op_exception_handling.zig` new** (per
   arch: aarch64 + x86_64). NOT bundled into op_call.zig — the
   emit shape differs structurally (throw needs unwind trampoline
   entry; try_table emits zero bytes).

3. **`engine/codegen/shared/exception_table.zig` new** — consumes
   ADR-0113's `Callsite` shape as a 2-edge specialisation:
   ```zig
   Callsite {
       pc: u32,
       edges: [
           CallsiteEdge { .kind = .normal_return,         target_pc, live_ins },
           CallsiteEdge { .kind = .exception_landing_pad, target_pc, live_ins },
       ],
   }
   ```
   For try_table with N tag clauses, the edge array grows to
   N+1 entries (1 normal + N landing-pad). Shares per-Instance
   arena storage with bounds_fixups (refactored to 1-edge per
   ADR-0113 D6).

4. **regalloc N-successor axis** (per ADR-0113 D3) — `op_try_table.zig`
   declares `pub const n_successor_edges: u8 = 1 + N_tag_clauses;`
   (computed at lower time from the parsed try_table body). Per-op
   constant only for catch-all shape; per-callsite N filled at
   the regalloc table population point.

5. **FP-walk unwind** — `engine/codegen/shared/unwind.zig` new.
   Cross-platform: Mac aarch64 / Linux x86_64 / Win64 use the
   SAME frame-chain walker (FP register conventions are spec-
   defined per-ABI; the walk algorithm is platform-agnostic).
   Algorithm:
   ```
   pc = current_throw_site
   fp = current_frame_pointer
   loop:
       handler = lookup_handler(pc, throw.tag)  // exception_table walk
       if handler != null: jump handler.target_pc with payload
       (caller_fp, caller_pc) = load_frame_chain(fp)
       if caller_fp == null: emit "uncaught exception" trap
       fp = caller_fp
       pc = caller_pc
   ```
   **Win64 SEH is NOT used for caught exceptions** (per
   ADR-0103, SEH is only for OS-level trap-recovery). EH uses
   FP-walk on all three hosts to keep the unwind path uniform.

6. **`zwasm_throw` thread-local trampoline** — one assembly stub
   per arch (`engine/codegen/<arch>/throw_trampoline.{zig,s}`).
   Stores `(tag, params, fp_at_throw, pc_at_throw)` into
   thread-local Exception slot, then invokes the FP-walk unwind.
   Decoupled from the Trap (signal/VEH) dispatcher:
   - Trap: signal/VEH → dispatcher → caller frame epilogue → host trap
   - Throw: software `zwasm_throw` → FP-walk → try_table landing
     pad OR uncaught-exception trap
   - **Invariant** (`comment_as_invariant` comptime assert):
     try_table-caught exceptions are Exception-class only — never
     a Trap. The dispatcher entry-points are distinct symbols;
     comptime asserts that `op_try_table.zig`'s catch path
     references only the Throw dispatcher.

7. **Tag identity via `*TagInstance` pointer equality** —
   cross-module day-1. Two tags imported into module B from
   module A's export resolve to the SAME `*TagInstance` pointer
   (the import-binding step copies the pointer, not the struct).
   Two structurally-identical tags from independent modules
   yield distinct pointers → distinct exception classes.
   `tag_a.ptr == tag_b.ptr` is the runtime match operator. No
   `wasmtime context-SP-offset` indirection needed (zwasm uses
   per-Runtime arena → pointer is stable for the Runtime's
   lifetime).

8. **wasm-c-api tag accessor extension** — `include/wasm.h:252-296`
   already declares the spec-side: `wasm_tagtype_t` opaque +
   `wasm_tagtype_params` / `wasm_tagtype_results` /
   `wasm_tagtype_delete` accessors + `wasm_tagtype_as_externtype`
   conversion. Phase 10 implements these in `src/api/tag.zig` (new
   file under existing api/ structure). Host C code can:
   - declare a tag via `wasm_tagtype_new(params, results)`
   - import a tag into a module via the standard `wasm_extern_t`
     import-vector mechanism
   - throw a tagged exception from a host func via a new
     `wasm_throw(store, tag, args)` (extension beyond spec).

9. **exnref lifetime** — `exnref` value type stores `?*Exception`
   pointer. Per-Runtime arena allocation; collected by GC
   walker (ADR-0115 / 0116 — GC roots include exnref-typed
   locals + stack slots). For Wasm builds without GC
   (`-Dwasm=v3_0 -Dgc=false`), exnref is rejected at parse
   time with a clear diagnostic ("exnref requires -Dgc=true").

## Alternatives considered

- **A. Win64 SEH-based unwind for caught exceptions** (use
  RaiseException + __try/__except). Rejected: ADR-0103 reserves
  SEH for OS-level trap-recovery (signal-equivalent); using it
  for Wasm-throw conflates two dispatchers + breaks the
  comptime-asserted invariant that catch-paths see only
  Exception-class. FP-walk is identical-shape across hosts.

- **B. Tag matching via structural hash** (canonicalise tag
  signatures; matching = hash equality). Rejected: violates
  spec §4.5.5 (tag identity is reference, not structural). A
  module importing `(tag (param i32))` from two distinct sources
  expects two distinct exception classes; structural hash collapses
  them.

- **C. Bundle EH ops into op_call.zig** (try_table extends call's
  emit shape with extra edge fields). Rejected: per
  `single_slot_dual_meaning` rule (§14), one file owning call +
  try_table accumulates implicit-coupling drift. The 1-file split
  cost is bounded; the drift cost is unbounded.

- **D. Separate `exception_table.zig` storage** (NOT consuming
  ADR-0113's Callsite shape; keep EH's table independent). Rejected:
  the data shape (PC → edges → live-in regs) is identical between
  bounds_fixups / try_table / GC stack-map. ADR-0113 forces
  unification at design time precisely to prevent this drift.

## Consequences

**Positive**:

- Wasm 3.0 `exception-handling/test/core/*.wast` (4 wast / 76
  assertion) green at 3-host gate after impl.
- Cross-module exception propagation works day-1 (pointer equality
  is naturally cross-module).
- emscripten-EH-enabled C++ realworld fixtures
  (`realworld/p10/emscripten_eh/`) pass at impl-close.
- Zero-instruction try_table emit (verified by `emit_test_eh.zig`
  golden snapshot) → no fast-path regression on EH-using modules
  that take the normal-return edge.
- Unwind path uniform across Mac aarch64 / Linux x86_64 / Win64
  → single audit surface; no per-host SEH/dwarf2 dialect.

**Negative**:

- New file count: `op_exception_handling.zig` (×2 arch),
  `exception_table.zig` (shared), `unwind.zig` (shared),
  `throw_trampoline.{zig,s}` (×2 arch), `feature/exception_handling/`
  (3 files: tag.zig + exception.zig + register.zig). ~7 new
  files; ~800 LOC estimate.
- Thread-local Exception slot adds 32 bytes per thread; bounded.
- exnref + GC interdependency: ADR-0114 ships only when ADR-0115/0116
  ship; `-Dgc=false` exnref reject is a hard requirement, not a
  defer-path.
- Per-Instance exception_table storage grows linearly with
  try_table-clause count × call density. Acceptable per design
  plan §3.4 (per-Instance arena absorbs the cost).

## Removal condition

This ADR retires when EH ships at ROADMAP §10 / 10.E `[x]`, with
all nine decisions above implemented:

- `exception-handling/test/core/*.wast` (4 wast / 76 assertion)
  green at 3-host gate.
- `emit_test_eh.zig` golden verifies try_table = 0-byte emit.
- `test/runners/eh_frequency_runner.zig` matrix (throw rate
  0/1/50/100% × catch depth 1/10/100) shows no hot-path
  regression (0% throw rate matches baseline within 1%).
- `realworld/p10/emscripten_eh/` fixtures green.
- `cross_module_throw_propagation.wat` edge case verifies day-1
  cross-module tag identity.
- `trap_not_caught_by_try_table.wat` edge case verifies the
  Exception-vs-Trap dispatcher separation (comptime invariant
  holds at runtime too).

At that point status transitions to `Closed (Implemented)` with
the impl SHA range cited.

## References

- `phase10_design_plan_ja.md` §3.4 — full design spec (source of
  truth; this ADR codifies the decisions).
- WebAssembly exception-handling proposal:
  https://github.com/WebAssembly/exception-handling
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/vm/` —
  6-array per-callsite exception table + FP-walk unwind
  (industry precedent).
- `~/Documents/OSS/wasmtime/crates/cranelift/src/translate/stack.rs:570-575`
  (`pub struct HandlerState { handlers: Vec<(Option<ExceptionTag>,
  Block)> }`): wasmtime's per-try-table handler list with
  `Option<ExceptionTag>` (None = catch_all). Direct precedent
  for zwasm v2 `ExceptionTable.HandlerEntry { tag_idx: ?u32 }`
  shape (10.E-codegen-1; null = catch_all). Comment at line
  566-569 explicitly notes the LIFO-flatten optimisation:
  "the LIFO stack of try_table's with left-to-right scans
  within a table" — same insertion-order discipline as zwasm
  v2 `Builder.add` (10.E-codegen-1).
- `~/Documents/OSS/wasmtime/crates/cranelift/src/translate/stack.rs:468-475`
  (`pub(crate) fn push_try_table_block(... checkpoint:
  HandlerStateCheckpoint ...)`): wasmtime threads a checkpoint
  through nested try_table blocks so handler-state restoration
  on block-exit is LIFO-correct. zwasm v2 mirror: the
  per-function `ExceptionTable.Builder` accumulates handlers
  across nested try_tables; the insertion-order-wins lookup
  achieves the same nested semantics without an explicit
  checkpoint stack.
- `~/Documents/OSS/wasmtime/crates/wasmtime/src/runtime/exception.rs:36-43`
  (`pub struct ThrownException` — opaque "error type *without*
  payload"; payload stored via `host_data_table` indirection):
  wasmtime stores throw payloads separately from the error
  marker. Direct contrast with zwasm v2's `Exception { tag_idx,
  payload_len, payload[16]Value }` inline-payload shape
  (`feature/exception_handling/exception.zig` D1). zwasm v2
  trades the indirection for a fixed-size payload cap (16
  values; matches per-tag param-count cap) per ADR-0114 D1.
- `~/Documents/OSS/wasmtime/crates/cranelift/src/translate/code_translator.rs:633`
  (`try_table.catches.iter().rev()`): already cited in ADR-0117
  References — wasmtime processes catch clauses in REVERSE
  order to unify within-table left-to-right matching with
  inside-out nested-try_table semantics. zwasm v2's
  `Builder.add` insertion-order matches this.
- `~/Documents/OSS/WebAssembly/exception-handling/test/core/` —
  4-wast / 76-assertion spec corpus (consumed at 10.E close).
- `include/wasm.h:252-296` — wasm-c-api spec tag accessor
  surface (this ADR implements; no extension to header).
- ADR-0103 — Win64 SEH usage policy (this ADR's decision §5
  abides; EH uses FP-walk, not SEH).
- ADR-0113 — callsite_metadata (this ADR's exception_table
  consumes the 2-edge specialisation).
- ADR-0115 / 0116 — GC (exnref reachability via GC roots;
  co-designed).
- ADR-0117 — GC × EH × TC integration invariants
  (gc_x_eh_thrown_ref_rooted.wat etc; co-designed).
- ROADMAP §14 — single_slot_dual_meaning forbidden list (this
  ADR's decision §2 + §3 abide).

## Revision history

- 2026-05-26 — References enrichment via /continue autonomous
  prep path. Added 4 concrete wasmtime citations: cranelift
  stack.rs:570 (HandlerState `Vec<(Option<ExceptionTag>, Block)>`
  mirror of zwasm v2 HandlerEntry.tag_idx nullable shape),
  stack.rs:468 (`push_try_table_block` checkpoint threading vs
  zwasm v2 Builder.add insertion-order), wasmtime exception.rs:36
  (`ThrownException` payloadless vs zwasm v2 inline-payload
  contrast per ADR-0114 D1), code_translator.rs:633
  (`try_table.catches.iter().rev()` cross-ref with ADR-0117).
  No semantic change to the design.
- 2026-05-25 — Initial draft via /continue autonomous prep path
  (per `.claude/skills/continue/SKILL.md` §"Autonomous prep
  paths for user-gated ADRs"). Status: Proposed pending user
  collab review at 10.D. Co-drafted in the 10.D ADR round
  alongside ADR-0111 / 0112 / 0113 / 0115..0117 (over multiple
  /continue cycles per the 7-ADR scope).
- 2026-05-25 — Status: Proposed → **Accepted** (user collab 4/7).
  All 9 decisions accepted. Enhancement: the Trap (signal/VEH)
  vs Throw (software `zwasm_throw`) dispatcher-separation
  invariant (decision §6) gets banked into
  `.claude/rules/no_workaround.md` (or a new dedicated
  `p10_eh_dispatcher_separation.md`) as a load-bearing rule —
  so future "便利だから SEH 流用" drift is caught structurally,
  not only by the comptime assert in `emit.zig`. Concretely:
  the rule's stale-ness check ensures that the catch-path
  symbol set never references the Trap dispatcher's entry-point.
