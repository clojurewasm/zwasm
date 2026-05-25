---
description: "Test discipline — boundary fixture obligation at code-write time (気付いたら即追加) + bug-fix-time same-class-cases grep before patching symptom. Absorbs former edge_case_testing.md + bug_fix_survey.md per ADR-0118 D3."
paths:
  - "src/**/*.zig"
  - "test/**/*.zig"
  - "test/edge_cases/**"
  - "build.zig"
---

# Test discipline

Two complementary disciplines: **add boundary fixture when crossing
a semantic edge** (write-time) + **grep siblings before fixing a
bug at one site** (fix-time).

## §1 — Boundary fixture obligation (気付いたら即追加)

While editing code, you cross a "boundary" when any of:

- Encoding a numeric op with IEEE-754 corner cases (NaN, ±Inf,
  ±0, denormal, exact-integer FP edge).
- Implementing or modifying a comparison whose strictness matters
  (`<` vs `<=`, signed vs unsigned vs ordered).
- Touching a spec-defined trap condition (memory bounds, table
  bounds, sig mismatch, integer overflow on trapping ops).
- Adding a new ZIR op or modifying an existing op's semantics
  (especially Wasm 2.0+ proposals).
- Refactoring a regalloc / spill / ABI invariant whose violation
  is silent at the type system but crashes at runtime.

When you cross a boundary AND no existing fixture covers it:
**add a fixture in the same commit**. Don't defer.

### Stress axes (dimensions worth exercising)

Per ADR-0072 §"Invariants in code, not prose":

| Axis | Examples |
|---|---|
| **Numeric range** | min/max int (i32 INT_MIN / INT_MAX); ±0, NaN, ±Inf, denormal; just-inside / just-outside 2's-complement |
| **Alignment / offset** | unaligned load/store (align 0 vs natural); page-edge (mem.size-1 / mem.size); SIMD lane-index 0 / max-1 / max |
| **Register pressure** | regalloc spill-vs-pool boundary (D-132/133); first-spill vs Nth-spill; live-range crossing a call (clobber boundary) |
| **Dispatch shape** | same-module call vs cross-module bridge thunk (D-142, ADR-0066); call_indirect table[0]/[last]/[oob]; sig-mismatch trap |
| **ABI boundary** | caller-saved scratch vs callee-saved invariant; pinned reg (X19/R15) survival across cross-module; signal-handler entry/exit |
| **Control flow** | block / loop / if-else nesting 1 / 2 / N; br to label-stack[0] vs [N]; unreachable-after-trap pruning |
| **Validator strictness** | type-stack underflow at fn boundary; multi-value param/result mismatch; assert_unlinkable vs runtime trap |
| **Cross-module / linking** | host import (Cat III) vs Wasm import; assert_unlinkable error class vs runtime trap; v128 cross-module load (D-079) |

A boundary on one axis often implies coverage gaps on others; a
new SIMD recipe (numeric range) introduces a new register-pressure
profile + dispatch shape. Scan `.dev/lessons/` + `.dev/decisions/`
for prior cases when uncertain.

### Fixture layout

```
test/edge_cases/p<N>/<concept>/<case>.wat       ← source (WAT)
test/edge_cases/p<N>/<concept>/<case>.wasm      ← compiled artifact
test/edge_cases/p<N>/<concept>/<case>.expect    ← expected outputs
```

`<N>` = phase where boundary first encountered. `<concept>` = op
group / feature (e.g. `trunc_f32_s`, `memory_bounds`). `<case>` =
short slug (e.g. `at_int_min`, `nan_input`, `idx_eq_size_minus_one`).

Lead `.wat` with provenance comment citing spec testsuite +
assertion line OR "internally derived from sub-X.Y boundary at
commit `<sha>`".

### `.expect` format

Trap-expecting:
```
trap: <canonical Wasm trap reason>
```

Value-returning (one line per result):
```
i32: <decimal>
i64: <decimal>
f32: <hex bits>
f64: <hex bits>
```

The runner parses `.expect` and asserts equality.

### When NOT to add a fixture

