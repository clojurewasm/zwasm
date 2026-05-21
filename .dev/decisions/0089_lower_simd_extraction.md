# 0089 — Extract Wasm SIMD prefix dispatcher to `lower_simd.zig`

- **Status**: Accepted (2026-05-21, draft + impl landed same cycle)
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (D-141 per-file ADR series, post-ADR-0088)
- **Tags**: file-layout, refactor, zone-1, ir, lowerer, SIMD, file-size-cap

## Context

`src/ir/lower.zig` is **1109 LOC** — 11% over soft cap. The
dominant contributor is `const Lowerer = struct {...}` spanning
lines 97–1109 (**91% of file**). Inside Lowerer, the 0xFD SIMD
prefix dispatcher `emitPrefixFD` is a ~309-LOC switch over ~200
SIMD opcodes, with two paired SIMD-only helpers
(`emitLaneByte`, `emitMemargLane`).

Per the lesson [`2026-05-21-pure-data-extraction-via-reexport`](../lessons/2026-05-21-pure-data-extraction-via-reexport.md)
survey checklist:

1. **Does ONE block exceed 40% of file LOC?** YES — Lowerer is
   91%, and `emitPrefixFD` alone is 28%.
2. **Does it have methods?** YES — Lowerer is struct-method-heavy.
   Re-export pattern does NOT apply; must use ADR-0083's
   cross-file struct-method approach.
3. **Callers reach via namespace or direct import?** Internal —
   `emitPrefixFD` is called from `Lowerer.dispatch` (lower.zig
   line 271). Zero external callers.

Direct mirror of ADR-0083 (validator_simd.zig) at smaller scale.
The 2026-05-21 cross-file-struct-method-syntax lesson exists
precisely to make this carve cheap.

## Decision

Extract `emitPrefixFD` + its 2 SIMD-only helpers
(`emitLaneByte`, `emitMemargLane`) from `Lowerer`'s body in
`lower.zig` to a new sibling `src/ir/lower_simd.zig`. In
`lower.zig`, replace `emitPrefixFD`'s body with a 1-line
forwarder:

```zig
fn emitPrefixFD(self: *Lowerer) Error!void {
    return @import("lower_simd.zig").emitPrefixFD(self);
}
```

This preserves the internal dispatch path
(`Lowerer.dispatch` → `self.emitPrefixFD()`) unchanged at the
call site, while moving the 309-LOC switch body to the sibling.

| File | Contents | Approx LOC |
|---|---|---|
| `src/ir/lower.zig` (revised) | docstring + imports + 1 entry pub fn + `Lowerer` struct with pub-ified Lowerer/Error/emit/emitMemarg/appendSimdConst + `emitPrefixFD` forwarder + non-SIMD Lowerer methods (run / dispatch / emit / emitPrefixFC / open/closeBlock / etc.) | ~775 |
| `src/ir/lower_simd.zig` (new) | 19-line header + 3 free fns (pub fn emitPrefixFD + fn emitLaneByte + fn emitMemargLane), each taking `self: *Lowerer` as first arg | ~368 |

### Structural changes (per ADR-0083 lesson)

Required pub-ifications in `lower.zig`:

- `pub const Lowerer = struct {...}` (was non-pub) — so sibling
  can name `Lowerer` as `self` parameter type.
- `pub fn emit` / `pub fn emitMemarg` / `pub fn appendSimdConst`
  (was non-pub) — the 3 Lowerer methods called from sibling via
  `self.X(...)` cross-file method syntax.
- `Error` was already pub (no change needed).

Intra-moved call conversions:

- `self.emitLaneByte(op)` → `emitLaneByte(self, op)` (the moved
  fn is no longer a method on Lowerer; free-fn form).
- `self.emitMemargLane(op)` → `emitMemargLane(self, op)` (same).

Calls to non-moved methods (`self.emit(...)`, `self.emitMemarg(...)`,
`self.appendSimdConst(...)`) STAY as method syntax — Zig 0.16
resolves these cross-file via `Type.method(&instance, ...)` desugar
as long as the method is pub.

## Implementation — single carve cycle

The 2026-05-21 lesson's pre-extraction checklist made the carve
mechanical:

1. Python extraction script identifies the 3 fn-body boundaries
   via brace-matching walker.
