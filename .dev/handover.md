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

γ-4 relax probe (uncommitted, in stash): yields 25307 passed,
1 failed (was 25305/3 before γ.3). The 2 ref_func fails
discharged by γ.3; the 1 residual `imports: call print64`
needs root-cause investigation — see D-144.

### Next-session active task — D-144 print64 trap root-cause

The fail: `assert_return print64 i64:24 -> ()` in
`imports/imports.1.wasm`. Sibling `print32 i32:13` passes.
Differs by `(call $i64->i64 (local.get $i))` — a cross-module
call into imports.0's `func-i64->i64 (param i64) (result i64)
(local.get 0)`.

Approaches tried in γ.4 cycle 1 (this session):
- Code review of arm64 + x86_64 bridge thunks (no defect
  found — see thunk.zig docstrings).
- Code review of importer `call N (import)` emit path on both
  arches (correct).
- Code review of captureCallResult for i64 (correct).
- Static spike `private/spikes/xmod_i64/{a,b}.wat` (compiled
  but couldn't wire to spec_assert harness without distiller
  rebuild; deleted).

The trap_flag MUST be set by something during print64's
execution. Open questions:
- Is it the cross-module call to `$i64->i64`? Direct test
  needs a harness wrapper that does `register A; import
  A.fn from B; invoke B.fn(i64:24)` outside the spec corpus.
- Is it one of the 5 spectest `call N` no-ops? hostImportTrapStub
  doesn't set trap_flag per code — verify by stderr trace from
  inside the stub.
- Is it the trailing `call_indirect (type $func_f64)`? Same
  hostImportTrapStub path via funcptr_base[1] post-patch.

Next-session plan:
- Add temporary stderr fprintf to `hostImportTrapStub` (test/
  spec/spec_assert_runner_base.zig:351) printing "stub fired:
  rt=%p trap_flag=%d". Run with γ-4 relax. Count stub calls
  per print64 invocation. If trap_flag becomes 1, identify
  which call.
- Failing that, lldb breakpoint on rt.trap_flag write inside
  zwasm-spec-wasm-2-0-assert binary.

After fix: flip `hasUnbindableImports` to allow registered
exporters; verify Mac+ubuntunote at 0 fail; close D-126 and
D-144.

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
