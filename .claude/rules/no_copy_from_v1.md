---
paths:
  - "src/**/*.zig"
  - "build.zig"
  - "include/**"
  - "scripts/**"
  - "test/**"
  - ".dev/ROADMAP.md"
  - ".dev/handover.md"
---

# No copy-paste from zwasm v1

> Lean stub (ADR-0118 D2). Full Why / examples / reviewer checklist / exception list: [`../references/no_copy_from_v1.md`](../references/no_copy_from_v1.md) (→ `no_copy_guardrails.md`).

## Invariant (PRESERVE — ROADMAP P10 mandate)

- ✅ **Read** v1 source/comments/tests as a textbook (Step 0 survey).
- ✅ **Re-derive** in v2 vocabulary (Zone 0–3, ZIR slots, dispatch tables,
  snake_case). Byte-for-byte identity is OK ONLY when it is the *result* of
  re-derivation — the act of re-typing is the act of re-deciding.
- ❌ **Never select-and-paste** v1 source into v2 source. "Ported with minor
  renames" = you bypassed the redesign (imports v1's implicit-contract sprawl +
  W54-class regression risk).

## Enforcement

Reviewer discipline (Step 0 survey + Step 4) — no mechanical gate. The tell:
a v2↔v1 diff that is "minor renames" only.

## Key cases

- EXEMPT: externally-authored artefacts v1 also consumed verbatim — the Wasm
  spec testsuite, WASI testsuite, realworld TinyGo/Rust/emcc binaries,
  `include/wasm.h` from upstream wasm-c-api. v2 fetches these fresh; not "v1
  source".
- OK framing: "read v1's validate.zig § type-stack, re-derived per ROADMAP §4.5".

Full rationale + worked OK/NOT-OK examples + exception list: [`../references/no_copy_from_v1.md`](../references/no_copy_from_v1.md).
