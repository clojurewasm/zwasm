# 0018 — Adopt explicit regalloc reserved set + first-class spill

- **Status**: Accepted
- **Date**: 2026-05-04
- **Author**: Shota / autonomous loop
- **Tags**: regalloc, jit, abi, phase7

## Context

`src/jit_arm64/abi.zig` documents X24..X28 as caller-supplied
invariants ("NOT in the regalloc pool"), but the implementation:

```zig
pub const allocatable_gprs = caller_saved_scratch_gprs ++ callee_saved_gprs;
// = X9..X15 ++ X19..X28  (17 slots)
```

includes them. `slotToReg` exposes X26..X28 as slots 14..16. The
W54 post-mortem singled out **doc/impl divergence as the root
cause class** of v1's hardest bugs; this is the same pattern.

ADR-0017 introduces a structurally different runtime ABI (X0 =
`*const JitRuntime`, prologue loads X28..X24 once per function),
which removes the *caller-supplied* version of the invariants.
But the **regalloc pool still needs explicit reservation** because
the prologue's LDRs land into X24..X28 and the body's loads use
them as live values; if the regalloc allocates X24..X28 to a vreg
on top of those invariants, the body silently misexecutes.

Additionally, `slotToReg` currently returns `null` on
out-of-pool slot id, which the §9.7 / 7.3 emit pass treats as
`Error.SlotOverflow`. The 17-slot pool happens to be enough for
all current MVP fixtures, but this is **structural luck, not
design**. As realworld fixtures + spec-testsuite execution land,
the >12-vreg case will arrive and the JIT will hard-error rather
than spill.

## Decision

### Reserved invariant register set (per-arch)

Declare `reserved_invariant_gprs` in `abi.zig` as a load-bearing
constant, and define `allocatable_gprs` strictly as the
complement.

ARM64:
```zig
pub const reserved_invariant_gprs = [_]Xn{ 24, 25, 26, 27, 28 };
pub const allocatable_gprs =
    caller_saved_scratch_gprs        // X9..X15  (7)
 ++ [_]Xn{ 19, 20, 21, 22, 23 };     // X19..X23 (5)
// Pool size: 12.
```

x86_64 (ADR-0019, sketch):
```zig
pub const reserved_invariant_gprs = [_]Xn{ /* RDI plus runtime-derived equivalents */ };
pub const allocatable_gprs = /* System V caller-saved + callee-saved minus reserved */;
```

The shared `regalloc.compute` consults `slotToReg` — already
arch-aware — so the regalloc body itself does not change.
Per-arch tables shift; the algorithm stays.

### First-class spill

`regalloc.Allocation` grows a spill side-table:

```zig
pub const Slot = union(enum) {
    reg: u8,             // index into allocatable_gprs / allocatable_v_regs
    spill: u32,           // byte offset within the function's spill frame
};

pub const Allocation = struct {
    slots: []const Slot,  // per-vreg (was: []const u8 of slot ids)
    n_reg_slots: u8,      // distinct register slots used (renamed from n_slots)
    n_spill_bytes: u32,   // total spill-frame bytes (8-aligned)
};
```

**Breaking change**: today `Allocation.slots` is `[]const u8`
(slot ids resolved via `slotToReg`) and `n_slots` is the count.
After ADR-0018, slots becomes a tagged union and the count
splits into reg vs spill components. Every emit handler that
reads `alloc.slots[v]` and feeds the result to `slotToReg` must
match on the `Slot` tag instead. ~70 sites in `emit.zig` (one
per `slotToReg` / `fpSlotToReg` call). Implementation cycle adds
the migration; the change is mechanical.

The greedy-local algorithm:
1. Try to assign a free register from the allocatable pool.
2. If no register is free, allocate a spill slot at the next free
   8-byte offset within the function's spill frame.

`emit.compile` consumes both:
- For `Slot.reg`, current logic.
- For `Slot.spill`, emit `STR` after def + `LDR` before each use,
  staging through a scratch reg.

**Scratch-reg conflict warning**: §9.7 / 7.3 sub-g3c
(call_indirect bounds + sig check) already uses X16/X17 mid-op
(W17 = idx → X17 = funcptr; W16 = loaded typeidx). Naïvely
reusing X16/X17 as the spill stage reg inside those handlers
would clobber the in-flight values. The spill machinery must
either (a) reserve a third scratch slot for spill use only, or
(b) declare an emit-pass invariant that op handlers never call
into spill helpers between their X16/X17 setup and final use.
Option (a) costs 1 reg from the pool (down from 12 to 11); (b)
costs review discipline. Recommend (a) for safety; e.g. add X15
to the reserved set for spill-stage use, leaving 11 in the
allocatable pool. Decision deferred to the implementation
cycle, but the option is named here.

