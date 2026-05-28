# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `86e5bfaf` — feat(p10): 10.R ref.as_non_null JIT emit
  handlers + dispatch registration (cycle 50 scaffolding; §2
  deviation acknowledged, bounded — execution test = cycle 51's
  source commit). Mac aarch64 test exit 0; count tests pass at
  arm64=350 / x86_64_ctx=397. cycle-49 ubuntu green at `c7dfeb2b`.
  cycle-50 ubuntu kick pending (Step 0.7 next cycle).
- **D-193 FULLY DISCHARGED** (cycle 47, `eccab477`): all ~23
  Mac-aarch64-only test gates cleared over cycles 41-47; D-180-hazard
  coverage gap gone; 0 `skip.blocker(.@"D-193")` sites repo-wide.
- **Active debt rows**: 17 — all `blocked-by:` with named barriers.
  Zero `now`-status rows.

## Active bundle

- **Bundle-ID**: 10.R-function-references
- **Cycles-remaining**: ~3
- **Continuity-memo**: ADR-0123 (Proposed) — call_ref/return_call_ref
  gated on Accept. **Cycle-50 landed scaffolding** (`86e5bfaf`):
  arm64/x86_64 `ref_as_non_null.zig` emit handlers + dispatch
  registration; count tests at 350/397; §2 deviation note (no
  execution test yet). Cycle-49 verified findings: JIT traps surface
  as generic `Error.Trap` (entry.zig:173/188); `trap_kind` is
  diagnostic-only; arm64 ref.func/ref.null are inline-emit at
  emit.zig:789/807 (per-op file pattern not used on arm64 for them);
  callI32_i64 exists (entry.zig:547) for u64-arg entry. **Cycle-51
  NEXT chunk — execution test** that closes the §2 gap: write the
  trap-on-null case first (simplest, no funcref-entry plumbing needed)
  in `src/engine/codegen/shared/entry.zig` (file already has the
  comptime native_emit binding from cycle 43). Test shape:
  `(func (result i32) ref.null funcref ; ref.as_non_null ; ref.is_null ; end)`
  → expect `callI32NoArgs(...)` returns `Error.Trap`. Resolve at
  test-write time: (a) `ref.null`'s payload encoding for funcref
  RefType (check zir.zig + arm64/emit.zig:789 — payload is probably 0
  for funcref or an enum like `@intFromEnum(zir.ValType.funcref)`),
  (b) liveness model with identity-passthrough (vreg 0 lives pc 0-2:
  ref.null→ref.is_null; vreg 1 lives pc 2-3: ref.is_null→end; slots
  `[_]u16{0,1}` n_slots=2 — both physically distinct since they
  overlap at pc 2), (c) regalloc.Allocation shape (mirror entry.zig
  existing tests like 2147+). Then add the non-null case
  (ref.func 0 inside a 2-func module — needs funcptr_base setup like
  the linker.zig:524 test pattern).
- **Exit-condition**: function-references spec return/trap fixtures run
  (not just invalid=12); the 5 ops execute under interp + JIT on both
  arches. (Autonomous portion: 3 null-ops JIT green; call_ref family
  after ADR Accept.)

## Active task — 10.R: JIT-emit the null-manipulation ops

Survey done (cycle 48): the 3 null-ops are parsed+validated+interpreted
(generic reftype) but **JIT-stubbed**; call_ref/return_call_ref are
parse-only (gated on ADR-0123). Per ADR-0123 D2 the null-ops are
representation-independent → unblocked.

**NEXT chunk** — JIT-emit `ref.as_non_null` (arm64 + x86_64). Smallest
red: a JIT-compiled function using ref.as_non_null currently hits the
unregistered-handler path (dispatch slot null per survey). Emit a
null-check: if the popped ref (`Value.ref` u64, null=0) is 0 → branch
to the trap stub (`NullReference`); else leave it in place (identity).
Register the emit handler in the dispatch table (likely via
`feature/function_references/register.zig`, currently an empty
placeholder — wiring it is part of this chunk). Then `br_on_null` +
`br_on_non_null` (null-conditional branch, reuse br_if fixup machinery)
as the following chunk. Mind the D-193 lesson: no arm64-pinned byte
asserts — test via execution or comptime per-arch.

## Larger §10 work (blocked / later)

- **10.M memory64** — spec passes; remaining = multi-memory
  (`memories: []MemoryInstance`) + clang_wasm64 realworld (D-179).
- **10.E EH** — blocked: exnref ValType (ADR §4 deviation) + runner
  cross-module register (D-188 / D-192).
- **10.G WasmGC op-corpus** — D-179-blocked (wabt 1.0.41+). Substrate
  landed end-to-end (parse + struct/array ops + β mark-sweep + roots).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (HEAD `96a17d5a`; gate-only cycles unchanged)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(fail2) exception=4(fail4)
[function-references] invalid=12 (all pass)   <- return/trap fixtures not yet run (10.R target)
```

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- ADR-0123 — Status: Proposed. Accept flip unblocks call_ref /
  return_call_ref impl (the 3 null-ops proceed without it). Low-risk
  decision (avoids ValType overhaul; defers typed-ref to 10.G).
- D-179 — wabt 1.0.41+ blocks GC corpus + clang_wasm64 realworld.
- D-188 / D-192 — EH blocked on exnref ValType + cross-module register.
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0122 (test skip categorization) — D-193 discharge complete.
- ADR-0115 / ADR-0116 (GC heap / roots+RTT+i31) — check for
  function-references typing coverage during 10.R survey.
- ADR-0076 (D1 gate / D2 single-push / D3 ubuntu kick).
- ROADMAP §10 rows 10.R / 10.TC; `.dev/phase_log/phase10.md`.
