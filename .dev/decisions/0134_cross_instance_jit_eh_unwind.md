# ADR-0134 — Cross-instance exception unwinding on the JIT backend

**Status**: Accepted (design; implementation in 10.E-eh-on-jit bundle, Cause B)

**Date**: 2026-06-03

**Relates to**: ADR-0114 (EH design — D5 FP-walk unwind, D7 `*TagInstance`
pointer-identity, cross-module "day-1" removal condition), ADR-0128
(Phase 10 = 100% both backends), ADR-0066/D-225 (cross-module bridge
thunk), ADR-0017 (pinned `*JitRuntime` in X19/R15). Closes the JIT half
of ADR-0114's `cross_module_throw_propagation.wat` removal condition.

## Context

ADR-0114 D7 specifies cross-module exception propagation works "day-1"
via `*TagInstance` pointer equality. The **interp** satisfies this: an
imported tag resolves to the SOURCE runtime's `*TagInstance`
(`instantiate.zig:1266` `tags_arr[ti] = src.source_runtime.tags[...]`),
so a module-1 throw and a module-2 catch on the imported tag compare the
same pointer (`mvp.catchTagMatches`). The interp's frame walk is
per-frame per-`*Runtime`, so each catch lookup is scoped to that frame's
instance.

The **JIT** EH unwinder (ADR-0114 D5; `shared/unwind.zig`,
`throw_trampoline.zig`) is **single-instance**: `trampolineCore` receives
exactly one `rt` (the throwing instance, = module 1 after the D-225
bridge-thunk swaps the pinned `*JitRuntime`), and the FP-walk consults
that one instance's exception table + tag map at EVERY frame. When the
walk crosses the thunk boundary into the caller (module 2), it still
queries module 1's (empty) table → no match → uncaught → the thunk RETs
normally → the caller resumes past the call with a leaked value. Spec
fails: `catch-imported`, `imported-mismatch` (try_table.wast). The
`unwind.zig:26-31` comment deferred this to "Phase 11+" — that note is an
implementation aside, NOT an ADR; it loses to ADR-0114's Phase-10
removal condition + ADR-0128's both-backends mandate.

Two distinct gaps cause the miss:

