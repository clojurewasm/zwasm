# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `8f8a01ec` — interp tail-call trampoline (10.TC; D-187
  discharge). wasm-3.0-assert tail-call now 31/31 assert_returns
  pass; CallStackExhausted at deep tail-recursion eliminated.
- **ROADMAP §10 progress**: 7/13 DONE (10.0/10.C9/10.J/10.F/
  10.Z/10.D/10.T), 4 IN-PROGRESS (10.M/10.R/10.TC/10.E with
  10.E core + 10.TC same-module direct + indirect + interp
  trampoline + 10.E spec runner parser→executor primitives
  substantively done), 2 Pending (10.G/10.P).
- **Active debt rows**: 17 — all `blocked-by:` with named
  structural barriers. Zero `now`-status rows.

## D-187 discharge — observable delta

Source commit `8f8a01ec`:
- `runtime.zig::Runtime.pending_tail_call: ?*const zir.ZirFunc`
  signal field.
- `mvp.zig::signalTailCall` helper — sets signal + marks caller
  frame done + clears labels. Used by `returnCallOp`
  + `returnCallIndirectOp` (same-rt) + `returnCallRefOp` (same-rt).
  Host-import + cross-rt paths keep prior recursive shape.
- `dispatch.zig::run` outer trampoline loop — after inner instr
  loop exits on `frame.done`, polls `pending_tail_call`, pops
  caller, pops args, alloc'd fresh callee locals, pushes callee,
  switches `instrs` to callee body, continues in same Zig stack
  frame. Mid-chain trampoline-alloc'd locals freed at next
  switch; last freed at exit (defer).
- Test marker `test/spec/wasm_3_0_manifest.zig` "tail-call bisect"
  retightened to `pass == 31, fail == 0`. Existing
  `src/interp/trap_audit.zig` chained-A→B→C test stays green
  (frame_len invariant holds under both old + new shapes).

Operand-base propagation: validator-guaranteed args-only at
return_call site → `callee.operand_base = caller.operand_base`
through chain → final results land at original
Instance.invoke `op_base`. No `tailReturn` needed in trampoline
path; results placement is structural.

## Next sub-chunk candidates (names only)

- **10.E spec runner: assert_trap execution** — expect runOne
  to return RunError with trap-class discrimination; verify
  EXPECTED trap kind per directive.
- **10.E spec runner: assert_invalid execution** — surface
  validator's reject-class; manifest's 4 assert_invalid
  (return_call.[1-4].wasm) + surrounding ones.
- **10.R-3** — `br_on_non_null` (unblocks 10.R-4 `call_ref` and
  10.R-5 `return_call_ref` per D-186).
- **10.G WasmGC** — large multi-cycle bundle; design plan +
  ADRs (0115/0116/0117) already shipped.
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- 10.G-4 (struct ops) — blocked-by GC heap impl.
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.
- D-186 — `return_call_ref` blocked-by 10.R-3/4/5.

## Key refs

- ADR-0017, ADR-0026, ADR-0109 (Native Zig API; governs the
  runOne + Instance.invoke shape that hosts the trampoline),
  ADR-0111, ADR-0112 (10.TC JIT codegen scope), ADR-0113 §A,
  ADR-0114 D1/D5/D6, ADR-0119, ADR-0120.
- ROADMAP §10, Phase log `.dev/phase_log/phase10.md` Row 10.T /
  10.TC / 10.E.
- Lessons (recent): `.dev/lessons/INDEX.md` entries 2026-05-26
  (shared-facade-host-dispatched) + 2026-05-28 (5 EH lessons).
