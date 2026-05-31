# Wasm spec citation per handler — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/spec_citation.md`](../rules/spec_citation.md).

# Wasm spec citation per handler

Auto-loaded when editing parse / validate / IR / instruction / runtime
/ engine codegen / feature sources. Codifies the discipline that
surfaced as a gap in §9.7 / 7.5-spec-assertion-driver-{f,t}: basic
Wasm spec requirements (D-033 i64 width, chunk-t prologue local
zero-init) reached production without unit-test coverage because the
per-handler authoring did not require a spec citation.

## The rule

Every handler / encoder / validator routine that implements a
**spec-defined behaviour** carries a docstring line of the form:

```zig
/// Wasm spec §X.Y.Z (op-name) — <one-line summary of the
/// spec semantics this implementation realises>.
```

Multiple citations are allowed. The citation belongs **on the function
or struct itself**, not in a separate ADR — the in-source comment is
the load-bearing artifact because it travels with the code through
every refactor.

## Why this matters (gate summary)

Phase 7 surfaced two classes of spec-semantic miscompiles that would
have been caught at authoring time if a spec citation were required:

- **D-033** (`local.get` truncating i64 to 32-bit): docstring described
  *what the code does*, not *what the spec demands* (Wasm §3.5.3).
  A required `Wasm spec §3.5.3` citation would have surfaced "is
  W-form correct for all declared types?" at write time.
- **chunk-t prologue local zero-init**: Wasm §4.5.3.1 ("locals
  initialised to ⟨T.const 0⟩"); the original prologue marshalled
  params but not declared locals. A required citation on the prologue
  would have made "are all locals zero-initialised?" a write-time
  question.

## What counts as a "handler with spec semantics"

| Category | Spec citation required? | Example |
|---|---|---|
| Parser section decoder (`decodeFunctions`, `readBlockType`) | Yes | `Wasm spec §5.5.X` |
| Validator opcode handler (`opIf`, `opCall`) | Yes | `Wasm spec §3.X.X` |
| IR lowerer (per-op `emit` calls in `lower.zig`) | Yes (or refer to Validator) | `lower(.@"i32.add", ...)` cites `§3.3.1.X` |
| Per-arch emit handler (`emitI32Binary`, `emitMemOp`) | Yes — both arch encoder reference AND Wasm semantic | `Wasm spec §4.4.1.X` + `Arm IHI 0055 §X.Y.Z` (or `Intel SDM Vol 2 X.Y`) |
| Runtime op (e.g. `Memory.grow`) | Yes | `Wasm spec §4.5.X` |
| Pure encoder (`encAddRegW`, `encStrImmW`) | NO — Wasm spec is irrelevant; arch ISA citation only | `Arm IHI 0055 §C6.2.X` |
| Test fixture / runner glue | NO | — |
| Pure helper (allocator wrappers, leb128 decoder primitives) | NO | — |

If you cannot decide which category a function falls into, ask:
**"if the Wasm spec changed for this op, would this function need to
change?"** If yes → spec citation required.

## Why this rule, not an ADR

This is observational + prescriptive (a rule about how new code is
authored), not a load-bearing decision that gates downstream
behaviour. Per `lessons_vs_adr.md`, prescriptive project rules that
don't pick a code path live in `.claude/rules/`.

詳細(format examples for validator/per-arch/parser handlers, reviewer
checklist, audit_scaffolding §G grep mechanics, staleness on
proposal-merge, forbidden anti-patterns) は
[`references/spec_citation_examples.md`](../references/spec_citation_examples.md)
を参照。