1. **Frame unreachable** — the arm64 thunk establishes a frame
   (`STP X29,X30,[SP,#-80]!`, saving the caller's call-site LR + FP) but
   never `MOV X29,SP`, so the thunk frame is NOT FP-linked. The callee's
   prologue therefore saves the *caller's* X29 (skipping the thunk) with
   a saved-LR that points INTO the thunk (post-BLR). The walk reaches the
   caller's frame carrying a thunk PC, not the caller's call-site PC → the
   caller's try_table (keyed on its call-site PC) can't be found. The
   caller's real call-site return address is buried in the unlinked thunk
   frame at `[thunk_sp+8]`.
2. **Single-instance dispatch** — even with the caller frame reachable,
   the walker uses one table + one tag map; it must switch to each
   frame's OWN instance, and tags must compare by a CROSS-instance
   identity (module 1's local tag idx vs module 2's local catch idx are
   not comparable through per-module local maps; Cause A's `tag_canon` is
   local-only).

## Decision

Implement per-frame-instance JIT unwinding in three coordinated parts.

### D1 — Thunk frame-linking (minimal ABI delta)

Add `MOV X29, SP` (arm64) / equivalent RBP-set (x86_64) to the bridge
thunk immediately after the frame-establishing store, so the thunk frame
joins the FP chain. Then the FP-walk traverses
`callee → thunk → caller`, and the caller's call-site return address
(saved by the thunk's frame-store at `[thunk_fp+8]`) becomes reachable as
the caller frame's PC. This is the smallest possible thunk change; the
existing reserved-invariant save/restore block (X19/X24..X28) is
untouched. Thunk byte size grows by one instruction per arch (update the
`thunk_bytes` constant + size asserts).

### D2 — Per-frame instance dispatch via a block-range registry

Build a process-global (per spec-run / per linker session) registry
mapping each instance's JIT code-block address range → that instance's
`*JitRuntime`. The walker resolves each frame's absolute PC to its owning
instance and switches the active exception table + tag map to that
instance's. A PC in a thunk arena (no owning module block) is a
pass-through frame (no try_table; skip lookup, keep walking). This keeps
instance identity OUT of the per-function prologue (rejected alternative
A) — only the walker + a setup-time registry change. The registry is
populated where instances are linked (the JIT spec runner / linker);
`trampolineCore` reads it instead of closing over one `rt`.

### D3 — Cross-instance tag identity (global id)

Generalize Cause A's per-module local `tag_canon` to a CROSS-instance
identity. Each instance carries a tag→global-id map; the throw site
resolves its local tag idx → global id, and each catch entry resolves its
local idx → global id; the unwinder compares global ids. The global id is
assigned at link time so module 1's `$e0` and module 2's
`(import "test" "e0")` (bound to the same source tag) receive the SAME
id — the JIT analog of the interp's shared `*TagInstance` pointer. This
requires a `tag_import_targets` resolution at JIT setup (analog of D-225's
`func_import_targets`), conveying the source tag's global id to the
importer. Cause A's local `tag_canon` becomes the degenerate
single-instance case (collapses to the same comparison).

### Sequencing (bundle cycles)

- **Cycle 1 (D3 foundation)** — ✅ DONE (`16a921a8`): global tag identity.
  `ExceptionTable.tag_canon` (u32 local) → `tag_ids` (u64); `setup` builds
  it over the full tag space (defined → own token address; imported →
  exporter id via `tag_import_targets`, else local rep token);
  `TagImportTarget` + `JitInstance.exportedTagTarget` +
  `sections.findExportedTagIndex`; `initLinked` += `tag_import_targets`;
  spec runner `jitResolveTagImports`. runner_test verifies an importer's
  aliased tags inherit the exporter's id. EH dir 32/2, global 794/3, no
  regression (Cause A now resolved via the real cross-module identity).
- **Cycle 2a (D2 engine)** — ✅ DONE (`cb55013e`): `ExceptionTable.lookupByIdentity`
  + `unwind.walk`'s optional `InstanceResolver` (null result falls back
  to the throwing table → regression-safe) + `eh_registry.zig`
  (process-global live-rt table; `resolve` finds the instance whose
  CodeMap contains the PC). `trampolineCore` threads the resolver. No
  production change (registry empty); unit-tested per-frame switch.
- **Cycle 2b (D1 + registration + handler-cmap)** — NEXT: thunk
  `MOV X29,SP` (arm64) + register each live instance in `eh_registry`
  (spec-runner pin sites) + resolve the catching instance's cmap from
  `handler_abs_pc` for the cross-instance SP-restore. `catch-imported` /
  `imported-mismatch` flip to pass on arm64 (Mac host).
- **Cycle 3** — x86_64 parity (thunk RBP-set + registry) + the
  `cross_module_throw_propagation.wat` edge fixture + 2-host gate.

## Alternatives considered

- **A. Per-function frame prefix** (store the pinned `*JitRuntime` in an
  8-byte prologue prefix on EVERY function). Rejected: changes every
  function's frame layout, `frame_bytes`, spill offsets, and the EH
  landing-pad SP-restore math across both arches — enormous blast radius
  for an EH-only concern. D2's block-range registry confines the change
  to the walker + a setup table.
- **B. Defer cross-instance EH-on-JIT to Phase 11** (deferred-allowlist
  per ADR-0133, matching the stale `unwind.zig` note). Rejected:
  contradicts ADR-0114's Phase-10 `cross_module_throw_propagation.wat`
  removal condition + ADR-0128's both-backends mandate; the interp
  already satisfies it day-1, so the JIT (second backend) owes the same
  in-phase. Deferring would be a workaround, not an "あるべき" fix.
- **C. Make the thunk fully frame-standard (its own prologue/epilogue
  pair + DWARF-style)**. Unnecessary: the thunk already saves FP/LR; only
  the missing `MOV X29,SP` blocks the walk. Minimal delta preferred.
- **D. Resolve tag identity by structural signature** (param/result type
  hash). Rejected for the same reason ADR-0114 alt-B was: spec §4.5.5 tag
  identity is by reference, not structure.

## Consequences

**Positive**: JIT cross-module EH reaches parity with the interp; closes
the JIT half of ADR-0114's removal condition; `tag_canon` (Cause A)
becomes a special case of the global-id model (no separate code path).

**Negative**: a process-global instance registry adds a small linker-time
structure + a per-frame lookup in the (cold) unwind path; the thunk grows
one instruction; cross-instance tag-id assignment adds a
`tag_import_targets` plumbing step. All confined to the EH + cross-module
link paths; the normal-return hot path and same-module calls are
unaffected.

## Removal condition

Retires (folds into ADR-0114's close) when `catch-imported`,
`imported-mismatch`, and `cross_module_throw_propagation.wat` are green
under `ZWASM_SPEC_ENGINE=jit` at the 2-host gate, with the
`unwind.zig` "Phase 11+" deferral comment updated to describe the
implemented per-frame dispatch.
