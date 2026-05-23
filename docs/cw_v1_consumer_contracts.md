# CW v1 consumer contracts — enforceable rails for Phase A-F

**Date**: 2026-05-24 cycle 37 (post-CW-v1 deep feedback review)
**Source**: `~/Documents/MyProducts/ClojureWasmFromScratch/private/notes/zwasm_v2_feedback.md`
(CW v1 private; gitignored on their side)
**Status**: Active rail for Phase A-F execution
(`.dev/phase9_remaining_flow.md`). Each contract item maps
to a specific Phase sub-step gate + verification path.
**Audience**: zwasm v2 future-self executing Phase A-F.
Read this BEFORE touching code that any contract gates.

## §0 — Why this doc

CW v1 (ClojureWasmFromScratch `cw-from-scratch` branch)
submitted a deep consumer review of zwasm v2's
`docs/zig_api_design.md` (ADR-0109 spec) on 2026-05-24.
Their review surfaced **3 ★必須 contracts + 6 answered
open questions + 2 long-term commitments + 1 persistence
requirement** that, if not enforced during Phase A-F
execution, will silently drift and break the CW v1
dogfooding contract.

This doc enumerates each contract, maps it to the Phase
sub-step where drift risk peaks, and specifies the
verification mechanism. **The list is load-bearing**:
Phase A-F execution must honor every item, or file an
ADR for any explicit deviation.

## §1 — ★必須 contracts (3 items)

### C-1 — `*const FuncEntity` is `align(8)`

**What**: Every `FuncEntity` allocation in zwasm v2 must
land at an 8-byte-aligned address. Reason: CW v1 NaN-box
2nd-generation uses **shifted pointer (`>> 3`)** to compress
44-bit heap pointers (4 group × 16 sub-type = 64 NaN slots,
47-bit effective address space). If `FuncEntity` isn't
align(8), CW v1 cannot inline `funcref` into Group D NaN
slot; falls back to heap-indirect wrapper (= 1 extra slot
+ 1 extra dereference per funcref op).

**Where drift risk**:
- Phase A.4d (JitRuntime extern struct field offsets) —
  any change to FuncEntity allocation path
- ADR-0014 zombie-instance arena allocation (FuncEntity
  is arena-allocated)
- Future Wasm 3.0 GC types that may share allocation
  pattern with FuncEntity

**Gate**:
- Phase A.4d sub-step: **audit current FuncEntity alloc
  for `align(8)` guarantee**. If guaranteed by arena
  allocator: no change. If not: add `align(8)` annotation
  or migrate allocation site.
- Phase A.5 verification: add `comptime
  std.debug.assert(@alignOf(FuncEntity) >= 8)` at
  FuncEntity type declaration site.
- Phase F ADR-0109 amend: spec §4.1 explicitly states
  "FuncEntity is `align(8)` so its address fits NaN-boxing
  shifted-pointer encoding (`>> 3`)".

**Future expansion**: CW v1 may require `align(16)` (`>>
4`) for later NaN layout. Currently scoped to Phase 5-15
of CW v1; revisit before Phase 16+. zwasm v2 should NOT
preemptively widen to align(16) — wait for CW v1
explicit request.

### C-2 — `Trap` error set has stable 12 variants as ABI

**What**: The 12 trap variants currently in
`src/runtime/trap.zig::Trap` (Unreachable, IntOverflow,
IntDivByZero, InvalidConversionToInt, OutOfBoundsLoad,
OutOfBoundsStore, OutOfBoundsTableAccess,
UninitializedElement, IndirectCallTypeMismatch,
StackOverflow, CallStackExhausted, OutOfMemory) are an
**ABI commitment**. CW v1 Phase 16 entry will map each 1:1
to a CW v1 error_catalog Code; variant addition/removal
breaks the mapping.

**Where drift risk**:
- Phase 10 Wasm 3.0 GC / EH may introduce new trap
  variants (e.g. for null-ref dereference, exception
  trapped past handler)
- Phase A internal refactor accidentally renaming or
  removing a variant
- Any cycle that touches `src/runtime/trap.zig`

**Gate**:
- Phase A.5 verification: assert variant set matches the
  list above (`grep -c '^\s*\(Unreachable\|IntOverflow\|...\),' src/runtime/trap.zig`
  → 12).
- Add header comment to `src/runtime/trap.zig` Trap enum:
  ```
  // ABI-stable variant set (CW v1 consumer contract per
  // docs/cw_v1_consumer_contracts.md §1 C-2). Additions
  // require an ADR; removals are forbidden until v0.2.
  ```
- Future Wasm 3.0 trap additions: file an ADR amending
  this contract, with explicit "added variants: ..." +
  "compatible with existing 12 variants: yes" rationale.
  Notify CW v1 maintainer via project_facts pin.