- **Type-system-enforced invariants** — `comptime` checks at build.
- **Trivially-mechanical encodings** — clang-verified + otool-inspected.
- **Internal implementation** not observable from Wasm (e.g. "the
  prologue uses MOV X19, X0").

Rule targets **observable spec-defined boundaries**, not internals.

### Fixture-internal workaround → debt entry

If a fixture file contains `// FIXME` / `// TODO` / `// HACK` /
hardcoded shortcut / bypass-constant: file a `D-NNN` row in
`.dev/debt.md` (same commit) naming the structural barrier
(`Status: blocked-by: <specific barrier>`). The fixture documents
the boundary AND the gap.

Forbidden fixture-comment phrasing:
- `// quick fix to make this pass` → escalate to debt
- `// remove when X works` without naming X precisely

(2026-05-04 retrospective regret #4: fixture-internal workarounds
atrophied silently across Phase boundaries because they weren't in
any debt or lesson.)

### Test-side byte offsets must be relative

Tests asserting JIT-emitted byte offsets MUST compute via the
prologue helper, not hardcoded literals:

```zig
// REJECTED — hardcoded
try testing.expectEqual(expected, std.mem.readInt(u32, out.bytes[32..36], .little));

// REQUIRED — via helper
const body_start = prologue.body_start_offset(/* has_frame = */ false);
try testing.expectEqual(expected, std.mem.readInt(u32, out.bytes[body_start..body_start+4], .little));
```

Helper: `src/jit_arm64/prologue.zig` / `src/jit_x86/prologue.zig`
(ADR-0019 / ADR-0021). New sites MUST use the helper. Exception:
opcode-pinned prologue first two words (AAPCS64 fixed per Arm IHI
0055 §6.4) — use `prologue.FpLrSave.stp_word` /
`prologue.FpLrSave.mov_fp_word` for value comparison; byte offsets
`[0..4]` and `[4..8]` stay literal.

(2026-05-04 retrospective regret #6: ADR-0017's 5-LDR prologue
change broke 124+ hardcoded test sites.)

## §2 — Bug-fix-time same-class-cases grep

Before editing code to fix a bug, run a same-class-cases survey:

1. Identify the symptom's **shape** (symbol, control-flow pattern,
   type, opcode group, field-merge logic).
2. **Grep** for that shape (`rg -n '<symbol>' src/` and a
   shape-level regex when the symbol is too narrow).
3. Apply the fix at every recurring site OR document exemption.
4. If the symbol is **near a ROADMAP §14 entry** (single slot dual
   meaning, ARM64-only feature, dispatch-table bypass), re-read
   the §14 entry + corresponding `.claude/rules/*.md` BEFORE
   editing.

Complements [`textbook_survey.md`](textbook_survey.md) (task-start
design survey) — this rule covers bug-fix-time.

### `/continue` Step 4 inline checklist (per master plan §9.12-C)

When Step 4 (Refactor) involves a bug-fix diff, walk before Mac
lint gate:

- [ ] **Same-class-cases grep** — `rg -n '<symbol>' src/`. Bundled
      arm rename / pattern change → siblings often live in adjacent
      files (e.g. x86_64 mirror of an arm64 fix).
- [ ] **Multi-tag arm audit** — removing / renaming a switch arm
      covering multiple `.@"foo"` patterns → verify each constituent
      independently handled by new dispatch (B109 `.select,
      .select_typed` regression).
- [ ] **§14 forbidden list re-read** — diff near §14 entry → re-read
      `single_slot_dual_meaning.md` / `no_workaround.md` /
      `abi_callee_saved_pinning.md`.
- [ ] **Boundary fixture obligation** (§1 above) — fix touches
      numeric / alignment / register-pressure / dispatch / ABI /
      control-flow / validator axis → add regression fixture same
      commit unless one exists.

Each item is 30 seconds.

### When §2 skip is OK

- **Trivial fixes**: typos in comments / format strings; missing
  `null` check on a single optional with unambiguous source.
- **Type-system errors**: compiler enumerates every site.
- **Refactor-rename**: `replace_all` covers the population.

If unsure: run the grep. 30 seconds vs one re-fix cycle.

## Anti-patterns

- **"We'll add the fixture later"** — add the WAT today; runner
  wires up later. Fixture is the spec; runner is execution.
- **"This boundary is too obvious"** — value is regression
  detection, not initial verification.
- **"Batch fixtures at next audit"** — defeats same-commit
  discipline; coverage atrophies during Phase gaps.

## Why this rule exists

- **D-027** (twin-largest 2026-05-04 regret): if-result merge fix
  landed for `if` only; `block (result T)` / `loop (result T)`
  needed same fix → extra cycle in sub-7.5c-vii. Bug-fix-time grep
  for "label result arity" would have surfaced siblings first.
- **Phase 8 + 15 optimization safety net**: every refactor either
  keeps boundary fixtures green or fails them loudly. Without
  fixtures, regressions surface only when downstream breaks.

## Stale-ness

Fixtures stale when spec proposals update (e.g. new trap reason):

1. Update `.expect` to new behaviour.
2. Add WAT comment referencing the spec change.
3. Don't delete unless boundary is genuinely gone.

`audit_scaffolding §I` (ADR-0020) periodically verifies each
fixture's `.wasm` matches its `.wat` source.

## References

- `references/bug_fix_grep_procedure.md` — full procedure with rg
  examples, additional case studies, anti-patterns table.
- ADR-0020 (edge-case fixture culture)
- ADR-0021 (prologue helper migration)
- `.dev/lessons/2026-05-04-prologue-helper-migration-regret.md`
