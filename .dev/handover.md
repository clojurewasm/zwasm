# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_close_plan.md`](phase9_close_plan.md)
   §6 (revised 2026-05-18). ADR-0069 chunked plan + §9.13-0
   windowsmini relocation in §6 (d)/(f). D-135 + D-146 closed.
2. **READ NEXT** ADR-0069 §"Phase 2 — Class C indirect-result-
   pointer (D-094 + D-140)" + ADR-0017 (now includes 2026-05-18
   amendment specifying MEMORY-class prologue slot design).
3. **READ THE LESSON** [`.dev/lessons/2026-05-18-class-c-callee-without-caller-segvs-fac.md`](lessons/2026-05-18-class-c-callee-without-caller-segvs-fac.md)
   — operational constraint that (b)-e-1 (callee) and (b)-e-2
   (caller) MUST bundle.
4. `git log --oneline -10`. Latest: ADR-0017 amend +
   Class C re-scope chore.
5. `bash scripts/p9_simd_status.sh` — live status.
6. `cat .dev/debt.md`. `now`: D-079, D-133. Blocked by Class C
   landing: D-094 / D-140.

## Active state — Class C ABI design landed; impl bundled next

D-126 + D-144 closed cycle 4; §9.9-III [x] cycle 5. D-145
closed cycle 10. D-135 closed (entry.zig 2445 → 2103 LOC).
D-146 closed (commit `1fc07508` / `cd7f0c78`). D-137 fully
drained. Mac + ubuntunote bit-identical 25317/0/696 (= 201
skip-impl + 495 skip-adr).

ADR-0017 2026-05-18 amendment landed (this commit): documents
the MEMORY-class prologue X8 capture slot, frame placement,
X16 epilogue load (NOT X14 — avoids spill-stage clobber).
Design approved; arm64 implementation **must bundle (b)-e-1 +
(b)-e-2** per the lesson — landing callee-only SEGVs
`fac/fac.0.wasm` because internal helper func[6]
`(i64,i64) → (i64,i64,i64)` is JIT-to-JIT called by fac-ssa
without caller-side X8 setup.

### Next-session active task — bundled (b)-e-1 + (b)-e-2

Dependency chain to §9.9 [x]:

```
arm64 bundled (b)-e-1 (callee) + (b)-e-2 (caller)
  ↓
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

**Next concrete task**: arm64 bundled chunk:
1. EmitCtx fields (`return_is_memory_class`,
   `indirect_result_slot_off`)
2. arm64 prologue STR X8 (callee)
3. arm64 op_call MEMORY-class detection + outgoing-args
   buffer allocate + LEA X8 + read back (caller)
4. arm64 op_control epilogue MEMORY-class branch (callee)
5. Byte-level unit test + spec_assert exercising fac.0.wasm
   func[6] via fac-ssa runtime call

Survey notes from this cycle live in
`private/notes/p9-cat3-class-c-arm64-survey.md` (cycle's
deferred design context).

### Discipline reminders

No `--no-verify`. 2-host per chunk (Mac + ubuntunote);
windowsmini at §9.13-0 (post-§9.12). ADR-0026 (x86_64)
amends in (b)-e-3 cycle.

### Outstanding `now` debts

D-079; D-133. Blocked by Class C landing: D-094 / D-140.
Relocated to §9.13-0: D-084 / D-028 / D-136.

## Sandbox + References

`~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
Per-chunk 2-host; windowsmini Phase-boundary batch.

PRIMARY: [`phase9_close_plan.md`](phase9_close_plan.md).
ADRs: [`0065`](decisions/0065_wasm_1_0_instance_work_phase9_rescope.md)
/ [`0066`](decisions/0066_cross_module_import_bridge_thunks.md) §A2
/ [`0067`](decisions/0067_ubuntunote_native_x86_64_gate_host.md)
/ [`0068`](decisions/0068_dual_view_table_storage_fix.md)
/ **[`0069`](decisions/0069_multi_result_return_abi.md)** §Phase 2
/ **[`0017`](decisions/0017_jit_runtime_abi.md)** 2026-05-18 amend.
Auto-loaded rules: [`abi_callee_saved_pinning.md`](../.claude/rules/abi_callee_saved_pinning.md)
(full cohort discipline); [`bug_fix_survey.md`](../.claude/rules/bug_fix_survey.md)
(module-dump > manifest survey).
