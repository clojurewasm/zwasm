# arm64 large-frame spill-offset overflow (D-331(B), go_regex)

**Observation.** go_regex func[1516] (Go's regexp compiler: 16070 vregs,
~21KB i64-locals area) JIT-compile-FAILED on arm64 with `SlotOverflow`, but
compiled fine on x86_64. The two-week-old hypothesis in the debt row — a
"liveness-vs-emit vreg-COUNT desync" — was a **red herring**: x86_64 shares
the same liveness (`slots.len`=16070) and passes, so the vreg COUNT was never
the problem.

**Real cause.** A large frame puts `spill_base_off=21056`, exceeding the
**W-form imm12 cap (16380)** = `4*4095` for `STR W [SP, #off]`. Several arm64
op-handlers hardcoded that cap (and the X-form 32760 / Q-form 65520) for
spilled-operand FRAME access and `return Error.SlotOverflow` above it —
WITHOUT the `frameAddrLarge` (materialise SP+off into a scratch GPR, then
`[scratch,#0]`) fallback that `gpr.zig`'s `gprLoadSpilled`/`gprStoreSpilled`
already use. x86_64's disp32 reaches any frame offset → immune. **That arch
asymmetry is the tell: x86_64 `compile` passes + arm64 overflows ⇒ an
immediate-offset budget, NOT a shared regalloc/liveness count.**

**The firing site is not the root.** The overflow surfaces wherever
`next_vreg`/offset first crosses the cap (op_call captureCallResult here), but
the FIX class is every spilled-operand frame access. Routed all siblings
through the existing large-off-safe `frame{Ldr,Str}{Gpr,Fp}` helpers
(byte-identical for off<=cap → no-spill output + byte-asserting tests
unchanged): op_call (captureCallResult all widths + memory-class returns +
homedCallerSavedSpillReload), op_memory (x3), op_table, op_alu_int wide-result,
emit.zig memory.grow.

**Rules.**
1. A codegen failure on ONE arch but not the other, with a shared
   liveness/regalloc input, points at a per-arch **immediate-offset / encoding
   budget**, not a count desync. Confirm by dumping the frame size
   (`spill_base_off`/`frame_bytes`), not the vreg count.
2. When adding a spilled-operand frame STR/LDR in an arm64 op-handler, use
   `gpr.frame{Ldr,Str}{Gpr,Fp}` (large-off-safe) — never inline
   `encStr*Imm*(.., 31, off)` with a hardcoded `> 16380/32760` cap. The cap is
   reachable: a fat function's `spill_base_off` alone can exceed it.
3. Scratch discipline: post-call/post-load, `spill_stage_gprs` (X14/X15,
   non-allocatable) are dead and safe as the address scratch; FP stores need a
   GPR address scratch + the `fp_spill_stage_vregs` value stage.
4. Trigger a large-frame fixture with thousands of i64 locals (each 8 B) to
   push `spill_base_off` past the cap; homing picks low-index locals, so a
   homed-local-at-high-offset fixture is unreliable — the call-result path is
   the deterministic minimal repro.

Fix `adb7b99a`; fixture `test/edge_cases/p9/large_frame/call_result_spill`.
Related: D-289 (the `frameAddrLarge` machinery), D-331(A) (separate go-runtime
poll_oneoff miscompile, still open).
