# No single slot serving two semantic axes

Auto-loaded when editing Zig source. Codifies the design lesson
captured by ROADMAP §14's "Single field serving two distinct
semantic axes" forbidden-list entry. Per ADR-0014 §6.K.5.

## The rule

When designing a struct whose fields are read by behaviour-
distinguishing code paths, **never let one field carry two
distinct semantic meanings**. Split into one field per axis from
day 1, even when the values happen to coincide for current
opcodes / shapes / fixtures.

> If two callers each read the same field for a *different*
> reason, those callers will eventually disagree about what the
> field should hold. Splitting per axis turns "different
> reason" into "different field" at compile time.

## The case study — `Label.arity` / `Label.branch_arity`

`src/interp/mod.zig:Label` carries two arities, not one:

```zig
pub const Label = struct {
    height: u32,
    arity: u32,         // pop-count for the matching `end`
    branch_arity: u32,  // pop-count for `br` to this label
    target_pc: u32,
};
```

The two values **happen to coincide** for `block` and `if` (both
are the blocktype's result count) but **disagree for `loop`**:

- `loop` (Wasm 1.0) — `arity = result_count`,
  `branch_arity = 0` (a `br` to a loop transfers params, of
  which there are none in 1.0).
- `loop (result T)` (Wasm 2.0 single-result) —
  `arity = 1`, `branch_arity = 0`. The `tinygo_fib` fixture's
  `loop (result i32)` body landed iter 5–11 of §9.6 / 6.E with
  the wrong dispatch because the original single `arity` field
  was being read by both `endOp` (wanted `1`) and `brOp`
  (wanted `0`). The fix (commit `7b26760`) split the field
  along the per-axis line; the rule re-derives the same
  decision at design time so future opcodes don't re-introduce
  the merge.

The same pattern arose previously and is documented at:
- `~/Documents/MyProducts/zwasm/.dev/archive/w54-redesign-postmortem.md` —
  v1's regalloc-stage IR shape implicitly assumed an absent
  liveness invariant; symptoms looked like "x86 broke" until the
  shared interpretation was unwound.

## Why this is a §14 forbidden pattern

Both v1 and v2 spent debugging cycles on this class of bug.
The W54 post-mortem and the iter-11 underflow share the
shape: one slot, two readers, two semantics, silent
interpretation drift. ROADMAP §14's entry exists to make
the rejection load-bearing during reviews.

## Reviewer checklist (apply during Step 4 Refactor / pre-commit)

- [ ] For each new struct field of type `u32` / `u64` / `usize` /
      `Value`-shaped, ask: is more than one caller reading it for
      a **different reason**?
- [ ] If yes, do those reasons stay synonymous across **every
      opcode / shape / spec proposal you can name**? If you can
      name even one case where they'd diverge, split the field.
- [ ] If the field's name reads like a noun without modifier
      (`size`, `count`, `arity`, `flags`, `kind`), suspect double
      duty until proven otherwise.
- [ ] If the diff "happens to need both readers to use the same
      value," document the coincidence with a comment OR split
      and let the comment be the field name.

## When the merge is genuinely safe

The rule is not "never reuse a field." It targets shared values
across **distinct semantic axes**. A counter loop variable read
by every iteration is not a violation; that's one axis. A
`u8` enum tag read by every switch arm is not a violation;
that's one axis. The trigger is "two readers expect different
values from the same slot."

## Forbidden patterns this rule rejects

- One `arity` field consumed by two opcodes that each want a
  different count (`Label.arity` pre-iter-11).
- One `flags` byte where one bit's meaning depends on another
  bit (instead, split into named bools / packed sub-struct).
- One `Value` slot used as both a typed numeric and a funcref
  pointer outside the discriminated-union (`Value` extern
  union) shape that already separates them.
- One opcode `payload: u32` used as both an immediate value AND
  a typed-index AND a section offset — pick one per opcode and
  document; if a single opcode genuinely needs two, split into
  `payload` + `extra` (which `ZirInstr` already does).

## Forbidden phrases in commit messages / ADR text

- "the same field is reused" — reads as a CON; the rule says it
  IS a CON.
- "for now we share `X`" — for-now sharing reliably becomes
  permanent sharing; pay the field-split cost on the day the
  shape is touched, not later.
