# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_close_plan.md`](phase9_close_plan.md)
   §6. Cat III dispatch — chunks α/β/γ-partial/γ.2/γ.3 of
   D-126 fix all landed. γ.4 is **blocked on D-144** (print64
   i64 cross-module trap, needs interactive lldb).
2. **READ NEXT** [`.dev/decisions/0068_dual_view_table_storage_fix.md`](decisions/0068_dual_view_table_storage_fix.md);
   [`.claude/rules/dual_view_table_sync.md`](../.claude/rules/dual_view_table_sync.md);
   `.dev/debt.md` D-144 row (hypothesis enumeration).
3. `git log --oneline -10`. Latest: D-144 debt filed (7f9fcd9f).
4. `bash scripts/p9_simd_status.sh` — live SIMD status.
5. `cat .dev/debt.md | head -90`. D-126 + D-144 rows have plan.

## Active state — γ.4 = D-144 print64 cross-module i64 debug

ADR-0068 chunks landed:
- α (3053f91d ancestor): FuncEntity.funcptr + TableSlice 16→24
  + null sentinel for externref + setup wiring + 5 contract
  fixtures.
- β: arm64 mirror of refs+funcptrs+typeidx (Copy).
- γ-partial: x86_64 mirror + SIB-byte fix.
- γ.2: typeidx mirror in Set/Fill/Init/Grow on both arches.
- γ.3: resolveFuncrefGlobals fixup for ref.func globals.

2-host gate at HEAD=7f9fcd9f: Mac + ubuntunote `zig build
test-all` EXIT=0. Edge-case runner 51 PASS on both. The 5
contract fixtures under `test/edge_cases/p9/table_storage_sync/`
all PASS.

γ-4 relax probe (re-applied locally cycle 3, reverted): 1
residual `imports: call print64`; see D-144.

### Next-session active task — D-144 cycle 4

Cycle 3 (2026-05-18) added `tf=` diag to `printCallTrap`.
Mac observation `[stubs=5 last_tf=0 tf=1]` (relax applied
locally, reverted before commit) localizes trap to JIT code
**between stub #5 ($print_f64-2) return and `call_indirect`'s
BLR** — call_indirect's bounds/sig/funcptr-load sets trap_flag=1
(generic JIT trap; arm64 emit.zig:1444 shares one stub).
Sibling print32 uses same `(elem $print_i32 $print_f64)`
table at idx 0; passes. print64 differs only by idx (0→1)
+ expected sig (func(i32)→func(f64)). See D-144 hypothesis
list cycle 3 update (#5/#6).

Cycle 4 plan: either (a) lldb breakpoint at trap stub addr +
dump tables_jit_ci_ptr[0].{typeidx_base,funcptr_base}[0..2]
and call_indirect's loaded typeidx; OR (b) add per-fixup-kind
W17 marker pre-B.cond at op_call.zig call_indirect emit sites
+ new JitRuntime.last_trap_kind field (permanent infra).

### Discipline reminders

Pre-commit hook active; no `--no-verify`. 2-host per chunk;
windowsmini batch at Phase 9 close.

### Outstanding `now` debts

D-079; **D-126** (α/β/γ/γ.2/γ.3 landed; γ.4 blocked on D-144);
**D-144** (print64 i64 cross-module trap, root-cause pending);
D-133.

## Sandbox + References

`~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
Per-chunk 2-host; windowsmini Phase-boundary batch.

PRIMARY: [`phase9_close_plan.md`](phase9_close_plan.md).
ADRs: [`0065`](decisions/0065_wasm_1_0_instance_work_phase9_rescope.md)
/ [`0066`](decisions/0066_cross_module_import_bridge_thunks.md)
/ [`0067`](decisions/0067_ubuntunote_native_x86_64_gate_host.md)
/ **[`0068`](decisions/0068_dual_view_table_storage_fix.md)**.
Auto-loaded rules: [`dual_view_table_sync.md`](../.claude/rules/dual_view_table_sync.md);
[`hypothesis_enumeration.md`](../.claude/rules/hypothesis_enumeration.md)
(D-144 multi-cycle investigation).
