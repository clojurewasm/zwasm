# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_close_plan.md`](phase9_close_plan.md)
   §6. Cat III dispatch — chunks α (ABI shape) + β (arm64 mirror) +
   γ-partial (x86_64 mirror) landed. **γ-4 relax + typeidx mirror
   follow-up** is next (see "Active state" below).
2. **READ NEXT** [`.dev/decisions/0068_dual_view_table_storage_fix.md`](decisions/0068_dual_view_table_storage_fix.md).
   Auto-loaded:
   [`.claude/rules/dual_view_table_sync.md`](../.claude/rules/dual_view_table_sync.md).
3. `git log --oneline -10`. Latest: SIB-byte fix (6513b23f) +
   x86_64 mirror (2c3c85fa). Prior chain via
   `git log --grep="9.9-III"`.
4. `bash scripts/p9_simd_status.sh` — live SIMD via ubuntunote.
5. `cat .dev/debt.md | head -90`. D-126 row body has plan summary.

## Active state — Phase 9 close-plan Step (c) D-126 chunk γ.2

Chunks α + β + γ-partial complete:
- α: ABI shape (FuncEntity.funcptr, TableSlice extension, setup
  wiring with null sentinel for externref).
- β: arm64 emit mirror for Set/Fill/Init/Copy (+typeidx for
  copy); growableTableGrowFn host-side mirror.
- γ-partial: x86_64 emit mirror for Set/Fill/Init/Copy (+typeidx
  for cross-table copy). SIB-byte fix in encMovR64FromMemDisp32
  for RSP/R12 base (regalloc pool members trigger SIB requirement).

2-host gate at HEAD=6513b23f: Mac + ubuntunote both `zig build
test-all` EXIT=0; `test-edge-cases` 51 PASS on both (5 new
contract fixtures green on both arches).

### Next-session active task — D-126 chunk γ.2 (typeidx mirror + γ-4)

**γ-4 relax probe** (this session, stashed not committed) flipped
`hasUnbindableImports` to allow registered-exporter func imports.
Result on Mac: 24034 → 25275 passed (+1241), **33 new fails**
(table_init / ref_func / imports families).

Root cause of the 33 fails: emitTableSet / emitTableFill /
emitTableInit / emitTableGrow mirror refs + funcptrs but NOT
typeidx_base. After table.init populates slots with funcref
entries, `call_indirect` sig-check on those slots reads stale
sentinel typeidxs → trap. `emitTableCopy`'s different-tables
path already mirrors typeidx (chunk β/γ); the other 4 ops don't.

Plan for chunk γ.2:
- Add `typeidx: u32` field to `FuncEntity` (at offset 12, between
  `func_idx` and `funcptr` for natural alignment; struct stays
  24 bytes total).
- Populate `typeidx` at every FuncEntity construction site:
  production runner.zig, spec_assert_runner_base, interp
  instantiate. Locals use `canonical_typeidx(compiled.func_typeidxs[i])`;
  imports use the resolved cross-module typeidx (via dispatch).
- emit typeidx mirror in arm64 + x86_64 Set/Fill/Init via
  `LDR W/MOV r32, [FuncEntity_ptr + 12]; STR/MOV [typeidx_base + idx*4]`.
  emitTableGrow's growableTableGrowFn host-side path: derive
  typeidx from init's FuncEntity ptr too.
- typeidx_base for k=0 lives at scalar `JitRuntime.typeidx_base`;
  k>0 at `TableJitCallInfo.typeidx_base`. Mirror code loads via
  the same dual-path as call_indirect.
- Land γ-4 permanent relax in `hasUnbindableImports` (`registered.contains(imp.module)`).
- 2-host gate: expect 0 fails on Mac + ubuntunote.

### Discipline reminders

Pre-commit hook active (`gate_commit.sh`); no `--no-verify`.
2-host per-chunk (Mac + ubuntunote); windowsmini batch at Phase
9 close.

### Outstanding `now` debts

D-079(v128 cross-module → (c)-2.4 sub-gap ii); **D-126
(IN PROGRESS — α/β/γ-partial landed, γ.2 next)**; D-133(arm64
op_table scratch sweep). D-016 + D-052 + D-138 + D-142 + D-143 CLOSED.

`blocked-by` rides: D-103/D-105 → (c)-2.3/2.4; D-079(ii) →
(c)-2.4; D-136 → step (d) Win64 SEH; D-135 entry.zig
comptime; D-094/D-137/D-140 multi-result ABI bridge family.

## Sandbox + References

`~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
Per-chunk 2-host (Mac + ubuntunote); windowsmini Phase-
boundary batch.

PRIMARY: [`phase9_close_plan.md`](phase9_close_plan.md).
ADRs: [`0065`](decisions/0065_wasm_1_0_instance_work_phase9_rescope.md)
/ [`0066`](decisions/0066_cross_module_import_bridge_thunks.md)
/ [`0067`](decisions/0067_ubuntunote_native_x86_64_gate_host.md)
/ **[`0068`](decisions/0068_dual_view_table_storage_fix.md)**.
Auto-loaded rules: [`dual_view_table_sync.md`](../.claude/rules/dual_view_table_sync.md).
