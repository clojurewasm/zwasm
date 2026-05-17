# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_close_plan.md`](phase9_close_plan.md)
   §6. Cat III dispatch — D-142 fix (B) `d543c646` + (A.1)
   ADR-0066 amendment `4e7a4646` + (A.2) arm64 thunk
   `6044e8f4` + (A.3) x86_64 thunk `b89c2d45` — all landed.
   D-142 fix (A) COMPLETE. γ-4 (relax `hasUnbindableImports`)
   is next.
2. `git log --oneline -10`. Latest: D-142 (A.3) x86_64 thunk
   redesign. Prior β/γ chain via `git log --grep="9.9-III"`.
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

### Next-session active task — γ-4 `hasUnbindableImports` relax

D-142 fix (A) COMPLETE. All 4 sub-chunks landed:

- **(B) `d543c646`** — `SAFE_STUB_PTR_ADDR = 0x1000` for 8
  absent-backing fields in `ensureCompiledAndRt`.
- **(A.1) `4e7a4646`** — ADR-0066 Amendment §A1 design contract.
- **(A.2) `6044e8f4`** — arm64 thunk 56-byte call-and-return
  shape preserving caller X19. New encoders: `encBlr`,
  `encStpPreIdx`, `encLdpPostIdx`.
- **(A.3) `b89c2d45`** — x86_64 thunk 27-byte call-and-return
  shape preserving caller R15. No new encoders (all existed).

**NEXT — γ-4**: in `test/spec/spec_assert_runner_base.zig`,
relax `hasUnbindableImports` to allow registered func imports
through the resolver-emitted bridge thunks. Pre-D-142-fix this
hit a Mac aarch64 SEGV at the cross-module dispatch boundary
(see lesson `2026-05-17-gamma3d-dispatch-write-segv-bisect.md`).
After γ-4 lands, the corpus runs `imports/imports.1.wasm` etc.
through the thunks; ubuntunote was already functional at
25196/112/705 under the relaxation (the 112 functional FAILs
are table_copy 65 / table_init 39 / ref_func 6, addressed by
the γ-1/γ-2/γ-3 per-exporter backing that landed earlier).

Expected outcome on Mac: SEGV closes structurally (or surfaces
a NEW class of bug, in which case D-142 cycle 7 opens). Both
hosts should converge to the same residual fail count
(~25196/112 ballpark) — if a host diverges, a new debt row
is filed.

After γ-4: (c)-2.4 corpus distiller `supported` extension +
new fixture rebuild (discharges D-138 fully + D-079 sub-gap
ii). Then Step (d) Cat IV windowsmini reconcile (D-136 SEH
bridge). Then Step (e) Phase 9 close (audit_scaffolding +
SHA backfill + open 9.12 hard gate).

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
D-079(v128 cross-module → (c)-2.4); D-126(bulk.wast post-
mutation per ADR-0065); D-133(arm64 op_table scratch sweep);
D-142(fix (A) COMPLETE — (B) + (A.1) + (A.2) + (A.3) all landed; final discharge after γ-4 behaviorally verifies).

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
