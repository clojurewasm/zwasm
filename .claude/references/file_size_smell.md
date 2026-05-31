# File-size discipline: smell-detection, not metric satisfaction — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/file_size_smell.md`](../rules/file_size_smell.md).

Auto-loaded when editing `src/**/*.zig`, `.dev/decisions/*.md`,
`scripts/file_size_check.sh`. Codifies ADR-0099 (which reframes
ADR-0023 §A2 cap rationale and reinforces ADR-0063 EXEMPT
mechanism).

## The two caps and what they mean

| Cap | Lines | Behavior | Purpose |
|---|---|---|---|
| Soft (1000) | WARN | `file_size_check.sh` emits WARN; informational | **Smell detector** — investigate, don't auto-split |
| Hard (2000) | BLOCK | `file_size_check.sh --gate` fails | Forced ADR — design choice required |
| Exempt (2500) | BLOCK with marker raise | Marker raises hard cap; soft WARN persists | For files with declared rationale |

**The soft cap WARN is NOT a metric to drive to zero.** It's a signal to investigate.

## When you see a WARN — the decision tree

```
WARN: src/foo.zig (1234 lines)
  ↓
Is the file mixing multiple concerns?
  ├─ NO  → Add `// FILE-SIZE-EXEMPT: <rationale> (per ADR-0099)`
  │        on lines 1-5. Cite ADR-0099. Done.
  │
  └─ YES → Does a valid extraction exist?
            ├─ NO  → Investigate the redesign. May need an ADR-grade
            │        survey first (extract shared helpers, etc.).
            │        DO NOT extract just to make the WARN disappear.
            │
            └─ YES → File extraction ADR per the 4+4 conditions below.
```

## The 4+4 conditions (ADR-0099 D2)

### Positive (need ≥ 1)

**P1 — Spec-defined closed sub-language**
- Module corresponds to a spec section (Wasm proposal, ABI class, ISA family)
- AND substantive code ≥ 300 LOC

**P2 — Pure-data dominance**
- Single declaration block ≥ 40% file LOC
- No methods, no state, no internal helpers used by rest of file

**P3 — Independent change cadence + deep interface**
- Git log (last 6 months) shows independent commits — advisory; for
  recent extractions without history, use structural evidence (clean
  narrow interface + visible independent purpose)
- AND ≥ 3 public symbols OR 1 deep operation
- AND ≥ 2 external callers OR 1 caller with ≥ 10 use-sites

**P4 — Test surface isolation** (corroborating only, not sufficient alone)
- Child tests don't import parent fixtures

### Negative (any one → REJECT)

**N1 — Helper-circular import**
- Child uses `parent.<helperFn>` (function, not type)
- Helper was private before extraction
- **Test-context carve-out**: calls inside `test "..." { ... }` blocks
  are informational only (round-trip property tests are intentional).
  Script flags them; reviewers accept.

**N2 — Forced pub-leak of helper function**
- Extraction adds `pub` to previously-private function
- Function is non-test code
- Acceptable only with SIBLING-PUB marker (ADR-0094) AND P1 trigger

**N3 — Shallow module**
- Substantive code < 100 LOC
- No P1 qualification

**N4 — Test dup or fixture pub-leak**
- Test helper duplicated across siblings (body > 5 LOC)
- OR test fixture pub-ified

### Tie-breaker

≥ 1 positive AND ≥ 1 negative:
- P1 + N2-managed-by-SIBLING-PUB → **ACCEPT** (existing handling for ADR-0083/0089)
- P3 + N1-type-only → **ACCEPT** (existing handling for ADR-0098)
- Otherwise → **REJECT** or **redesign**

## Reviewer checklist

When reviewing a file-size-driven extraction ADR:

- [ ] Does the ADR's "Conditions check" section enumerate which P/N fire?
- [ ] If an N fires without tie-breaker — REJECT
- [ ] If 0 P fires — REJECT
- [ ] Does the impl match what the ADR claims (e.g., spec-axis P1 holds against actual code shape)?
- [ ] After landing, does `scripts/check_split_smell.sh` flag the result?

## When to use EXEMPT marker

EXEMPT marker is the **default outcome when no valid extraction exists**:

```zig
// FILE-SIZE-EXEMPT: <one-line specific rationale> (per ADR-NNNN)
```

The rationale must name a concrete category:
- "Uniform-pattern catalog" (e.g., entry.zig: 84 callXX_yy helpers)
- "Wasm spec §X.Y.Z catalog" (e.g., parse/sections.zig if we choose this path)
- "Closed sub-language single-file impl" (when split would create shallow modules)
- "Per-instruction-class catalog" (e.g., op_simd_int_cmp_lane.zig)

Vague rationales ("legacy", "complex", "later") are rejected by the script's marker regex.

## Forbidden anti-patterns

- **"Make this file ≤ 1000 lines"** as task description — re-state as "investigate the smell"
- **Sub-100-LOC sibling extraction** — almost always a shallow module
- **"Pub-ifying" a helper to enable extraction** — without SIBLING-PUB + P1
- **Test helper dup as the only sharing mechanism** — usually a sign tests aren't separable

## Sibling rules

- `.claude/rules/lessons_vs_adr.md` — when to write a lesson vs ADR
- `.claude/rules/architectural_spike.md` — when to use private/spikes/ instead
- `.dev/decisions/0023_*.md` — original cap
- `.dev/decisions/0063_*.md` — EXEMPT marker mechanism
- `.dev/decisions/0094_*.md` — SIBLING-PUB marker (for managed N2)
- `.dev/decisions/0099_*.md` — this rule's source of truth

## Stale-ness

This rule is stale if any of the following:
- All of N1/N2/N3/N4 lack mechanical detection (no script AND no audit AND no rule grep covers them)
- The P/N conditions cannot be applied per the ADR-0099 §D2 decision tree
- The current Zig version's import semantics change (e.g., 0.17+) such that
  the mechanics described in ADR-0083 / ADR-0094 stop working

The check_split_smell.sh script is one mechanical implementation but not
the only acceptable one. Removing it and replacing with an equivalent
mechanism (e.g., LSP-based check) is fine.

When stale, an ADR-0099 amendment is needed.
