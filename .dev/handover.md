# Session handover

> ≤ 100 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure (FOLLOW THIS ORDER)

1. **READ FIRST**:
   [`.dev/phase9_close_plan.md`](phase9_close_plan.md) §6 work
   sequence. The current active task is **Phase 9 close-plan
   step (a) — amendment cycle** (ROADMAP / ADR-0056 amend /
   new ADR-0065 / debt re-eval / substrate audit notes /
   handover refresh).
2. `git log --oneline -15` — last 11 commits (`d3f2a1a7` …
   `7976dc00`) are 2026-05-17 close-readiness work; familiarise.
3. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
4. `cat .dev/debt.md | head -90` — `now` + `blocked-by:`. Note
   newly filed D-135 (entry.zig comptime gen) + D-136 (Win64
   SEH bridge) + D-052 flipped to `now`.
5. ROADMAP §9 Phase Status widget — `[ ]` on 9.9; the **plan
   doc supersedes** the §9.9 sub-task list until step (a) lands
   the ROADMAP correction.

## Active state — **Phase 9 close-plan execution (post-2026-05-17 cycle)**

### One-line state

§9.9 exit-criterion `skip-impl == 0` re-interpreted per
[`phase9_close_plan.md`](phase9_close_plan.md): literal 0
across 4 categories (Cat I validator/parser, Cat II
multi-result harness, Cat III runtime instance, Cat IV
windowsmini batch-end sweep). **User-confirmed correction
2026-05-17**: Cat III (cross-module / host imports / start-
trap / link-typecheck) was a ROADMAP misclassification —
Wasm 1.0 core work that was wrongly pushed to Phase 10+;
must be pulled back into Phase 9.

**Current spec_assert tally** (Mac aarch64 + OrbStack
bit-identical, unchanged since d-85 close on 2026-05-16):

- spec_assert non-simd: **24001 / 0 / 2069**
- simd_assert: **13301 / 0 / 440** (also bit-identical with
  windowsmini per today's D-084 reconcile attempt)

### Next-session active task

**Step (a) — Amendment cycle** per
[`phase9_close_plan.md`](phase9_close_plan.md) §6 step (a):

| Sub-step | Description | Output |
|---|---|---|
| (a)-1 | Draft `ADR-0065_wasm_1_0_instance_work_phase9_rescope.md` | New ADR file `Accepted` |
| (a)-2 | Amend ADR-0056 (Revision history 2026-05-17 row): 4-category exit predicate | ADR-0056 amended |
| (a)-3 | ROADMAP §1/§2 P/A + §9.9 row text + sub-task table update; cite ADR-0065 | Commit per §18.2 with ADR cite |
| (a)-4 | Debt ledger re-eval (D-079, D-082 sub-rows, D-126, D-026, D-074 barriers) | `.dev/debt.md` updates |
| (a)-5 | Substrate audit doc: Q5 hygiene extension; note Cat III work proceeds in parallel | `.dev/phase9_completion_substrate_audit.md` |
| (a)-6 | Refresh handover.md to point at Step (b) | handover update |

**After step (a)**:

- Step (b) — Cat II multi-result entry helpers (~6-8 chunks)
- Step (c) — Cat III Wasm 1.0 instance / store / linker /
  cross-module dispatch / host-import binding (subchunk count
  TBD via survey)
- Step (d) — Cat IV windowsmini batch sweep at Phase 9 end
- Step (e) — §9.9 [x] flip + Phase 9 close → substrate audit
  hard-gate (9.12) collaborative review

### Discipline reminders

- Pre-commit hook now active (`.githooks/pre-commit`
  reactivated 2026-05-17 commit `66c699e7`). All commits run
  `gate_commit.sh`. **No `--no-verify`** per ROADMAP §14.
- `core.hooksPath` auto-set by `flake.nix` shellHook on
  `nix develop`. Fresh clones get the activation automatically.
- `.claude/rules/heisenbug_discharge.md` — D-134 streak (1
  silent recorded today; track via
  `bash scripts/track_heisenbug.sh d134 silent|segv` per
  OrbStack run).
- `.claude/skills/audit_scaffolding/CHECKS.md` §F.3a / §G.3 /
  §G.4 — new lints; invoke at phase boundary.
- New TODO(D-136) markers in `test/spec/spec_assert_runner_base.zig`
  flag Windows-compat stubs as workarounds (not real recovery).

### Outstanding `now` debts (post-2026-05-17)

- **D-052** (now): x86_64 prologue.zig extract; barrier
  dissolved. D-081 follows.
- **D-126** (now): bulk.wast call_indirect post-table-mutation;
  re-evaluate barrier in step (a)-4 (likely Phase 9 scope now).
- **D-133** (now): arm64 op_table / op_memory hardcoded scratch;
  substrate audit Q5 anchor.
- **D-134** (now): OrbStack heisenbug; streak counter armed at
  `private/heisenbug-d134.log`.
- **D-135** (blocked-by: entry.zig at 2500 OR new ABI variant):
  ADR-0063 Alt B comptime entry helper generation.
- **D-136** (blocked-by: Win64 SEH bridge): assert_trap recovery
  on Windows. Cat IV scope; discharged at step (d).

## Sandbox quirks + hook scope

- `~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
- OrbStack daemon log-rotation panic — restart via
  `pkill -9 -f OrbStack && open -a OrbStack`.
- Per-chunk 2-host (Mac+OrbStack) per ADR-0049; windowsmini
  reconcile is **step (d) batch**, not per-chunk.
- Pre-commit hook: `.githooks/pre-commit → scripts/gate_commit.sh`
  active. Failures must be fixed at root, not bypassed.

## Reference chain

- **PRIMARY**: [`.dev/phase9_close_plan.md`](phase9_close_plan.md)
  — the authoritative plan; this handover is the pointer
- [`.dev/decisions/0056_phase9_scope_extension_to_wasm2_full.md`](decisions/0056_phase9_scope_extension_to_wasm2_full.md)
  — amend at step (a)-2
- [`.dev/decisions/0062_phase9_substrate_audit_gate.md`](decisions/0062_phase9_substrate_audit_gate.md)
  — substrate audit gate at 9.12 (post-Phase-9 close)
- [`.dev/decisions/0063_uniform_pattern_catalog_file_size_exemption.md`](decisions/0063_uniform_pattern_catalog_file_size_exemption.md)
  + [`.dev/decisions/0064_runner_validate_split.md`](decisions/0064_runner_validate_split.md)
  — 2026-05-17 hook reactivation foundation
- [`.dev/phase9_completion_substrate_audit.md`](phase9_completion_substrate_audit.md)
  — 9.12 hard gate doc (collaborative; post Phase 9 close)
- [`.dev/phase_log/phase9.md`](phase_log/phase9.md) — per-chunk
  historical record (d-1..d-85 complete)
- [`.dev/lessons/2026-05-16-narrative-claim-vs-landed-state.md`](lessons/2026-05-16-narrative-claim-vs-landed-state.md)
  — discipline anchor for "claim ≠ landed state"
