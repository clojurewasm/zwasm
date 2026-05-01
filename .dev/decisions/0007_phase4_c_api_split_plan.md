---
name: 0007 — Split src/c_api/wasm_c_api.zig along chunk boundaries
date: 2026-05-02
status: Accepted
tags: phase-4, phase-5, c-api, file-size
---

# 0007 — Split src/c_api/wasm_c_api.zig along chunk boundaries

- **Status**: Accepted
- **Date**: 2026-05-02
- **Author**: Claude (autonomous /continue loop)
- **Tags**: phase-4, phase-5, c-api, file-size

## Context

`src/c_api/wasm_c_api.zig` reached **2092 lines** during Phase
4 — exceeding the §A2 hard cap of 2000 (a `block` finding per
the `audit_scaffolding` skill's CHECKS.md). The file grew
through §9.3 / 3.4 onward as each binding chunk added shapes,
exports, and tests in place; the §9.4 / 4.7 host-thunk wiring +
4.10 validator extension pushed it past the cap.

The Phase-3 boundary audit (private/audit-2026-05-02-p3.md)
already flagged the file as `soon` and recommended a split
along three carve-outs (`trap_surface.zig` / `vec.zig` /
`instance.zig`); the Phase-4 boundary audit elevates it to
`block`.

A split that's safe to land mid-loop has a non-trivial blast
radius:
- ~36 `pub export fn`s spread across the file (engine /
  store / module / instance / func / extern / trap / vec).
- Cross-references between sections (Trap allocator pinned to
  Store→Engine; Instance owns a Runtime + arena that
  instantiateRuntime populates; vec helpers parameterised on
  ByteVec / ValVec / ExternVec types).
- ~95 tests interleaved with the code under test.

Splitting under time pressure (during a Phase-4 boundary
commit) is also risky because all three hosts must stay green
through the move.

## Decision

File-split lands as **the first task of Phase 5** (§9.5 /
5.0), executed off the analysis-layer phase ramp where similar
size-cap-driven moves (mvp.zig int_ops / float_ops /
conversions; validator.zig + lowerer.zig) are already queued.

The Phase-4 boundary commit acknowledges the block finding,
files this ADR, and proceeds — per the
`audit_scaffolding` skill's "block finding requires load-
bearing change" branch ("file an ADR via §18, queue the fix
in handover, then continue").

The carve-outs are:

```
src/c_api/
  wasm_c_api.zig          ~600 lines  re-exports + module-level docs;
                                      keeps the export point names
                                      stable for include/wasm.h consumers.
  trap_surface.zig        ~250 lines  Trap, TrapKind, mapInterpTrap,
                                      allocTrap, wasm_trap_new/delete/
                                      message, wasm_byte_vec_delete.
  vec.zig                 ~350 lines  ByteVec / ValVec / ExternVec
                                      shapes + the WASM_DECLARE_VEC
                                      family of new_empty/new_uninit/
                                      new/copy/delete/etc.
  instance.zig            ~650 lines  Engine / Store / Module /
                                      Instance / Func / Extern shapes,
                                      instantiateRuntime, all *_new /
                                      *_delete + wasm_func_call +
                                      wasm_instance_exports.
  wasi.zig                ~300 lines  zwasm_wasi_config_*, the 16
                                      thunks, lookupWasiThunk.
```

`pub export fn`s remain in their carved-out files; the C
linker symbols don't change. Tests follow each export to its
new file.

## Consequences

- §9.5 (Phase 5) gains a row 5.0 (or whatever the first
  available slot is when §9.5 expands) for the file split.
- The split commit will be substantial (~2000 lines moved
  across 5 files) — expected to run as one focused chunk
  with a single three-host gate.
- The Phase-4 boundary commit (§9.4 / 4.11–4.12) closes
  with the block finding documented but not yet repaired.
- File-size gate (`scripts/file_size_check.sh --gate`) will
  flag wasm_c_api.zig until the split lands. The gate's
  hard-cap fence is informational at the boundary commit
  per this ADR; the next pre-commit is expected to do the
  split or proceed under explicit exception.

## Alternatives considered

### Alternative A — Split mid-Phase-4-boundary

- **Sketch**: do the carve-out as the next chunk, before §9.4
  / 4.11 closes.
- **Why rejected**: a ~2000-line code move under the boundary
  commit's three-host gate has a non-trivial chance of
  introducing import cycles or test breakage. The boundary
  commit should reflect the phase's deliverable, not absorb
  significant refactor risk.

### Alternative B — Loosen the §A2 hard cap

- **Sketch**: amend §A2 to allow this file specifically; or
  raise the hard cap globally.
- **Why rejected**: the cap exists to keep modules
  comprehensible. wasm_c_api.zig genuinely has 5 distinct
  responsibilities (trap surface, vec ABI, instance lifecycle,
  binding-internal helpers, WASI wiring); the split is a
  cleanup that pays back, not a workaround.

### Alternative C — Drop tests inline; promote them to a
sibling test file

- **Sketch**: move the ~95 tests to `src/c_api/tests.zig`,
  cutting wasm_c_api.zig to ~1700 lines.
- **Why rejected**: tests-next-to-code is the project
  convention. Moving them just to dodge the cap optimises
  for the line count metric, not the comprehensibility one.

## References

- ROADMAP §A2 — file-size cap.
- `private/audit-2026-05-02-p3.md` — Phase-3 boundary audit
  flagging the file as `soon`.
- `private/audit-2026-05-02-p4.md` — Phase-4 boundary audit
  (this commit) — elevates to `block`.
- `audit_scaffolding/SKILL.md` § "Procedure" — the block-with-
  load-bearing-change branch.