Frame layout extends:
```
[old SP]           ← caller's SP
FP   ←--+
LR      |
spill_0 |  prologue extends frame: SUB SP, SP, #(num_locals*8 + spill_bytes)
spill_1 |
...     |
local_0 |
local_1 |
new SP  ←--+
```

Spill region is below FP, locals below spill (or vice versa, design
choice — recommend spills above locals so the existing locals-
addressing imm12 displacement stays small for hot paths).

### Documentation + ruleset

- `abi.zig` doc reflects pool ↔ reserved separation.
- `.claude/rules/single_slot_dual_meaning.md` gains a checklist
  item: "When introducing a register reservation, did you remove
  it from the regalloc pool?"
- `audit_scaffolding` skill §F (debt + lessons coherence) gains a
  spot-check: `for r in reserved_invariant_gprs: assert r not in allocatable_gprs`.

## Alternatives considered

### Alternative A — Keep current pool, document the limit

- **Sketch**: Pool stays X9..X15+X19..X28 (17 slots). Document
  "do not allocate ≥14 vregs" and call it a precondition.
- **Why rejected**: precondition that grows-with-realworld is a
  silent-correctness trap. The W54 lesson rejects this class.

### Alternative B — Move invariants to caller-saved (X9..X15)

- **Sketch**: Invariants live in X9..X15 instead of X24..X28.
  Body reloads from `*X0` after every call (since calls clobber
  caller-saved).
- **Why rejected**: per-call reload defeats the prologue-once
  pattern; memory hot paths now have an LDR before every memory
  op if the function calls anything in between.

### Alternative C — Spill everything beyond reg pool (no reserved)

- **Sketch**: Don't reserve anything; have every Wasm function
  re-load runtime invariants from a global TLS or
  per-thread context.
- **Why rejected**: TLS load on every memory op is a 5-10 cycle
  hit; defeats Phase 7 "interpreter dispatch + JIT body" cold-
  start parity.

## Consequences

### Positive

- **Doc and impl agree by construction**. Changing
  `reserved_invariant_gprs` propagates automatically to
  `allocatable_gprs`.
- **W54-class regression class structurally closed** for this
  particular case. Pattern generalisable: any future "reserved
  for X" reg goes in `reserved_invariant_gprs`.
- **Spill makes 14+ vreg functions correct**. Realworld
  Wasm has plenty of these (TinyGo guests routinely use 30+
  locals).
- **Regalloc verify() can assert** `allocatable_gprs ∩ reserved_invariant_gprs == ∅`.

### Negative

- **Pool shrinks 17 → 12 slots**. Functions with 8-12 vregs that
  previously fit will still fit. Functions with 13+ now spill
  (correct behavior, was previously silently wrong).
- **Spill machinery code volume**: ~200-300 lines added across
  regalloc.zig + emit.zig. Worth it for correctness.
- **Spill instructions slow the body**: STR/LDR per spilled vreg
  per use. Phase 15 (optimisation) can do live-range splitting
  + better allocation; today's greedy-local is intentionally
  simple per ROADMAP §2 (P3 cold-start).

### Neutral / follow-ups

- **Spill order policy**: spills above locals vs below. Pick
  "spills directly below FP, locals below spills" for now.
- **8-byte vs typed spill width**: store all GPR vregs as 8-byte
  even for i32. V regs need 16-byte for v128 once SIMD lands
  (Phase 8). Today GPR + V both 8-byte (V regs use scalar
  STR S/D forms).
- **Spill heuristic**: greedy assigns first-free; a future ADR
  may specify "reuse spill slot when live ranges allow"
  (linear-scan with reuse).

## References

- ROADMAP §2 (P3 cold-start, P13 W54-class regression prevention,
  P7 backend equality — operationalised within Phase 7 by ADR-0019)
- ROADMAP §14 forbidden list (single-slot-dual-meaning)
- W54 post-mortem (`~/Documents/MyProducts/zwasm/.dev/archive/w54-redesign-postmortem.md`)
- Related ADRs: 0017 (JitRuntime ABI — pairs with this),
  0019 (x86_64 in Phase 7 — defines the x86_64 reserved set)
- `src/jit/regalloc.zig`, `src/jit_arm64/abi.zig`,
  `src/jit_arm64/emit.zig` (today's pool / impl)
- `.claude/rules/single_slot_dual_meaning.md`

## Revision history

- 2026-05-04 — Proposed. SHA: `<backfill at acceptance>`
