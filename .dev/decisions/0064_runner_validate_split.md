# 0064 — Split runner.zig: extract module-level validation into runner_validate.zig

- **Status**: Accepted
- **Date**: 2026-05-17
- **Author**: Shota Kudo (chaploud)
- **Tags**: scaffolding, runner, module-validation, file-size, ROADMAP-§A2

## Context

`src/engine/runner.zig` reached 2178 lines as of HEAD
(2026-05-17), exceeding the ROADMAP §A2 hard cap (2000 LOC). The
growth came from the d-74 → d-85 chunk cohort (cumulative +217
PASS) which added ~600 LOC of inline module-level validation
passes to `compileWasm`:

- §3.4.4 memory section (d-75): count + limits + data-segment-
  requires-memory.
- §3.4.5 table + §3.4.6 elem segment validation (d-76): tableidx
  in range + active-elem reftype match + funcidx range (d-83).
- §3.4.10 export validation (d-74): idx in range + duplicate
  names.
- §3.4.3 / §3.3.2 global init-expression validation (d-77):
  const-expr opcode check + result-type match + trailing-end.
- §3.4.6 / §3.4.7 active elem/data offset-expression validation
  (d-78): i32-typed const-expr.
- Function-body memory-op validation threading (d-79).
- §3.3.5.6 + §3.4.6 reftype-matching for call_indirect (d-80).
- §3.4.7.3 / §3.4.10 ref.func declared-funcrefs set (d-82).
- §3.4.6 elem-funcidx range + §3.3.5.20 table.init reftype-match
  (d-83).
- §5.5.3 type-section eager decode + §5.5.6 function/code count
  + §5.5.13 data_count consistency + §5.5.10 memory.init/
  data.drop require data_count (d-84).

Each addition is small (10-50 LOC); cumulatively they bloated
`compileWasm` to 851 LOC and runner.zig to 2178 LOC. The
validation passes are also DUPLICATED between the empty-fn
early-return path (lines 411-590) and the main path (lines
614-870) — d-77 and d-78 explicitly added mirrors because the
empty-fn branch otherwise skipped them. The mirrors are
mechanical copies; the spec rule is the same.

Unlike `entry.zig` (ADR-0063: uniform-pattern catalog
exemption), `runner.zig`'s growth is LEGITIMATE multi-concern
bloat. Splitting is the appropriate response.

## Decision

Extract module-level validation into a new
`src/engine/runner_validate.zig` module. Initial scope:

1. **Standalone helpers** move wholesale:
   - `initExprRefFunc` (10 LOC)
   - `validateGlobalInitExpr` (~85 LOC)
   - `evalConstScalarRaw` (~50 LOC)
   - `evalConstV128Expr` (~25 LOC)
   - `evalConstI32Expr` (~23 LOC)
   These have no `compileWasm`-internal state dependencies; they
   take `(expr: []const u8, ...)` and return a result.

2. **Early validation block** (current lines ~175-374) extracts
   to `validateEarlyModuleSections(allocator, module, imports_buf)
   Error!void`. Covers memory count + limits, table/elem range,
   import typeidx — the validation that fires BEFORE the
   empty-fn vs main-path branch.

The split keeps the `Error` set in runner.zig (so existing
callers continue using `runner.Error`); runner_validate.zig
returns a narrower error set that aliases into runner.Error.

Out of scope for this chunk:

- Eliminating the empty-fn-path vs main-path validation
  duplication. The mirror structure is intentional (different
  pre/post conditions for each path). A future ADR may unify if
  the duplication grows past tolerable.
- Moving setupRuntime / hostDispatchTrap / per-export run
  helpers. These are runtime concerns, not validation; separate
  candidate split later if needed.

Expected post-split LOC: runner.zig ~1750, runner_validate.zig
~440. Both well under hard cap.

## Alternatives considered

### Alternative A — Full validation extract including both empty-fn and main-path passes

- **Sketch**: extract ALL validation (early block + empty-fn
  mirrors + main-path passes) into one `validateModule(...)
  Error!ValidatedModuleContext` that runs BEFORE the empty-fn
  branching decision, returning a struct with decoded sections
  + counts that `compileWasm` consumes.
- **Why rejected for THIS chunk**: requires plumbing many
  context fields and re-thinking the empty-fn-vs-main branching
  shape. Higher refactor risk; defer to a follow-up if the
  duplication pain re-surfaces.

### Alternative B — Split by Wasm spec section number (§3.4.4 / §3.4.5 / …)

- **Sketch**: one file per Wasm spec §, e.g.
  `runner_validate_memory.zig`, `runner_validate_tables.zig`.
- **Why rejected**: 6-10 tiny files for ~50 LOC each; each
  validation is invoked once by the caller and has no separate
  reusability. The spec-section taxonomy doesn't map to
  meaningful Zig module boundaries.

### Alternative C — Accept runner.zig > 2000 via FILE-SIZE-EXEMPT marker

- **Sketch**: apply ADR-0063 exemption to runner.zig too.
- **Why rejected**: runner.zig IS multi-concern. ADR-0063's
  exemption is for uniform-pattern catalogs, not "any file that
  grew past cap". The smell-detection signal at 2000 LOC for
  runner.zig is a TRUE positive.

## Consequences

- **Positive**:
  - runner.zig under hard cap; pre-commit hook can re-activate
    without rejection.
  - Module validation extracted to a discoverable, named module
    (`runner_validate.zig` — grep-friendly).
  - The 5 standalone helpers are reusable from other contexts
    (e.g. `setupRuntime`'s init-expr evaluator paths).

- **Negative**:
  - Cross-file plumbing of decoded sections is slightly more
    verbose than inline access (extra param passing).
  - The empty-fn-path mirror duplications still exist (deferred
    per Alternative A rejection); the split surfaces but does
    not resolve them.

- **Neutral / follow-ups**:
  - If empty-fn vs main-path validation duplication grows further,
    file a new ADR for the unified `validateModule(...)` shape.
  - `audit_scaffolding` skill §B.3 (duplicated facts) should
    track the explicit `validateGlobalInitExpr` mirror call
    pairs as a deferred coalescing candidate.

## References

- ROADMAP §A2 (file size hard cap)
- ADR-0063 (companion: uniform-pattern catalog exemption for
  entry.zig)
- d-74 through d-85 phase_log entries documenting the
  validation additions
- `.claude/skills/audit_scaffolding/CHECKS.md` §B.1 (file-size
  finding category)

## Revision history

| Date       | Change                                          | Commit |
|------------|-------------------------------------------------|--------|
| 2026-05-17 | Initial draft + acceptance + split execution    | (this commit) |
