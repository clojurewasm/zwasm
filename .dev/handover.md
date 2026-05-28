# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `af477394` — fix(p10): cycle-51b fix-forward for
  D-180-class miss in x86_64 ref.as_non_null. Cycle-51 ubuntu kick
  FAILED (`expected Error.Trap, found 0` on Linux x86_64): my new
  bounds_fixups.append in ref_as_non_null.zig triggered the trap
  stub's R15 write, but R15 was uninit because the op wasn't in
  `usage.zig::usesRuntimePtr` whitelist. Added it → ubuntu re-kick
  GREEN at `af477394`. **ref.as_non_null JIT is now truly complete
  on both arches.** Lesson recorded:
  `.dev/lessons/2026-05-28-d180-detector-misses-bounds-fixups.md`.
- **D-193 FULLY DISCHARGED** (cycle 47, `eccab477`): all ~23
  Mac-aarch64-only test gates cleared over cycles 41-47; D-180-hazard
  coverage gap gone; 0 `skip.blocker(.@"D-193")` sites repo-wide.
- **Active debt rows**: 17 — all `blocked-by:` with named barriers.
  Zero `now`-status rows.

## Active bundle

- **Bundle-ID**: 10.R-function-references
- **Cycles-remaining**: ~2
- **Continuity-memo**: ADR-0123 (Proposed) — call_ref/return_call_ref
  gated on Accept. **ref.as_non_null JIT COMPLETE on both arches**
  (cycles 50/51/51b, last green at `af477394`). **Cycle-53 survey
  done** for br_on_null/br_on_non_null — full impl plan distilled
  below; cycle 54 executes with fresh context.

  **br_on_null impl (cycle 54a)** — files to create:
  `src/engine/codegen/{arm64,x86_64}/ops/wasm_3_0/br_on_null.zig`
  + register in `dispatch_collector_ops.zig` (count bumps +1 each).
  Pattern (mirrors ref.as_non_null's null-check, BUT label fixup
  instead of bounds_fixups → **no usesRuntimePtr whitelist needed**;
  br_if doesn't reference R15/X19 directly, just `ctx.labels[idx].pending`):
  - Pop src vreg manually; `gprLoadSpilled(src) → reg`.
  - arm64: `encCmpImmX(Xn, 0)` + `encBCond(.eq, 0)` placeholder;
    append fixup to `labels[depth].pending` (Fixup kind `.b_uncond`).
  - x86_64: `encTestRR(.q, Rn, Rn)` + `encJccRel32(.e, 0)`; append
    fixup `{byte_offset, insn_size=6}` to `labels[depth].pending`.
  - **Push src back** (non-null fall-through keeps ref on stack as
    spec-typed non-null; survey's mid-text confusion corrected at end).
  - Label-fixup patching happens at `emitEndIntra` (already wired by
    br_if). Survey cites: arm64 op_control.zig:281-360 + x86_64
    op_control.zig:759-860 for the canonical br_if pattern.

  **br_on_non_null impl (cycle 54b)** — same shape, inverse condition:
  `B.NE` (arm64) / `JNE` (x86_64); branch-taken passes ref AS the
  label value (so push src to label's value position before branch);
  fall-through drops ref. Subtler than br_on_null — verify with a
  separate cycle.

  **Test shape (cycle 54a)** — `entry.zig` test:
  `(func (result i32) block (result i32) (i32.const 7) (ref.null funcref)
  (br_on_null 0) drop (i32.const 42) end)`. Null path: br_on_null
  branches with i32=7 → returns 7. Non-null path: drop ref, push 42
  → returns 42. ZIR: `.block` op with `extra=(0<<8)|1` (0 params,
  1 result), `.@"i32.const"` payload=7, `.@"ref.null"` payload=0,
  `.@"br_on_null"` payload=0 (depth), `.drop`, `.@"i32.const"`
  payload=42, `.end`. Resolve at impl-time: exact `.block`
  ZirInstr.extra encoding (the survey's `(0<<8)|1` is likely; verify
  via existing block tests if any).

  Bundle exit after br_on_null+br_on_non_null: the 3 ADR-independent
  null-ops are all JIT-green; final pre-ADR-Accept chunk = wire
  function-references spec return/trap fixtures into the runner.
  call_ref/return_call_ref impl waits for ADR-0123 Accept flip
  (still in open-questions).
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
