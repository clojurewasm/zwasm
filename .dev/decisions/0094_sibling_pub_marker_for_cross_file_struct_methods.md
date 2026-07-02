# 0094 — Introduce SIBLING-PUB marker + audit grep for cross-file struct-method extraction

- **Status**: Accepted
- **Date**: 2026-05-21
- **Author**: Shota Kudo
- **Tags**: phase9, structural-debt, encapsulation, audit, zig-0-16

## Context

Zig 0.16 removed `usingnamespace`. Cross-file struct-method
extraction (ADR-0083 `validator_simd.zig`, ADR-0089 `lower_simd.zig`,
ADR-0093 `op_control_merge_mov.zig`) requires pub-ifying both the
struct AND every helper method the moved code calls via `self.X()`
syntax — the lookup desugars to `Type.X(&instance, ...)` and goes
through `Type`'s namespace; non-pub methods are unreachable from
the sibling file. Lesson
[`2026-05-21-cross-file-struct-method-syntax-zig-0-16.md`](../lessons/2026-05-21-cross-file-struct-method-syntax-zig-0-16.md)
documents the mechanic.

The structural cost: each cross-file extraction permanently raises
a previously-private helper to module-public. Today's leaked
surface (D-158):

- `src/validate/validator.zig`: `Validator.popExpect`, `Validator.pushType`
  (pub-ified at ADR-0083 `860281bb`).
- `src/ir/lower.zig`: `Lowerer.emit`, `Lowerer.emitMemarg`,
  `Lowerer.appendSimdConst` (pub-ified at ADR-0089 `1a008ee5`).
- `src/engine/codegen/arm64/op_control.zig`:
  `resolveAndEmitMergeMovsRegBatch`, `emitMergeMov`,
  `captureOrEmitBlockMergeMov`, `unpackBlockArity`, `ParallelMove`
  (pub-ified at ADR-0093 `41dcc43d`).

`grep -rn` confirms **zero** external callers exist today. The
risk is **future misuse** — any Zone-1 caller can reach these
decls, and the type system can't distinguish "pub for sibling
reach" from "pub for the world". This is a workaround in spirit
of ROADMAP §P1 (no workarounds) with no paired ADR documenting
it as such — which is precisely the gap D-158 names.

The pattern will recur — Phase 9.12-F still has D-141 candidates
(`parse/sections.zig`, `api/instance.zig`, `engine/compile.zig`,
`regalloc.zig` etc.) where struct-method extraction is on the
table. Without a discipline, every future extraction enlarges the
leak.

## Decision

Adopt the **SIBLING-PUB marker convention** + automated audit
grep:

1. **Marker syntax** — every pub decl that is "pub-only-for-
   sibling-reach" gets an immediately-preceding comment:

   ```zig
   // SIBLING-PUB: <authorized sibling file paths, comma-separated>
   //   (per ADR-NNNN extraction)
   pub fn helper(...) ...
   ```

   The comma-separated list names the **only** files allowed to
   call this decl from outside the declaring file. The ADR
   reference cites the extraction ADR that introduced the leak.

