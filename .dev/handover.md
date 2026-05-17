# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_close_plan.md`](phase9_close_plan.md)
   §6. Cat III dispatch — D-142 fix (A) chain complete; γ-4
   probe behaviorally verified the thunks; D-126 dual-view
   storage gap is the remaining cross-module blocker.
   **ADR-0068 Accepted 2026-05-18** with audit-prep
   amendments §A1–A7; chunk α/β/γ ready to execute.
2. **READ NEXT** [`.dev/decisions/0068_dual_view_table_storage_fix.md`](decisions/0068_dual_view_table_storage_fix.md)
   in full, especially the "Audit-prep configurations §A1–A7"
   section — chunk α/β/γ scope + helper-mediated discipline.
   Also auto-loaded: [`.claude/rules/dual_view_table_sync.md`](../.claude/rules/dual_view_table_sync.md).
3. `git log --oneline -10`. Latest: ADR-0068 amendments +
   new rule. Prior chain via `git log --grep="9.9-III"`.
4. `bash scripts/p9_simd_status.sh` — live SIMD via ubuntunote
   native x86_64 (ADR-0067).
5. `cat .dev/debt.md | head -90`. D-126 row body has the
   3-chunk plan summary.

## Active state — Phase 9 close-plan Step (c) D-126 fix

D-142 fix (A) chain (B/A.1/A.2/A.3) all landed; D-138 closed;
D-143 absorbed into D-126. γ-4 probe verified the bridge
thunk path. The remaining 113 functional FAILs are D-126's
dual-view table-0 storage gap, fixed via ADR-0068's
helper-mediated triple-write.

### Next-session active task — D-126 chunk α (precondition + ABI shape)

Per ADR-0068 §A4 chunk α scope:

- **Add `FuncEntity.funcptr: usize`** field to
  `src/runtime/instance/func.zig`. Update construction
  sites (3 in tests, 2 in `spec_assert_runner_base.zig`,
  1 production in `src/engine/runner.zig:1599`). For
  test/scratch sites use `undefined` initially; production
  populates from `compiled.module.block.bytes.ptr +
  func_offsets[i]` (locals) or `dispatch[i]` (imports).
- **Extend `TableSlice` extern struct** in
  `src/engine/codegen/shared/jit_abi.zig` from 16 → 24
  bytes (add `funcptrs: [*]u64`; typeidxs already separate).
  Stride references at `op_table.zig` / `op_call.zig` need
  re-derivation (grep `* 16` + `<<4` referring to
  `tables_ptr` indexing — likely 4-6 sites per arch).
- **Create `src/engine/codegen/shared/table_storage.zig`**
  with `mirrorWrite` API skeleton (empty body initially —
  call sites land in β/γ). Doc-comment cites ADR-0068 §A1.
- **Wire setup** in `makeJitRuntime` /
  `setupMultiTableScratch` / `ensureCompiledAndRt` so
  `scratch_tables_descriptor[k].funcptrs` points at
  `scratch_funcptrs` (k=0) / `scratch_extra_funcptrs[k-1]`
  (k>0).
- **Add `// TODO(9.12-audit): table storage shape — see
  D-126 / ADR-0068`** markers at every new site (helper,
  TableSlice extension, FuncEntity.funcptr field).
- **Land contract fixtures** under
  `test/edge_cases/p9/table_storage_sync/` per §A3 — 5–10
  WAT files exercising table.copy/init/set/grow + round-trip
  via call_indirect. These fail at chunk α gate because
  helper body is empty; chunk β/γ greens them.

Chunk α LOC budget ≈ 200 (ABI + wiring + fixtures). Gate:
Mac + ubuntunote `zig build test-all`; cross-module fixtures
expected to FAIL (chunk β/γ flips them).

### Subsequent chunks

- **Chunk β**: arm64 4-op triple-write via helper. Wire
  `mirrorWrite` calls into `emitTableCopy` / `TableInit` /
  `TableSet` / `TableGrow` (`emitTableFill` if same
  arch-source-file). Fixtures green on Mac; ubuntunote
  stays red.
- **Chunk γ**: x86_64 mirror + `hasUnbindableImports`
  permanent relax (γ-4 land). Both hosts green at 0 FAIL.
  Capture optional bench delta (§A5) into commit body.

### Discipline reminders

Pre-commit hook active (`gate_commit.sh`); no `--no-verify`
per §14. 2-host gate per chunk: Mac foreground +
`bash scripts/run_remote_ubuntu.sh test-all > /tmp/ubuntu.log 2>&1`
background. windowsmini batch at Phase 9 close.

### Outstanding `now` debts

D-079(v128 cross-module → (c)-2.4 sub-gap ii); **D-126
(IN PROGRESS via ADR-0068 chunk α/β/γ)**; D-133(arm64
op_table scratch sweep — 3-reg pressure, architectural).
D-016 + D-052 + D-138 + D-142 + D-143 CLOSED.

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
Lessons:
[`2026-05-17-gamma3d-dispatch-write-segv-bisect.md`](lessons/2026-05-17-gamma3d-dispatch-write-segv-bisect.md)
· [`2026-05-18-debt-dedup-grep-before-file.md`](lessons/2026-05-18-debt-dedup-grep-before-file.md).
