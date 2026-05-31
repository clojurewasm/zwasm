# No copy-paste from zwasm v1 — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/no_copy_from_v1.md`](../rules/no_copy_from_v1.md).

# No copy-paste from zwasm v1

Auto-loaded when editing Zig / C / shell / build sources. Codifies
ROADMAP P10's prohibition: **v1 may be read as a textbook; never
copy-pasted as code.**

## The rule

When implementing a feature in zwasm v2:

- ✅ **Read** v1 source, comments, and tests for context
  (Step 0 Survey, see `textbook_survey.md`).
- ✅ **Re-derive** the implementation in v2's design vocabulary
  (Zone 0-3, ZIR slots, dispatch tables, snake_case naming).
- ❌ **Do not** select-and-paste from v1 source files into v2
  source files.

The deliberate friction of re-typing each line is the act of
re-deciding. If a function ends up byte-for-byte identical with a v1
function after re-derivation, that is acceptable; it means the v1
design was already optimal for the v2 substrate. But the act of typing
it is what proves the redesign happened.

## Why (gate summary)

Three reasons, in order of importance:

1. **Implicit-contract sprawl** — v1's idioms carry assumptions about
   layer boundaries, error sets, and runtime invariants that were
   never written down. Copy-paste imports them silently.
2. **W54-class regression risk** — v1's post-hoc layered optimisations
   (W43/W44/W45/W54 hoist/coalescer) accumulated into a fragile
   lattice. v2's day-1 ZIR substrate avoids it; copy-paste defeats
   that.
3. **Knowledge compression** — re-derivation is what makes the project
   teachable.

## Quick OK / NOT-OK example

OK: "I read v1's `validate.zig` § type-stack tracking. The MVP-level
idea is the same in v2. I re-derived the structure here, splitting
per-feature handlers per ROADMAP §4.5."

NOT OK: "Ported `validate.zig` from v1 with minor renames." — if the
diff between v1 and v2 is "minor renames", you bypassed the redesign
step.

## Exception (gate)

This rule applies to **zwasm-authored source**. Externally-authored
artefacts that v1 also consumed verbatim (WebAssembly spec testsuite,
WASI testsuite, realworld TinyGo / Rust / emcc binaries,
`include/wasm.h` from upstream `WebAssembly/wasm-c-api`) are exempt.
v2 fetches them fresh from the same upstream — they are not "v1
source".

詳細・rationale (full Why expansion, worked examples, reviewer
checklist, exception list) は
[`references/no_copy_guardrails.md`](../references/no_copy_guardrails.md)
を参照。

