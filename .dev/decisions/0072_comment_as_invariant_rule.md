# 0072 — Comment-as-invariant rule

- **Status**: Accepted
- **Date**: 2026-05-19
- **Author**: continue loop §9.12 substrate audit cycle
- **Tags**: phase-9, hygiene, rules, comment-discipline, regression-prevention

## Context

The D-132 / D-133 family (arm64 `op_table.zig` hardcoded `X10` / `X11` / `X12`
scratch registers) surfaced a recurring failure mode in zwasm v2: **invariants
written in prose comments without code-level enforcement drift silently as the
codebase grows**. The specific D-132 lineage:

- `op_table.zig` carried a comment stating "X10/X11/X12 are private scratch
  within the handler" — authoritative-looking, but unenforced.
- regalloc independently treated the same physical register slots as
  allocatable scratch (the `allocatable_caller_saved_scratch_gprs` set in
  `abi.zig` overlapped).
- A specific combination — nested table-op + cross-module table.copy + corpus
  pressure (d-63 / d-64) — produced silent register corruption.
- Bisect time: weeks. The prose invariant looked like documentation; reading
  it carefully (vs reading `abi.zig`'s allocatable set) was the bisect's
  late breakthrough.

The lesson `.dev/lessons/2026-05-16-regalloc-pool-scratch-overlap.md` recorded
this as a "comment-as-invariant" anti-pattern. The Phase 9 completion substrate
audit (Q5) escalated it to a formal rule. Repeat failures of the same shape
elsewhere in the codebase:

- `funcref` encoding in `instance/funcref.zig` carries a "high 16 bits are
  always the originating-module instance index" prose invariant — unenforced
  until ADR-0044's encoding-check landed.
- `spill_aware_check` discipline was prose-only until `scripts/spill_aware_check.sh`
  was added as a gate; multiple cycles had landed code violating the prose.
- The "Wasm-1.0-only ZirOp slot N is unused in Wasm 2.0" comments in
  `validator.zig` decayed silently as Wasm 2.0 ops were assigned to those slots.

Each instance of the failure mode pays the same cost: prose claims an
invariant; readers trust the claim; code drifts; the bug surfaces under
specific stress; bisect is expensive because the prose was authoritative-
looking and was not where the bug lived.

## Decision

Introduce a project rule **`.claude/rules/comment_as_invariant.md`**
(auto-loaded on `src/**/*.zig` editing). The rule body:

> **When writing a prose invariant (a statement of the form "X is always Y" /
> "X is private scratch for Z" / "X has alignment N" / "X is owned by Y"),
> the invariant MUST be paired with at least one of:**
>
> (a) A `comptime assert` (compile-time check at the declaration site)
>
> (b) A runtime `std.debug.assert` (boundary check at the first use site)
>
> (c) A lint / grep script in `scripts/` and registered in `audit_scaffolding §G`
>
> (d) Deletion (= the invariant isn't load-bearing; the comment is removed)
>
> **Forbidden**: a prose invariant in a docstring or `//` comment with no
> mechanical enforcement. Such comments are deemed "false documentation" —
> they create reader trust without underlying integrity.

### Reference catalog of violation examples + fixes

The rule cites these as illustrative:

| Violation site | Prose claim | Mechanical fix |
|---|---|---|
| `src/engine/codegen/arm64/op_table.zig` (pre-D-133) | "X10/X11/X12 are private scratch within the handler" | Named constants in `abi.zig` (`table_emit_scratch_gprs: [3]GprId`) + comptime disjointness check `comptime { for (table_emit_scratch_gprs) ‖r‖ assert(!isMemberOf(allocatable_caller_saved_scratch_gprs, r)); }` |
| `src/runtime/instance/funcref.zig` (pre-ADR-0044) | "High 16 bits are always the originating-module instance index" | Encoding helper `pub fn encode(instance_idx: u16, table_idx: u32) FuncRef { ... }` plus `decode(...)` checking high-bit zeros; comptime-assert mask shapes |
| `src/validate/validator.zig` (multiple pre-Phase-9) | "Slot N is unused in Wasm 2.0" | Comptime check inside `dispatch_collector.zig`: `comptime { if (op.wasm_level == .v1_0 and reserved_for_wasm_2_0.contains(op)) @compileError(...); }` |
| `src/runtime/instance/store.zig` (pre-Cat-III) | "This slot is owned by the originating module's Store" | Wrap the slot in a thin `Owned<T>` type carrying an owner-instance handle; runtime `assertOwnedBy(self, instance)` at boundary |

### Enforcement landings (§9.12-C)

- **`.claude/rules/comment_as_invariant.md`** — auto-load rule, expanded from
  the existing skeleton.
- **`audit_scaffolding §G` grep extension** — extend the grep set to detect
  hardcoded register numerals in op_table / op_memory and unenforced
  invariant-shape comments. Pattern: `grep -nE '// .* (always|private|owned by|alignment N)' src/`
  cross-referenced against assertion presence.
- **D-133 sweep** — convert hardcoded `X10` / `X11` / `X12` references in
  `op_table.zig` / `op_memory.zig` to named-constant references; add
  `abi.zig` comptime disjointness check covering all op-internal scratch
  arrays (`table_emit_scratch_gprs`, `memory_emit_scratch_gprs`, plus future
  arrays for Wasm 3.0 ops).
- **`bug_fix_survey.md` reinforcement** — when a bug is fixed by adjusting an
  invariant comment, the `/continue` Step 4 checklist requires identifying
  sibling sites with the same comment shape (this is the discipline gap that
  let D-132's sibling sites at `emitMemoryInit` / `emitDataDrop` go untouched
  in the original D-132 fix).

### Scope — what is and isn't an "invariant"

**Is** (rule applies):

- Statements about ownership ("X is owned by Y")
- Statements about layout ("X is at offset N", "high N bits are always Z")
- Statements about uniqueness / disjointness ("X / Y / Z never overlap")
- Statements about thread / signal safety ("X is async-signal-safe")
- Statements about lifetime ("X lives until Y returns")

**Isn't** (rule does not apply):

- Explanatory comments about *why* a particular implementation choice was
  made ("we use PSHUFB here because the Cranelift recipe uses POR — see
  ADR-NNNN")
- Pointers / cross-references ("see also `foo.zig`", "per Wasm spec
  §4.5.2")
- TODO / FIXME / WIP markers (these are explicit non-invariants)
- Section delimiters / file-scope comments not making invariant claims

## Alternatives considered

### Alternative A — Strict "no prose invariants ever" rule

- **Sketch**: forbid all invariant-shaped prose; require code-level
  enforcement at the declaration site for any property a reader might
  rely on.
- **Why rejected**: too strict. Some invariants are spec-derived (e.g.
  "Wasm linear memory page size is 65536") and don't need a runtime
  assert at every use; a single `pub const wasm_page_size = 65536;`
  declaration with a comment citing the spec is sufficient. The
  paired-enforcement rule covers this case via (a) comptime-assert
  shape or (c) lint coverage — over-strictness would force boilerplate
  without raising integrity.

### Alternative B — Lint-only enforcement (no rule file)

- **Sketch**: drop the auto-load rule; rely on `audit_scaffolding §G`
  grep to flag violation patterns.
- **Why rejected**: grep alone catches the *known* violation shapes
  (hardcoded register numerals, "always X" prose) but not the new
  shapes that the rule's principle should cover (future ownership
  claims in Cat III code, future Wasm 3.0 GC-slot ownership claims).
  The rule articulates the *principle*; the grep operationalises one
  *application* of the principle. Both are needed.

### Alternative C — Mandate runtime `assert` at every invariant use site

- **Sketch**: every invariant-protected access site must `assert(...)`
  before using the protected property.
- **Why rejected**: assertion churn obscures the code without
  proportional integrity gain. The rule prefers *one* boundary check
  (at the encoding helper, e.g. `FuncRef.encode/decode`) over N use-
  site asserts. The 4-option enforcement list (a/b/c/d) lets the
  author pick the cheapest mechanical anchor per invariant.

### Alternative D — Promote to ROADMAP §14 forbidden-list entry directly (no rule file)

- **Sketch**: skip the rule file; add "Unenforced prose invariants
  on load-bearing code" to ROADMAP §14.
- **Why rejected**: ROADMAP §14 entries are for behaviours that are
  *categorically* forbidden across the project. The comment-as-
  invariant case is a hygiene discipline with concrete
  enforcement options — the rule file is the natural home. ROADMAP
  §14 can cite the rule if escalation is later wanted.

## Consequences

### Positive

- **D-132-class bugs are caught at the prose-claim site**, not
  weeks later under stress. The mechanical fix is locked in at the
  moment of claim, not retroactively after bisect.
- **The lint catches future violations**: `audit_scaffolding §G`
  extension fires on every audit cycle; new invariant-shape
  comments without paired enforcement surface immediately.
- **The D-133 sweep is concrete + bounded** (op_table.zig +
  op_memory.zig hardcoded register numerals). One commit closes
  D-133.
- **The rule generalises to Cat III + Phase 10 work**: as runtime
  instance / store / GC slot / EH frame code lands, the same rule
  applies — invariant-shaped claims about ownership / layout /
  alignment must carry mechanical anchors.

### Negative

- **Existing comment sweep cost**: ~20 invariant-shape comments
  exist today in `src/`. Each is reviewed in §9.12-C; either fix
  applied (a/b/c) or comment deleted (d). Estimated 1 chunk of
  work.
- **`audit_scaffolding §G` grep can produce false positives**: a
  comment "X is always Y" may be explanatory rather than
  invariant-shaped. The grep flags candidates; the human (or future
  audit) decides. False-positive cost is bounded; false-negative
  cost (the D-132 case) is high.

### Neutral / follow-ups

- The rule's worked examples (op_table, funcref, validator,
  store) double as Phase 10 templates — each is the canonical
  shape for similar future code.
- Pair with `bug_fix_survey.md`: when a bug is fixed by adjusting
  an invariant, walk sibling sites with the same comment shape
  (D-132 fix forgot `emitMemoryInit` / `emitDataDrop`).
- `.claude/rules/runtime_instance_layer.md` (separate skeleton)
  applies this rule to Cat III code specifically; the two rules
  share the principle but have different scopes.

## References

- `.dev/lessons/2026-05-16-regalloc-pool-scratch-overlap.md`
  (D-132 root-cause retrospective; this rule's seed).
- D-133 (op_table sweep — discharged in §9.12-C).
- ADR-0071 (Phase 9 substrate audit resolution; Q5 referent).
- ADR-0018 (regalloc reserved set; prior art for comptime
  disjointness checks).
- ADR-0044 (funcref encoding; example of paired-enforcement
  shape).
- `.claude/rules/bug_fix_survey.md` (sibling-site sweep
  discipline; pairs with this rule).
- `.dev/phase9_completion_substrate_audit.md` §Q5.

## Revision history

| Date       | SHA          | Note                                                         |
|------------|--------------|--------------------------------------------------------------|
| 2026-05-19 | `bdd433d5` | Initial draft — Q5 deliverable; rule body + violation catalog + 4-option enforcement list. |
| 2026-05-19 | `<backfill>` | **Accepted** at §9.12 collab gate. Landing in §9.12-C (rule + lint + D-133 sweep). 新規ルール / lint 投入と同時に既存 `no_workaround.md` / `bug_fix_survey.md` / `audit_scaffolding §G` の重複・陳腐化を整理する dedup sweep を §9.12-C scope に含む。 |