### C-3 — `Engine.init(alloc, ...)` allocator strict-pass to ALL internal allocations

**What**: The `alloc` passed to `Engine.init` must back
every internal allocation in zwasm v2 (module metadata,
function table, instance state, JIT-emitted code's runtime
data, anything). No hidden `c_allocator`, no
globally-bound fallback, no thread-local fallback. On
`Engine.deinit`, every allocation must be freed (CW v1 GC
leak detection is strict).

**Where drift risk**:
- Phase A.4f c_api Val simplification — current c_api
  veneer hard-codes `c_allocator` at `wasm_engine_new`;
  Phase A.4f must NOT propagate this pattern
- Phase F native Zig API impl — the rewrite is where
  allocator strict-pass is materially achieved; must NOT
  accidentally introduce fallback
- JIT runtime alloc (if any dynamic alloc happens at JIT
  execution time, must go through the same `alloc`)
- Test code that uses `testing.allocator` is fine
  (tests are not consumer-facing)

**Gate**:
- Phase A.4f sub-step: **grep for `c_allocator` in
  src/api/ + src/runtime/** — any hits get audited.
  Acceptable: tests, comments, explicit "Debug-only"
  paths. Forbidden: hot-path or library-internal alloc.
- Phase A.5 verification: grep `c_allocator` + `page_allocator`
  + `heap.GeneralPurposeAllocator()` in src/, validate
  each hit against the rule.
- Phase F ADR-0109 implementation: explicit per-allocation
  trace through Engine → Module → Instance → ... → JIT
  scratch demonstrating allocator threading. Add to
  ADR-0109 §Decision as a load-bearing commitment.
- Add `scripts/check_allocator_strict_pass.sh` (Phase 5
  later cycles) as a lint to grep `c_allocator` etc. and
  fail on non-exempted hits.

## §2 — Answered open questions (6 items)

CW v1 provided recommended answers to the 6 open questions
in `docs/zig_api_design.md` §6. These should be reflected
in spec doc + ADR-0109 during Phase F (when actually
implementing the native Zig API).

| # | Original question | **CW v1 answer (zwasm v2 adopts unless ADR overrides)** | When to bake in |
|---|---|---|---|
| Q1 | multi-result shape: anonymous tuple vs named struct | **named struct default**, anonymous tuple continues | Phase F impl + spec §3.3 amend |
| Q2 | Caller first arg of host funcs: required vs optional | **optional** (default: not received; explicit `*Caller` first param if needed) | Phase F impl + spec §3.2 amend |
| Q3 | `mem.slice()` invalidation: snapshot vs growth-tracking | **snapshot** (Wasm spec aligned; re-fetch at call boundary) | Phase F impl + spec §3.4 amend |
| Q4 | WasiConfig granularity: bulk `defineWasi(cfg)` vs per-syscall | **bulk default, per-syscall opt-in** | Phase F impl + spec §3.8 amend |
| Q5 | TypedFunc cache lifetime: re-lookup after defineFunc vs stable | **stable across Instance lifetime** (defineFunc is pre-instantiate only) | Phase F impl + spec §2 (TypedFunc) clarification |
| Q6 | Ref-typed args: `?u64` raw vs typed wrappers | **typed wrappers** (`FuncRef` / `ExternRef` thin structs; internal repr `?u64` w/ 0 sentinel) | Phase F impl + spec §4.1 amend |

**Gate**: Phase F (post-Phase-9) ADR-0109 Revision history
entry must reflect each Q1-Q6 decision. Spec doc updates
land alongside.

## §3 — Long-term commitments (2 items)

### L-1 — `Instance.invoke(name, args, results)` long-term support

CW v1 calls Wasm functions from Clojure where signatures
are only known at runtime (= dynamic dispatch). TypedFunc
is comptime-only and unusable for this path. Therefore:

- `invoke` is NOT a transitional API; it's a **first-class
  long-term surface**. Not deprecated in favor of typed
  paths.
- Signature mismatch error (`ArgTypeMismatch` /
  `ResultTypeMismatch`) should carry **signature info in
  the error context** (CW v1 translates these to Clojure
  exception messages).

**Gate**: Phase F spec §3.5 amend with explicit
"long-term commitment" language + error context spec.

### L-2 — Shared memory default isolated, opt-in shared

CW v1 wants `default isolated, opt-in shared` as sandbox
policy. Concretely:
- If Wasm module declares `(import "env" "memory" ...)`
  but linker doesn't define it, `instantiate` MUST error
  (= CW v1 can enforce "default separate memory" by
  not calling `linker.defineMemory`).
- Cross-instance sharing only via explicit
  `linker.defineMemory("env", "shared_mem",
  inst_a.memory().?)`.

**Gate**: Phase F spec §3.7 amend with explicit isolation
default + instantiate-time error spec.

## §4 — Persistence + cross-references (1 item)

### P-1 — CW v1 feedback ↔ zwasm v2 sync mechanism

CW v1 feedback is gitignored on their side. zwasm v2 needs
a discoverable persistence path so the feedback survives
session boundaries on both sides.

**Done in this commit**:
- This doc (`docs/cw_v1_consumer_contracts.md`) codifies
  the contracts.
- `handover.md` MUST-read includes this doc as #4.
- `.dev/phase9_value_widen_plan.md` Phase A.5 references
  the §1 verification list.

**Pending (Phase F)**:
- ADR-0109 Revision entry adding "Consumer feedback
  honored" section pointing at this doc.
- CW v1 side may pin a `project_facts.md` F-008 entry
  referring back to this doc.

## §5 — Co-existence with c_api veneer (CW v1 §6 confirmation request)

CW v1 may run early prototypes against the current c_api
veneer before Phase F native Zig API rewrite completes.
This requires:

- **Current c_api veneer (`src/api/instance.zig`) stays in
  tree**. Phase F rewrite ADDS native Zig API; does NOT
  delete c_api binding.
- **c_api veneer remains functional through Phase A-F**
  (Phase A.4f's "simplify c_api Val" is scope-limited;
  shouldn't break consumer-facing wasm-c-api contract).
- **Migration path documented**: when Phase F ships, CW v1
  prototypes built against c_api can migrate to native Zig
  API one component at a time (Engine, then Module, then
  Instance).

**Gate**: ADR-0109 (already Accepted) explicitly states
c_api remains as Zone-3 sibling. Phase F implementation
preserves c_api binding; verification at Phase F merge.

## §6 — Verification checklist (Phase A.5 sub-step)

Add to Phase A.5 (cope code removal verify) as additional
checklist:

```
□ C-1: comptime assert @alignOf(FuncEntity) >= 8 added
□ C-2: Trap variant count == 12 (grep verify); header
       comment added
□ C-3: grep c_allocator / page_allocator in src/api/ +
       src/runtime/ — all hits accounted (test-only or
       comment); no production-path leakage
□ L-1: invoke API remains in spec (not removed)
□ L-2: shared memory default isolated (linker behavior
       defaulted to error on undefined memory import)
□ P-1: this doc + handover pointer + plan reference all
       coherent
□ §5: src/api/instance.zig intact + functional
```

Phase A.5 cannot close without every box ticked. Failure
of any box requires either fix-in-same-chunk or ADR
amendment documenting the deviation.

## §7 — When to update this doc

- **Phase A-F finds a contract is structurally impossible
  to honor**: amend this doc + file ADR explaining the
  exception + notify CW v1 maintainer.
- **CW v1 sends additional feedback** (subsequent revision
  of `zwasm_v2_feedback.md`): merge into corresponding
  section here + bump Date in this doc header.
- **Phase F ADR-0109 implementation amends ADR-0109**:
  cross-reference the amend in §2 / §3 sections of this
  doc.
- **Wasm 3.0 GC / EH adds trap variants**: per C-2 process,
  file ADR + amend this doc + notify CW v1.

## §8 — Revision history

- 2026-05-24 — Initial draft at cycle 37, post-CW-v1
  feedback review. Codifies CW v1 feedback as
  enforceable Phase A-F contracts. Wired into
  `phase9_value_widen_plan.md` Phase A.5 + handover MUST-read.

## §9 — References

- Source: `~/Documents/MyProducts/ClojureWasmFromScratch/private/notes/zwasm_v2_feedback.md`
  (CW v1 side; gitignored)
- [`docs/zig_api_design.md`](./zig_api_design.md) — spec
  doc that CW v1 reviewed
- [`docs/runtime_deep_comparison.md`](./runtime_deep_comparison.md)
  — industry audit referenced by CW v1 §2 evaluation
- [`.dev/decisions/0109_native_zig_api_inversion.md`](../.dev/decisions/0109_native_zig_api_inversion.md)
  — ADR-0109 (Proposed); Phase F amend will codify the
  §2 answered questions and §3 commitments
- [`.dev/decisions/0110_value_widen_to_16_byte.md`](../.dev/decisions/0110_value_widen_to_16_byte.md)
  — ADR-0110 (Accepted); Phase A execution honors §1
  contracts (C-1 in A.4d, C-3 in A.4f, all in A.5)
- [`.dev/phase9_value_widen_plan.md`](../.dev/phase9_value_widen_plan.md)
  — Phase A playbook; §6 verification checklist gates
  Phase A.5 close
- [`.dev/phase9_remaining_flow.md`](../.dev/phase9_remaining_flow.md)
  — Phase A-F overview; this doc is the enforcement
  rail layer
