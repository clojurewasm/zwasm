# EH-on-JIT real blocker is the per-module validate/lower/emit stack, not handler dispatch

**Date**: 2026-06-03 · **Phase**: 10.E

## Observation

The EH-on-JIT return-fail (`exception-handling/try_table.1.wasm`, all 33
throw-catch asserts JIT-skipped) is NOT the handler landing-pad dispatch. That
dispatch is fully implemented: `throw_trampoline.zig` `trampolineCore` resolves
the catching frame's CodeMap entry, sets `eh_handler_sp/fp/pc` + `eh_handler_active=1`,
and `zwasmThrowTrampoline` (arm64 + x86_64 SysV + Win64) branches on
`eh_handler_active` and `BR/JMP`s to the landing pad. The module **docstring**
(lines 9-35) still narrates "cycle 3c-ii / handler ALSO traps / 3c-iii deferred"
— **stale comment-rot**; 3c-iii landed. A code survey that trusts the docstring
mis-diagnoses the gap (it did, this session). **Fix the docstring when next
touching that file.**

The actual blocker is a **per-module blocker stack** (the recurring late-Phase-10
JIT-corpus shape, cf. `2026-06-02-jit-corpus-late-phase-is-per-module-blocker-stacks`):
the module is rejected at the FIRST failing function during compile, so a single
fix only advances to the next blocker — the corpus headline number doesn't move
until the WHOLE module compiles + runs.

try_table.1.wasm stack (compile order):
1. **func[6] validate StackTypeMismatch** — JIT `tags_slice` was defined-only;
   imported tags shift the index space → wrong tag params. FIXED `3b668110`
   (compile.zig full imports-first space, both compile paths). ✓
2. **func[24] try_table emit UnsupportedOp** — `eh_landing_pads`/`eh_catch_entries`
   null → `try_table.zig:53/54/66 orelse UnsupportedOp`. The lowerer
   (`lower.zig:202`) sets them only when `landing_pads.items.len > 0`; a
   catchless / zero-catch-clause try_table produces none. NEXT.
3. **func[36] return_call_indirect UnsupportedOp** — tail-call-in-try_table emit gap.
4. **try_table.2 imported-mismatch returns 0** (separate module) — cross-module
   imported-tag matching at runtime; may be the same tag-index class as #1.

## How to apply

When a JIT-corpus module shows pass=0/skip=N, the blocker is almost always a
compile reject (validate or emit UnsupportedOp), found via stderr
`compileWasm: func[K] ... → <err>` / `arm64/emit: failing op \`X\``. Don't survey
the *runtime* dispatch first — find the compile reject, fix it, re-measure, repeat.
Trust the CODE over docstrings for "what's implemented".

Related: [[2026-06-02-jit-corpus-late-phase-is-per-module-blocker-stacks]],
[[2026-06-02-gti-tied-to-heap-need-misses-func-subtyping]] (D-232/D-235 = the
same imports-shift-the-index-space class, on the type index).
