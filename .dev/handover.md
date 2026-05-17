# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_close_plan.md`](phase9_close_plan.md)
   §6. Cat III dispatch — γ-5 landed (`552a2b6d` /
   `e902e531`). γ-3.d bisect (`e5c91aef` + this session)
   established: imports.1 SEGV is **Mac-aarch64 specific**
   (D-142 filed); ubuntunote runs cleanly to 25196/112/705
   with 112 functional FAILs (table_copy 65 / table_init 39
   / ref_func 6) addressed by γ-1/γ-2/γ-3 per-exporter
   backing. **Next = γ-1** (per-exporter globals — behavior-
   neutral; doesn't depend on D-142 since no fixture
   exercises it until γ-4 lands).
2. `git log --oneline -10`. Latest: γ-3.d findings refresh.
   γ-5 `552a2b6d`. Prior β/γ chain via
   `git log --grep="9.9-III"`.
3. `bash scripts/p9_simd_status.sh` — live SIMD via ubuntunote
   native x86_64 (ADR-0067).
4. `cat .dev/debt.md | head -90`. Cat III sub-chunks tracked
   in close-plan §6 step (c), not granular ROADMAP rows.

## Active state — Phase 9 close-plan Step (c)-2.3

D-134 closed structurally (Rosetta race; ubuntunote native
host eliminates). Cat III JIT dispatch infra: registry
(c)-1a/b/c; ADR-0066 design (c)-2.0; arm64 32-byte /
x86_64 22-byte opcode-pinned thunk encoders (c)-2.1;
`shared/thunk.zig` arena lifecycle (c)-2.2; resolver substrate
+ wire-up (c)-2.3-α/β-1/β-2a/β-2b. Counts unchanged with
γ-relaxation deferred: 24034/0/2015 + 13301/0/440 + 212/0/20
Mac+ubuntunote bit-identical (β-2b kept hasUnbindableImports
strict — exercising the dispatch+arena infra via spectest-
import modules, but pre-existing cross-module fixtures still
SKIP-CROSS-MODULE-IMPORTS until γ lands per-exporter backing).

### Next-session active task — (c)-2.3-γ-3.b remaining state

Read `private/notes/p9-9.9-III-c-2.3-gamma-survey.md` FIRST
(corpus taxonomy + 5-step ramp; γ-3.b note appended below).

Sub-chunking progress (Cat III (c)-2.3):
- SHAs through γ-5: `git log --grep="9.9-III"`.
- γ-1/γ-2/γ-3/γ-3.b-i/γ-3.b-ii/γ-5 **all landed**
  (`9518eb4d` / `413d9b57` / `33d1da17` / `3b003b9e` /
  `84f62398` / `e902e531`). `RegisteredExporter` carries
  scratch_globals / scratch_memory / scratch_funcptrs /
  scratch_typeidxs / scratch_func_entities /
  scratch_elem_segments / scratch_data_segments, all wired
  into per-exporter rt. **Prior handover's "γ-1 NEXT" was
  stale**.
- γ-3.d bisect (`e5c91aef` + `2d37c925`) established that
  γ-4 (the `hasUnbindableImports` relaxation) is the only
  remaining gating step — and it's **blocked by D-142**
  (Mac aarch64 SEGV at the cross-module dispatch-slot write
  boundary). ubuntunote runs cleanly to 25196/112/705 under
  the relaxation; the 112 FAILs are functional (table_copy
  65 / table_init 39 / ref_func 6) — γ-1/2/3 backing is
  populated but does not yet route correctly in some
  cross-module shapes. This is the residual γ work.
- **D-142 ROOT CAUSE IDENTIFIED (cycle 6)**: bridge
  thunk corrupts X19 across cross-module call. Two
  interacting bugs: (A) v2 arm64 prologue overwrites X19
  (`runtime_ptr_save_gpr`) without saving caller's value
  (AAPCS64 §6.4.1 violation); (B) `ensureCompiledAndRt`
  inits callee_rt with `host_dispatch_base = undefined`
  (`0xAA` poison in Debug). After cross-module call
  returns, importer's X19 = callee_rt; next host-import
  call loads imports.0's poison `host_dispatch_base =
  0xAA`; LDR at +8 faults at `0xAA + 8 = 0xB2`. Both
  fixes needed: (A) bridge thunk → BL/RET pattern saving
  caller's X19 (ADR-0066 amendment, ~48-byte thunk);
  (B) replace `undefined` field inits with safe stubs.
  See lesson for full diagnostic chain.
- **NEXT options** (loop should pick one):
  (1) Deep D-142 investigation (SA_SIGINFO + ucontext_t to
      capture fault PC + address; hypotheses 1 and 2 are
      already rejected, 3/4/5 remain).
  (2) D-055 sentinel wire-up (now partially unblocked by
      D-052 helper landing; test-site migration to
      `body_start_offset()`-relative pattern still needed).
  (3) D-126 bulk.wast table.copy post-mutation (Cat III
      scope per ADR-0065; needs unification ADR).
- (c)-2.4 (distiller) follows once γ-4 lands (gated on D-142).

(c)-2.4 = corpus distiller's `supported` set extension + new
fixture rebuild; discharges D-138 fully + D-079 sub-gap ii.

### Discipline reminders

Pre-commit hook active (`gate_commit.sh`); no `--no-verify`
per §14. 2-host gate per chunk: Mac foreground +
`bash scripts/run_remote_ubuntu.sh test-all > /tmp/ubuntu.log 2>&1`
background. D-134 closed; future heisenbugs use 5-streak +
3-SHA rule.

### Outstanding `now` debts (6)

D-016(applySanitize wrapper); D-052(x86_64 prologue extract);
D-079(v128 cross-module → (c)-2.4); D-126(bulk.wast post-
mutation per ADR-0065); D-133(arm64 op_table scratch sweep);
D-142(Mac aarch64 SEGV at cross-module dispatch boundary).

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
[`lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md`](lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md).
