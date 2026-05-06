---
name: spec-citation-gap
description: Per-handler Wasm spec § citation rule introduced after two basic-spec late-surface bugs (D-033 + prologue zero-init)
type: feedback
---

# Spec citation gap — per-handler Wasm spec § anchoring

## The pattern

Two §9.7 / 7.5 chunks surfaced **basic-Wasm-spec-level** bugs
late, despite extensive byte-level test coverage:

1. **D-033 (chunk-f)**: `local.get` / `local.set` / `local.tee`
   used `STR W` / `LDR W` (32-bit) regardless of declared local
   type, silently truncating i64 to 32 bits. The handler
   docstring said "Push a fresh vreg holding the value loaded
   from `[SP, #(local_idx * 8)]`" — describing **what** the code
   does, not what Wasm spec §3.5.3 demands (the value type
   follows the local declaration).

2. **chunk-t prologue zero-init**: declared locals beyond
   parameters were left uninitialised (stack garbage). Wasm
   spec §4.5.3.1 explicitly mandates `⟨T.const 0⟩`
   initialisation. Caught only when running the actual
   `local_get.wast` corpus through spec_assert_runner —
   `type-local-i32` returned 1 instead of 0.

Both gaps persisted through:
- Author + reviewer attention at write time
- `byte-level` unit tests verifying encoding correctness
- 3-host green over the affected commits
- Multiple ADRs covering adjacent concerns

## Why this matters

The infrastructure to catch these gaps existed only as
**reactive surface-via-corpus-expansion**, not as **proactive
write-time constraint**. spec_assert_runner was added late in
the loop (chunk-a, several phases after the affected handlers
were authored).

If every spec-semantic handler had carried a `Wasm spec §X.Y`
docstring citation at write time, both bugs would have been
detectable as questions during authoring:

- D-033: "I'm citing §3.5.3, which says the value type follows
  declaration — does my W-form load actually preserve i64?"
- zero-init: "I'm citing §4.5.3.1, which says locals init to
  zero — does my prologue do that?"

## The rule (now codified)

`.claude/rules/spec_citation.md` lands as a permanent rule
auto-loaded when editing parse / validate / IR / instruction /
runtime / engine codegen / feature sources. Every
spec-semantic handler now requires a docstring line of the form:

```zig
/// Wasm spec §X.Y.Z (op-name) — <semantic summary>.
```

The rule is observational (describes how new code should be
authored, not which code path runs), so it lives as a rule
under `.claude/rules/` rather than an ADR. Multiple sites
already in production are not retroactively required — the
discipline applies forward.

## Citing

- Discovery commits: chunk-f (`ff7df89`, D-033 discharge),
  chunk-t (`d1eb42a`, prologue zero-init).
- Rule: `.claude/rules/spec_citation.md`.

## Cross-references

- `.claude/rules/edge_case_testing.md` — boundary-fixture rule
  that pairs with spec citations: spec citation says **what
  semantics**, fixture rule says **which boundaries to exercise**.
- `.claude/rules/textbook_survey.md` — Step 0 survey reads
  reference codebases; spec citation rule is the per-handler
  derivative of that — when authoring the handler, anchor in
  spec, not in v1's interpretation of spec.