2. Dedent (drop 4-space prefix, since methods become free fns).
3. Write sibling header + extracted content.
4. Sed-rewrite intra-moved `self.X(args)` → `X(self, args)` for
   the 2 helpers' call sites.
5. Pub-ify Lowerer + emit / emitMemarg / appendSimdConst in
   original.
6. Replace original `emitPrefixFD` body with the forwarder.
7. Build + cohort gate + lint.

Lint failed once: unused `const std = @import("std")` in the
sibling header (same touch-up as ADR-0083). Removed, re-ran,
green.

## Alternatives considered

### Alternative A — Extract ALL Lowerer methods (full struct-method carve)

- **Sketch**: move every Lowerer method (19 fns) to a sibling
  module, leave lower.zig as just the wrapper.
- **Why rejected**: too aggressive; methods like `run`, `dispatch`,
  `openBlock`, `closeBlock` are tightly coupled to the dispatch
  loop's state machine and would require state-threading
  refactor. The 309-LOC SIMD block is the only natural extraction
  axis without state-threading.

### Alternative B — Extract `dispatch` (the main 324-LOC switch) instead

- **Sketch**: move the main opcode dispatcher to a sibling.
- **Why rejected**: `dispatch` is the central call site for ALL
  Lowerer's helpers (emit, openBlock, closeBlock, emitElse,
  emitBrTable, etc.) — moving it requires pub-ifying ~10 methods
  vs SIMD's 3. Higher coupling cost, more pub surface, no clear
  semantic gain over the SIMD-prefix axis.

### Alternative C — Convert to re-export pattern (ADR-0087 shape)

- **Sketch**: `pub const emitPrefixFD = lower_simd.emitPrefixFD;`
- **Why rejected**: `emitPrefixFD` is a method on Lowerer, not a
  free function. Re-export of a method requires the receiver to
  exist at the call site. Since Lowerer.dispatch calls
  `self.emitPrefixFD()` (method syntax), the cleanest preservation
  is the body-forwarder (kept as a method) rather than aliasing.

## Consequences

- **Positive**:
  - lower.zig drops 1109 → 775 LOC. Well under soft cap.
  - The 309-LOC SIMD prefix dispatch becomes findable by file
    name (someone looking for "where are the SIMD opcodes
    lowered" reaches `lower_simd.zig` immediately).
  - D-141 lower.zig slot closes.
  - Pattern composes with ADR-0083 (validator_simd) — same
    SIMD-extraction shape applied to two layers (validate +
    lower).
- **Negative**:
  - 3 Lowerer helpers become pub (emit / emitMemarg /
    appendSimdConst). Pub surface expansion is intentional + bounded
    — these are the helpers the sibling needs; no other public
    callers should add new dependencies (audit_scaffolding §G can
    catch new external uses if they appear).
- **Neutral / follow-ups**:
  - emitPrefixFC (Wasm tablecopy/memorycopy/memory.init/etc
    prefix, ~82 LOC) is the parallel candidate if further
    extraction is desired — but lower.zig at 775 LOC is well
    under soft cap; no immediate pressure.

## References

- ADR-0083 — validator_simd.zig (direct precedent; SIMD
  extraction in the validator layer).
- Lesson
  [`2026-05-21-cross-file-struct-method-syntax-zig-0-16`](../lessons/2026-05-21-cross-file-struct-method-syntax-zig-0-16.md)
  — pre-extraction checklist that made this carve cheap.
- Lesson
  [`2026-05-21-pure-data-extraction-via-reexport`](../lessons/2026-05-21-pure-data-extraction-via-reexport.md)
  — survey checklist that flagged lower.zig as struct-method-
  heavy (NOT a re-export target).
- D-141 — file-size soft-cap proliferation.
- ROADMAP §A2 — file size soft (1000) / hard (2000) caps.

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `1a008ee5`   | Initial draft + impl landed same cycle. lower.zig 1109 → 775 LOC (-334); lower_simd.zig 368 LOC new. ADR-0083 cross-file struct-method pattern applied: pub Lowerer/Error/emit/emitMemarg/appendSimdConst; intra-moved self.emitLaneByte / self.emitMemargLane → free-fn form. Test gate cohort + lint green. D-141 lower.zig slot closes. |
