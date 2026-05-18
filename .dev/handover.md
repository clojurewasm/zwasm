# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_close_plan.md`](phase9_close_plan.md)
   §6 (revised 2026-05-18). ADR-0069 chunked plan + D-135
   prerequisite + §9.13-0 windowsmini relocation in §6 (d)/(f).
2. **READ NEXT** ADR-0069 implementation chain + ADR-0049 /
   ADR-0056 / ADR-0065 2026-05-18 amends.
3. `git log --oneline -10`. Latest: §9.13-0 wiring + ADR amends.
4. `bash scripts/p9_simd_status.sh` — live status.
5. `cat .dev/debt.md`. `now`: D-079, D-133. Cohort blocked
   by D-135: D-094 / D-137 / D-140 / D-146. Cohort relocated
   to §9.13-0: D-084 / D-028 / D-136.

## Active state — §9.9-III [x]; §9.9-IV moved to §9.13-0

D-126 + D-144 closed cycle 4; §9.9-III [x] cycle 5. D-145
closed cycle 10. Both hosts bit-identical **25316/0/697**.

2026-05-18 wiring: §9.9-IV → §9.13-0 (post-§9.12 audit) per
ADR-0049+0056+0065 amends. `skip-impl == 0 literally` preserved.
ADR-0066 §A2 (thunk 56→96 B), ADR-0069 chunked plan refined.

### Next-session active task — D-135 (entry.zig comptime-gen) is now the chain prerequisite

2026-05-18 wiring landed (this commit): §9.9-IV moved to
§9.13-0 per ADR-0049 + ADR-0056 + ADR-0065 amends. ADR-0069
chunked plan refined. Dependency chain to §9.9 [x]:

```
D-135 (entry.zig comptime-gen)     ← PHASE 0 — required next
  ↓
D-146 (cycle-11 (f64,f32) re-land + x86_64 inline-asm thunk)
  ↓
ADR-0017 + ADR-0026 amend (X8 / RDI hidden-result-ptr prologue)
  ↓
Class C (D-094 + D-140) — 5 chunks per arch
  ↓
§9.9 [x]  →  §9.12 substrate audit (USER GATE)  →
§9.13-0 windowsmini reconcile (LOOP)  →
§9.13 Phase 10 entry gate (USER GATE)
```

**Next concrete task**: D-135 entry.zig comptime-gen.
Without this, D-146 + Class C both hit ADR-0063 cap.
Side candidates if D-135 stuck: D-079 (latent), D-133 (latent).

### Discipline reminders

No `--no-verify`. 2-host per chunk (Mac + ubuntunote);
windowsmini at §9.13-0 (post-§9.12).

### Outstanding `now` debts

D-079; D-133.
Blocked by D-135: D-094 / D-137 / D-140 / D-146.
Relocated to §9.13-0: D-084 / D-028 / D-136.

## Sandbox + References

`~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
Per-chunk 2-host; windowsmini Phase-boundary batch.

PRIMARY: [`phase9_close_plan.md`](phase9_close_plan.md).
ADRs: [`0065`](decisions/0065_wasm_1_0_instance_work_phase9_rescope.md)
/ **[`0066`](decisions/0066_cross_module_import_bridge_thunks.md)** §A2
/ [`0067`](decisions/0067_ubuntunote_native_x86_64_gate_host.md)
/ [`0068`](decisions/0068_dual_view_table_storage_fix.md).
Auto-loaded rules: [`abi_callee_saved_pinning.md`](../.claude/rules/abi_callee_saved_pinning.md)
(full cohort discipline); [`dual_view_table_sync.md`](../.claude/rules/dual_view_table_sync.md);
[`hypothesis_enumeration.md`](../.claude/rules/hypothesis_enumeration.md).