2. **Audit script** —
   [`scripts/check_sibling_pub.sh`](../../scripts/check_sibling_pub.sh)
   (created by this ADR's implementation cycle):

   - Scans `src/**/*.zig` for `// SIBLING-PUB: <list>` markers,
     paired with the immediately-following `pub fn|const|var`
     decl name.
   - For each marker, builds `(decl_name, declaring_file,
     authorized_files)` triple.
   - `grep -rnE` the codebase for caller sites of `decl_name`
     (best-effort symbol grep — Zig has no LSP-equivalent in
     CI; the marker mechanism is intentionally grep-friendly).
   - Reports a `block` finding if any caller is in a file **not**
     in `(declaring_file, authorized_files)` ∪ test-tree
     (test files are exempt per `zone_check.sh`'s established
     pattern).
   - `--gate` mode exits non-zero on block; integrate into
     `scripts/gate_commit.sh` after the marker baseline lands.

3. **audit_scaffolding §F extension** — the periodic audit's
   debt-coherence section walks the SIBLING-PUB inventory and
   reports `soon` findings when a new pub decl is introduced
   inside a struct-method-extracted file pair without a marker
   (= bypass attempt).

4. **Marker application** to existing pub-leak sites — discharge
   D-158 by applying the marker to the 5 leaked surfaces named
   in Context above. Land in the implementation cycle of this
   ADR (separate commit, paired with the audit script).

## Alternatives considered

### Alternative A — Free-function refactor with explicit `*Self`

- **Sketch**: Convert all `self.X(args)` patterns inside the
  extracted sibling to `X(self, args)`; move method decls to
  free functions in their original file.
- **Why rejected**: Does not reduce pub surface. The free
  function still needs `pub` to be callable from the sibling
  file — Zig's pub/non-pub axis is per-decl, not per-method-
  vs-free-fn. The conversion changes call-site shape but not
  visibility class. Lesson
  [`2026-05-21-cross-file-struct-method-syntax-zig-0-16.md`](../lessons/2026-05-21-cross-file-struct-method-syntax-zig-0-16.md)
  step 2 of the fix path is exactly "intra-moved calls become
  free-function form" — and the cited `popExpect`/`pushType`
  pub-ification is unaffected by that conversion.

### Alternative B — Subdirectory + facade module

- **Sketch**: Put cohesive groups inside subdirectories
  (`src/validate/internal/`, `src/ir/lower_internal/`); expose
  only the facade module (`src/validate/validator.zig` re-
  exports a controlled subset). Files inside `internal/` can
  pub freely; external Zone-1 callers go through the facade.
- **Why rejected**: Zig 0.16 has **no** directory-scope
  visibility. Any `@import("validate/internal/foo.zig")` from
  any Zone-1 file works regardless of directory naming. The
  enforcement reduces to the same convention + grep as the
  chosen decision — but without the per-decl marker, the
  audit can't distinguish "legitimate facade re-export" from
  "bypass import". Net: same enforcement axis, weaker
  audibility, larger restructuring cost (move dozens of
  files).

### Alternative C — Wait for Zig stdlib mechanism

- **Sketch**: Defer the discipline until Zig adds a
  package-private or directory-internal visibility class.
- **Why rejected**: No such mechanism is on the Zig roadmap
  (verified against `~/Documents/OSS/zig/CHANGELOG.md` 0.16
  release notes; no proposal in `~/Documents/OSS/zig/doc/
  langref.html.in` matches). Indefinite deferral leaves the
  current 5 leaks + every future extraction unbounded. ROADMAP
  §P1 explicitly forbids indefinite-deferral workarounds.

### Alternative D — Accept the leakage with no enforcement

- **Sketch**: Do nothing; rely on reviewer discipline.
- **Why rejected**: Phase 9.12 closure quality is the user
  directive driving D-158's discharge. The session-internal
  pressure (continuation-loop) already demonstrated reviewer
  discipline drift (lesson `2026-05-21-d141-sweep-structural-
  debts.md`); a non-mechanical convention without grep
  enforcement is a non-discipline.

## Consequences

- **Positive**:
  - Pub-surface leakage from cross-file struct-method extraction
    becomes **observable** (audit grep) and **bounded** (named
    sibling list).
  - Future extraction ADRs inherit a default discipline; the
    marker becomes part of the pre-extraction checklist named
    in lesson `2026-05-21-cross-file-struct-method-syntax-
    zig-0-16.md`.
  - Discharges D-158 in a load-bearing way (marker convention
    + enforcement + applied to existing leaks).
  - audit_scaffolding §F gets a new structural-coherence check.

- **Negative**:
  - Marker text proliferation — every extracted struct-method
    file pair adds 5–10 marker comments. Mitigated by being
    structurally similar to existing `// EXEMPT-FALLBACK:` /
    `// FILE-SIZE-EXEMPT:` markers (precedent: ADR-0050,
    ADR-0063).
  - The grep enforcement is best-effort; symbol shadowing
    across files can produce false positives (e.g. another file
    has its own `emit` fn). Mitigated by qualifying the grep
    pattern with the declaring type (`Lowerer.emit` not bare
    `emit`); the audit script's pattern catalog is extensible
    if shadowing surfaces in practice.
  - Adds one more gate to `gate_commit.sh`. Minor; the gate's
    `--fast` mode already skips it per ADR-0076 D4 if needed.

- **Neutral / follow-ups**:
  - Implementation cycle (next /continue) lands:
    1. `scripts/check_sibling_pub.sh` (gate + info modes).
    2. Marker application to 5 existing leak sites.
    3. `audit_scaffolding §F` extension.
    4. `gate_commit.sh` integration (after baseline observation).
    5. Lesson
       [`2026-05-21-cross-file-struct-method-syntax-zig-0-16.md`](../lessons/2026-05-21-cross-file-struct-method-syntax-zig-0-16.md)
       update — add "pre-extraction checklist" step covering
       SIBLING-PUB marker addition.
  - ADR-0083 / 0089 / 0093 Consequences sections may be amended
    in the implementation cycle to cite this ADR as the
    pub-leak resolution.

## References

- ROADMAP §P1 (no workarounds)
- ROADMAP §A2 (file size caps — context for why extraction
  happens in the first place)
- ROADMAP §A1 / §4.1 (Zone architecture — encapsulation axis
  this ADR enforces orthogonally)
- ADR-0050 (skip-impl one-way ratchet — marker + audit gate
  precedent)
- ADR-0063 (FILE-SIZE-EXEMPT marker mechanism — marker syntax
  precedent)
- ADR-0083 (validator_simd extraction — first cross-file
  struct-method extraction; leaked `popExpect`/`pushType`)
- ADR-0089 (lower_simd extraction — leaked `Lowerer.emit`/
  `emitMemarg`/`appendSimdConst`)
- ADR-0093 (op_control_merge_mov extraction — private-helper-
  relocation variant; leaked 4 fns + `ParallelMove`)
- Lesson
  [`2026-05-21-cross-file-struct-method-syntax-zig-0-16.md`](../lessons/2026-05-21-cross-file-struct-method-syntax-zig-0-16.md)
  — the mechanic
- Lesson
  [`2026-05-21-d141-sweep-structural-debts.md`](../lessons/2026-05-21-d141-sweep-structural-debts.md)
  — the honest accounting that surfaced D-158
- `.dev/debt.md` D-158 row
- `.claude/rules/zone_deps.md` — sibling encapsulation enforcement
  via `scripts/zone_check.sh` (precedent for grep-based audit)
- `~/Documents/OSS/zig/CHANGELOG.md` (0.16 release notes —
  `usingnamespace` removal)

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `ac89b0a6` | Initial proposed version (this commit). |
| 2026-05-21 | `5653180c` | Accepted at `ba2a08cf5` — `scripts/check_sibling_pub.sh` + 9 markers + bonus `resolveAndEmitMergeMovsRegBatch` pub→private downgrade + gate_commit integration + lesson step 4. D-158 closed. |
