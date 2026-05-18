# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_close_plan.md`](phase9_close_plan.md)
   §6 (revised 2026-05-18). ADR-0069 chunked plan; arm64 Class C
   bundled (b)-e-1 + (b)-e-2 landed (this commit).
2. **READ NEXT** ADR-0069 §"Phase 2 — Class C indirect-result-
   pointer" + ADR-0017 (2026-05-18 amend) + ADR-0026 (x86_64,
   will amend next).
3. `git log --oneline -10`. Latest: arm64 Class C ABI bundled.
4. `bash scripts/p9_simd_status.sh` — live status.
5. `cat .dev/debt.md`. `now`: D-079, D-133.

## Active state — arm64 Class C landed; x86_64 (b)-e-3 next

D-126 + D-144 closed cycle 4; §9.9-III [x] cycle 5. D-145
closed cycle 10. D-135 + D-146 + D-137 closed. arm64 Class C
ABI (callee + caller MEMORY-class indirect-result-ptr) landed
this commit; Mac aarch64 spec_assert 25317/0/696 unchanged
(the existing 8 manifest skip-impl multi-result lines remain
skip-impl until chunk (b)-e-4/5 lands entry.zig FuncRet_iXiXiX
+ runner dispatch + manifest re-bake).

What this chunk delivered structurally: callee prologue STR X8
+ epilogue LDR X16 + STR via X16; caller LEA X8 = SP+buffer_off
before BL + LDR-from-buffer capture; symmetric trigger
`sig.results.len > 2`. fac/fac.0.wasm internal helper func[6]
`(i64,i64) → (i64,i64,i64)` now compiles + runs without
SEGV.

### Next-session active task — x86_64 (b)-e-3 mirror

Dependency chain to §9.9 [x]:

```
x86_64 bundled (b)-e-3 callee + caller (ADR-0026 amend)
  ↓
(b)-e-4 entry.zig FuncRet_iXiXiX + runner dispatch +
        distiller supported_multi
  ↓
(b)-e-5 manifest re-bake; verify PASS-count delta
  ↓
D-140 large-sig 16-result (ADR-0069 §Phase 3)
  ↓
§9.9 [x]  →  §9.12 substrate audit (USER GATE)  →
§9.13-0 windowsmini reconcile (LOOP)  →
§9.13 Phase 10 entry gate (USER GATE)
```

**Next concrete task**: x86_64 mirror of bundled (b)-e-1 +
(b)-e-2.
1. ADR-0026 amendment documenting RDI hidden-result-pointer
   prologue slot.
2. x86_64 callee prologue: capture RDI to frame slot.
3. x86_64 op_call caller: pre-allocate buffer in outgoing-
   args region + LEA into RDI before CALL.
4. x86_64 op_control epilogue MEMORY-class branch: read
   captured RDI + store results via `*RDI[i*8]`.
5. Byte-level test mirroring the arm64 bundled test.

Reference: arm64 commit `425e2607` (this chunk) is the
canonical pattern. x86_64's symmetric pieces live in
`src/engine/codegen/x86_64/{emit,op_call,op_control,
prologue}.zig`. SysV ABI §3.2.3 specifies RDI = hidden
first-arg for composite returns > 16 B; Win64 uses RCX
(deferred to §9.13-0 per ADR-0049 + ADR-0056 + ADR-0065
amendments).

### Discipline reminders

No `--no-verify`. 2-host per chunk (Mac + ubuntunote);
windowsmini at §9.13-0 (post-§9.12).

### Outstanding `now` debts

D-079; D-133. Blocked by Class C landing: D-094 (closes
after x86_64 (b)-e-3) / D-140 (Phase 3 large-sig).
Relocated to §9.13-0: D-084 / D-028 / D-136.

## Sandbox + References

`~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
Per-chunk 2-host; windowsmini Phase-boundary batch.

PRIMARY: [`phase9_close_plan.md`](phase9_close_plan.md).
ADRs: [`0017`](decisions/0017_jit_runtime_abi.md) (2026-05-18
amend) / [`0026`](decisions/0026_x86_64_r15_cc_pivot.md)
(next-cycle amend target) / [`0065`](decisions/0065_wasm_1_0_instance_work_phase9_rescope.md)
/ [`0066`](decisions/0066_cross_module_import_bridge_thunks.md) §A2
/ [`0067`](decisions/0067_ubuntunote_native_x86_64_gate_host.md)
/ [`0068`](decisions/0068_dual_view_table_storage_fix.md)
/ **[`0069`](decisions/0069_multi_result_return_abi.md)** §Phase 2.
Lessons: [`2026-05-18-class-c-callee-without-caller-segvs-fac.md`](lessons/2026-05-18-class-c-callee-without-caller-segvs-fac.md)
(bundling rule).
