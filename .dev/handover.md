# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_close_plan.md`](phase9_close_plan.md)
   §6. Cat III dispatch — D-142 fix (A) chain complete; γ-4
   probe surfaced 113 FAILs which bisect identified as
   pre-existing **D-126** dual-view table-0 storage bug.
   D-143 closed as duplicate. D-126 next.
2. `git log --oneline -10`. Latest: D-126 absorb D-143
   evidence. Prior chain via `git log --grep="9.9-III"`.
3. `bash scripts/p9_simd_status.sh` — live SIMD via ubuntunote
   native x86_64 (ADR-0067).
4. `cat .dev/debt.md | head -90`. Cat III sub-chunks tracked
   in close-plan §6 step (c), not granular ROADMAP rows.

## Active state — Phase 9 close-plan Step (c)-2.3

D-134 closed structurally. Cat III JIT dispatch infra:
registry (c)-1a/b/c; ADR-0066 design (c)-2.0; arm64 32-byte
/ x86_64 22-byte opcode-pinned thunk encoders (c)-2.1;
`shared/thunk.zig` arena lifecycle (c)-2.2; resolver
substrate + wire-up (c)-2.3-α/β-1/β-2a/β-2b. γ-1/γ-2/γ-3/
γ-3.b-i/γ-3.b-ii/γ-5 all landed
(`9518eb4d`/`413d9b57`/`33d1da17`/`3b003b9e`/`84f62398`/
`e902e531`). Counts unchanged with γ-relaxation deferred:
24034/0/2015 + 13301/0/440 + 212/0/20.

### Next-session active task — D-126 fix needs ADR FIRST (§18.2 deviation); (c)-2.4 / D-079(ii) viable parallel work

**γ-4 probe + D-143 bisect (2026-05-18 cycles 1+2)** confirmed
the 113 functional FAILs surfaced by relaxing
`hasUnbindableImports` are the SAME bug class as pre-existing
**D-126** (`bulk.wast` call_indirect post-mutation returning
stale entries). γ-4 just exposed it across 4 more fixture
families (table_copy 66 / ref_func 6 / table_init 5 /
imports 1) on top of the original bulk.X.wasm cases. D-143
closed as duplicate; D-126 updated with the cycle-2 evidence
+ 3 architectural options.

**Root cause (verified)**: table-0 in `JitRuntime` has TWO
independent storage buffers:
- `funcptr_base` (= `scratch_funcptrs.ptr`, read by
  `call_indirect t0` per the §9.9-l-1b-d093 X26 fast path).
- `tables_ptr[0].refs` (= `scratch_table_refs[0]`, written
  by `table.copy`/`table.init`/`table.set` per
  `op_table.zig::emitTableCopy`).

The two are populated identically at `on_module_loaded` but
NEVER synced after mutating ops. `call_indirect` sees the
PRE-mutation state. Verified minimal repro:
`table_copy/table_copy.2.wasm`.

**Architectural options** (per D-126 row):
- (A) unify storage — one array per slot holding (funcptr,
  FuncEntity-ptr) pair; table.copy moves both halves at once.
- (B) sync at op time — extend the 4 table-mutating JIT op
  handlers to write both views. Most incremental.
- (C) route call_indirect through `tables_ptr` — drops the
  X26 fast path; loses §9.9-l-1b-d093 caching.

**NEXT chunk caveat (ADR FIRST)**: Option B implementation
(extend the 4 mutating table ops to mirror writes into a
parallel funcptr view) is a §4 architecture deviation per
`.dev/ROADMAP.md` §18.2 — affects `JitRuntime` field
layout AND `TableSlice` extern struct stride AND every
`tables_ptr`-indexing emit site. Loop policy:
**`.dev/decisions/NNNN_dual_view_table_storage_fix.md`
FIRST** documenting (A) unified storage / (B) sync-at-op /
(C) call-indirect-through-tables_ptr trade-offs + the
chosen path; then implementation as multi-chunk follow-up.

**Viable parallel chunks (no D-126 dependency)**:
- **(c)-2.4 corpus distiller** — extend
  `scripts/regen_spec_2_0_assert.sh`'s `supported` set +
  rebuild .wasm fixtures. Discharges D-079 sub-gap ii
  (v128 cross-module imports — also needs
  `Runtime.globals` v128 plumbing per ADR-0052 §3).
  D-138 ALREADY closed `4894ad1e` independent of (c)-2.4.
- **D-016 `applySanitize` wrapper extract** — mechanical
  refactor, no architectural depth.
- **D-052 x86_64 prologue.zig extract** — paired refactor.
- **D-133 arm64 op_table scratch sweep** — mechanical
  scratch-reg audit.

After Cat III closes (D-126 fix + (c)-2.4): Step (d) Cat IV
windowsmini reconcile (D-136 SEH bridge). Then Step (e)
Phase 9 close (audit_scaffolding + SHA backfill + open 9.12
hard gate — substrate audit collaborative review).

(c)-2.4 = corpus distiller's `supported` set extension +
new fixture rebuild; discharges D-138 fully + D-079 sub-gap
ii.

### Discipline reminders

Pre-commit hook active (`gate_commit.sh`); no `--no-verify`
per §14. 2-host gate per chunk: Mac foreground +
`bash scripts/run_remote_ubuntu.sh test-all > /tmp/ubuntu.log 2>&1`
background. D-134 closed; future heisenbugs use 5-streak +
3-SHA rule.

### Outstanding `now` debts (6)

D-016(applySanitize wrapper); D-052(x86_64 prologue extract);
D-079(v128 cross-module → (c)-2.4); D-126(dual-view table-0
sync gap — γ-4 evidence absorbed 2026-05-18, ADR needed);
D-133(arm64 op_table scratch sweep). D-138 + D-142 + D-143
CLOSED 2026-05-18.

`blocked-by` rides (corresponding chunks):
D-103/D-105 → (c)-2.3/2.4; D-138 → (c)-2.4;
D-136 → step (d) Win64 SEH; D-135 entry.zig comptime;
D-094/D-137/D-140 multi-result ABI bridge family.

## Sandbox + References

`~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
Per-chunk 2-host (Mac + ubuntunote); windowsmini Phase-
boundary batch.

PRIMARY: [`phase9_close_plan.md`](phase9_close_plan.md).
ADRs: [`0065`](decisions/0065_wasm_1_0_instance_work_phase9_rescope.md)
/ [`0066`](decisions/0066_cross_module_import_bridge_thunks.md)
/ [`0067`](decisions/0067_ubuntunote_native_x86_64_gate_host.md).
[`ubuntunote_setup.md`](ubuntunote_setup.md) ·
[`lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md`](lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md)
· [`lessons/2026-05-17-gamma3d-dispatch-write-segv-bisect.md`](lessons/2026-05-17-gamma3d-dispatch-write-segv-bisect.md).
