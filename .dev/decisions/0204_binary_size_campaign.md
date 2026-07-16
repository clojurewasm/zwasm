# ADR-0204: Binary-size campaign — host-bridge thunk collapse + table-driven emitter completion

- **Status**: Implemented (D1 stage 1 shipped in #145: jit_host_bridge
  −82%, CLI −21% ReleaseSafe / −8% ReleaseFast; D1 stage 2 re-scored
  ~200 KB → demand-driven in D-522; D2 size premise refuted by stage-A
  measurement → D-521 discharged, see 2026-07-16 amendment below; D3 not
  pursued. Released as v2.2.1.)
- **Date**: 2026-07-16
- **Front**: binary-size (D-521 / D-522; dogfooding request `from_cljw_05`)
- **Findings base**: symbol-attribution measurement 2026-07-16 (below);
  cljw-side measurement in `private/dogfooding_handover/from_cljw_05.md`.

## Context

cljw's binary-size campaign (cljw ADR-0172) measured zwasm as the largest
single component of its shipped binary: ~2.99 MB of `__text` (44% of all
code), with a 4.0 MB budget line, and sent three finished-form requests
(mailbox `from_cljw_05`, 2026-07-16): (1) table-driven arm64 emitter,
(2) comptime-gate unused api surfaces, (3) optional module split. Hard
constraints from the request: **no behaviour change, no JIT-output change,
no API break** — size-neutral refactors only, no urgency coupling.

zwasm-side measurement (macOS arm64 ReleaseSafe CLI, 5,282,584 B at
71cccba76; `nm -n` next-addr − addr, bucketed by prefix) confirms and
*re-prioritizes* the cljw attribution:

| Bucket | Size | Syms | Dominant content |
|---|---|---|---|
| `api.*` | 1,428 KB | 5,630 | `api.jit_host_bridge` alone = **1,311 KB / 5,453 syms** |
| `engine.*` | 1,248 KB | 516 | `engine.codegen.arm64.emit.compile` alone = **707 KB** (one symbol) |
| everything else | ≤101 KB per bucket | — | Io / debug / feature / instruction / … |

The `size_history.yaml` series independently confirms the drift: ReleaseFast
`base` was 1,972,696 B at the last record (6979c838, 2026-06-12) and is
3,884,856 B at this kickoff (71cccba76) — the binary doubled in a month
(AOT campaign + host-bridge growth), unnoticed because the series' cadence
is phase-boundary.

Inside `jit_host_bridge`, the cost is a comptime thunk cross-product, not
API surface: `t2fp__struct.f` × 2,880 instantiations = 900 KB,
`t1fp__struct.f` × 960 = 282 KB, `t0..t4__struct.f` × 320 each ≈ 124 KB.
The x86_64 backend is already target-comptime-gated out of the arm64 binary
(0 B), and `enable_component` already comptime-strips the CM subsystem at
`-Dwasi=p1` (ADR-0073 DCE substrate) — so cljw's request (2) as literally
stated ("gate unused api surfaces") is *already mostly satisfied*; what an
embedder actually pays for is the thunk cross-product, which every
JIT-enabled embedder pays regardless of which api slice it imports.

## Decisions

### D1 — Collapse the `jit_host_bridge` thunk cross-product (D-522, lever #1: ~1.2 MB potential)

Reduce the comptime instantiation space of the host-call trampolines
(`t0..t4`, `t1fp`, `t2fp` families) toward a small set of runtime-generic
trampolines (argument marshalling driven by a per-signature descriptor
table instead of one monomorphized function per type combination).
Constraints: no api break, no per-call runtime regression beyond noise
(bench-gated per ADR-0181 series).

Characterization (2026-07-16, `src/api/jit_host_bridge.zig` — 344 lines
generating 5,453 symbols): the instantiation axes are
`arg-kinds × RetKind(5) × MAX_HOST_SLOTS(64)` — t2fp = 3×3×5×64 = 2,880,
t1fp = 3×5×64 = 960, t0..t4 = 5×5×64 = 1,600. Two independent findings:
- **The ×64 slot axis is 94% of the product** and exists only so each
  thunk comptime-hardcodes its slot index K (the JIT call passes only
  `rt` + wasm args). Collapsing it means conveying K at runtime — e.g.
  the call site materializes the slot index (or payload pointer) into a
  scratch register before `BLR`. That changes zwasm's own emitted
  call sequence (internal, version-keyed via the AOT cache — allowed),
  NOT the embedder-facing api.
- **t1fp/t2fp inline the whole payload-lookup + invokeCb body per thunk**
  (~300 B each) where the GP thunks delegate to a shared `bridge()`
  (~88 B each). A shared FP-bridge delegation alone — no ABI/JIT change
  at all — cuts ~0.8 MB and is the natural stage-1 increment; the slot-
  axis collapse (further ~0.4 MB) is stage 2.

### D2 — Complete the table-driven arm64 dispatch; delete the legacy switch (D-521, lever #2: ~500 KB potential)

> **Amended 2026-07-16 — size premise REFUTED by stage-A measurement.**
> Converting `dispatch()` to a comptime fn-pointer table left
> `emit.compile` at 707 KB and grew the binary +28.8 KB (reverted). The
> 707 KB symbol is *aggregation* of once-called inlined handlers, not
> duplication — out-lining is size-neutral. See lesson
> `2026-07-16-outlining-once-called-handlers-size-neutral.md`. D-521 is
> discharged; the per-op-file migration of the remaining ~161 switch arms
> stays on the ADR-0074 maintainability trajectory, NOT as a size lever.
> The original text below is retained for the record.

`engine.codegen.arm64.emit.compile` (src/engine/codegen/arm64/emit.zig,
~2,100-line fn) is a ~161-arm switch over `ZirOp` whose arms mostly
delegate to already-extracted `op_*.zig` handlers. The table-driven
substrate already exists: `dispatch_collector` (ADR-0074) dispatches
registered ops first and falls through to the switch. Finish the
registration for all remaining ops and delete the fall-through switch.
Same treatment applies to the x86_64 twin (`x86_64/emit.zig` `compile()`)
— it costs the Linux/Windows binaries, not the Mac one. Acceptance gate:
**emitted JIT bytes identical** — `zig build test-aot-diff` (63/63),
`zig build fuzz-diff` lanes, full `test-all` on 3 OSes.

### D3 — Module split (cljw request 3): NOT pursued as its own workstream

Only adopted if it falls out of D1/D2 naturally (cljw's own framing). No
architecture contortion for a hybrid ReleaseSmall build.

## Consequences

- Debt rows D-521 (emitter table completion) + D-522 (thunk collapse) track
  the stages; each stage = own `develop/<slug>` PR with the standard CI gate.
- Baseline recorded to `bench/results/size_history.yaml` at kickoff
  (`record_binary_size.sh`, base + lean variants); re-run per stage-merge so
  the size delta of each lever is OBSERVED (per-merge bench policy).
- Success bar (finished-form): arm64 ReleaseSafe CLI `__text` shrinks by
  the two levers' measured share without any JIT-output or api change;
  cljw re-measures on its normal pin-bump cadence — no coupling.
- Reply posted to the mailbox (`to_cljw_05.md`): confirms receipt, shares
  the re-prioritized attribution (thunk cross-product ≫ api-surface gating;
  x86_64 emitter already exists and is already target-gated).
