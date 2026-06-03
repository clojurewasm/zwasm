# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **11 IN-PROGRESS — WASI 0.1 full + bench infra** (Phase 10 DONE; §11 table: 11.0✓ / 11.1 WASI / 11.2
  bench / 11.3 SIMD-gap ✓ / 11.4→Phase 15 / 11.P). §11.P windowsmini reconcile surfaced a **systemic Win64 JIT
  bug** → bundle (below).
- **§11.P windowsmini test-all** (first since §11.1, against `00cd6d1f`): fd.zig compile fix WORKED (Windows test
  build compiles + runs); spec suite + WASI all PASS. But the unit-test layer FAILED: `run test 2213 pass, 12 fail,
  19 crash`. Two named aborts, both **Phase-10 JIT features on the Win64 ABI for the first time** (windowsmini is
  phase-boundary-only, so Win64 JIT EH/GC was NEVER exercised before): (1) `throw_trampoline` test SEGV; (2)
  `runner_gc_test … struct.new_default + ref.is_null → 0` returns 1 (wrong).
- **ROOT CAUSE (subagent-confirmed, unifying)**: x86_64 code calling a `callconv(.c)` helper **hardcodes SysV arg
  regs (RDI/RSI/RDX/RCX)** instead of the Cc-aware `abi.current.arg_gprs[]`. On Win64 the helper reads args from
  RCX/RDX/R8/R9 → garbage → `jitGcAlloc` returns null → `ref.is_null`=1 (BUG 2, production, HIGH conf, **17 GC/EH
  emit files**). BUG 1 = the `throw_trampoline` TEST wrapper `invokeTrampolineWith` is SysV-only (tag→RDI, no
  `.windows` arm); the *production* `.windows` trampoline arm is correct (test-only fix, MED conf).
- **Fix is SysV-no-op-safe**: `abi.current.arg_gprs[0..3]` == `{rdi,rsi,rdx,rcx}` on SysV (abi.zig:60 + test),
  so swapping literals → `arg_gprs[N]` is byte-identical on Mac+Linux (existing byte tests prove it) and only
  corrects Win64. Regalloc pool ∩ arg_gprs = ∅ (comptime-enforced) → no shuffle-collision hazard.
- **Prior gates GREEN**: ubuntu test-all `173ca8af` OK; Mac local green. windowsmini = the only Win64 host
  (~90min/run, SSH, NO local Win64 execution → cross-compile-check only).

## Active bundle

- **Bundle-ID**: 11.P-win64-jit-arg-marshal
- **Cycles-remaining**: ~2 (cycle 1 = land the 17-file swap + test-wrapper Win64 arm; cycle 2 = verify windowsmini
  green, iterate on any residual Win64 alignment in the EH test wrapper)
- **Continuity-memo**: 17 x86_64 GC/EH emit files (struct_new_default, struct_new, array_{new,new_default,
  new_fixed,new_data,new_elem,copy,fill,init_data,init_elem}, ref_{test,test_null,cast,cast_null}, br_on_cast,
  throw) marshal args via hardcoded RDI/RSI/RDX/RCX → replace with `abi.current.arg_gprs[N]` (rdi=0/rsi=1/rdx=2/
  rcx=3). + throw_trampoline.zig:443 `invokeTrampolineWith` x86_64 arm → add `.windows` case (tag→RCX; production
  trampoline at :357 already Win64-correct). Win64 arg regs: RCX/RDX/R8/R9; shadow space handled by prologue.
- **Exit-condition**: windowsmini `test-all` → `[run_remote_windows] OK` (0 fail/crash in run-test for the GC/EH
  JIT tests). Tracked as **D-NNN** (file at commit).

## Next task (autonomous)

**NEXT** = cycle 1 of the bundle: apply the 17-file `abi.current.arg_gprs[]` swap + throw_trampoline test-wrapper
`.windows` arm. Verify (a) `zig build test` Mac green + byte tests unchanged (proves SysV-no-op), (b) `zig build
test -Dtarget=x86_64-windows-gnu` compiles. Commit pair + push + kick windowsmini `test-all` (NOT ubuntu — Win64 is
the target) + re-arm. Next cycle: read `/tmp/windows.log` for the two tests' verdicts.

## Deferred / open debt (none a Phase-11 blocker except the bundle)

- **D-245** host→JIT callee-saved: arm64 + x86_64-SysV no-arg-void FIXED + regression-gated; win64 + arg'd variants
  = remainder. (Related family to the new Win64-arg-marshal bundle but distinct: D-245 = caller-saved preservation;
  bundle = arg-reg routing.)
- **D-246** §11.3 → Phase 15: arm64 dot/extmul JIT-emit hole. **D-211** GC-on-JIT precise rooting → Phase 15.
- **D-238** x86_64-SysV cross-instance EH thunk. **D-244** SIMD interp-free by design (partial). **D-210** /
  **D-234** / D-237 / D-229 / D-231 / D-204 / D-209 / D-213 (note).

## Step 0.7 (next resume)

This turn lands the bundle cycle-1 commits → windowsmini `test-all` kick fires against the turn HEAD. Step 0.7
next cycle: read `/tmp/windows.log` → did `throw_trampoline` + `runner_gc_test` GC tests go green? (ubuntu/Mac were
already verified; this is a Win64-targeted turn so the kick is windowsmini.) Prior ubuntu `173ca8af` = GREEN.

**Gate hygiene**: Step-5 Mac = `bash scripts/mac_gate.sh`. Win64 cross-compile-check: `zig build test
-Dtarget=x86_64-windows-gnu` (compile-only; "unable to execute" run-error = compile PASSED). ReleaseSafe
`--engine=jit` repro: `zig build -Doptimize=ReleaseSafe && zig-out/bin/zwasm run --engine=jit <fixture>`.

## Key refs

- ROADMAP line 83 (4-platform JIT incl. x86_64-windows = IN SCOPE). `src/engine/codegen/x86_64/abi.zig` (current/
  sysv/win64 namespaces; arg_gprs). `src/engine/codegen/shared/throw_trampoline.zig`.
- Lessons: `2026-06-03-windowsmini-reconciliation-catches-os-only-compile-drift` (the phase-boundary-drift rule
  that predicted this); + a new Win64-arg-marshal lesson (file at commit).
