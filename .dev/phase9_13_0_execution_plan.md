# §9.13-0 Cat IV — execution plan

> Close-plan-style doc. `.dev/handover.md` Cold-start procedure
> step 1 points here, so the `/continue` skill's Step 1a override
> activates and §6 Work sequence below is the **authoritative
> work source** for the next session.

## §0 Preflight — environment health check (run FIRST)

windowsmini was last gated at §9.6 / 6.F (per ADR-0049 the
per-chunk gate is deferred, so the clone may have drifted).
Run before W0:

```sh
ssh windowsmini "uname -a 2>/dev/null; powershell -Command 'Get-Host | Select-Object Version'; \
    cd ~/Documents/MyProducts/zwasm_from_scratch && git rev-parse HEAD && git status -sb && zig version"
```

Expected:
- SSH responds within 5s.
- `git rev-parse HEAD` returns a commit sha (clone exists).
- `zig version` returns `0.16.0`.
- `git status -sb` is clean OR only shows untracked
  build artifacts.

If any fail → `extended_challenge.md` 3-step. Common
remediation:
- Clone missing: `ssh windowsmini "cd ~/Documents/MyProducts && git clone <origin> zwasm_from_scratch"`.
- HEAD drift: `bash scripts/run_remote_windows.sh test-all`
  internally does `git fetch + reset --hard
  origin/zwasm-from-scratch`, so a stale clone is
  self-repaired at first run. No separate pull needed.
- zig version mismatch: re-run `.dev/windows_ssh_setup.md`
  setup steps for the Zig install.

Preflight is a single bash call. **Not a separate cycle**;
runs at the head of the first resume that opens §9.13-0.

## §1 Goal

Close §9.13-0 (Cat IV windowsmini reconcile). Exit per
`.dev/ROADMAP.md` §9.13-0:

- windowsmini `zig build test-all` green incl.
  `spec_assert_runner_non_simd`.
- Bit-identical with Mac aarch64 + ubuntunote x86_64.
- 4 Cat IV debts closed: D-022 / D-028 / D-084 / D-136.

Parallel track: WA (`.dev/decisions/NNNN_phase9_debt_exit_
reframe.md` draft for §9.12-F exit criterion). Autonomous draft;
ADR-flip is the only user touchpoint.

## §2 Parallel-track model

Two independent tracks; the loop drives both:

| Track | Where | Type | User touchpoint |
|---|---|---|---|
| **WA** — §9.12-F exit ADR draft | main session | `architectural` (ADR draft only; no src/ change) | ADR-flip Proposed → Accepted |
| **W0–W6** — §9.13-0 Cat IV chunks | mostly main; W0+W1 may use background subagent | `survey` then `emit` / `infrastructure` then `architectural` (W3 SEH only) | None for W0–W2 / W4–W6; W3 SEH bridge surfaces shim-design ADR at draft |

Anti-pattern guard: this doc must not list "wait for X" or
"needs commitment to Y". Pure work descriptors, ordered.

## §3 Subagent delegation policy (this plan only)

**Delegable (data-collection, no commit authority):**

- **W0** — windowsmini `test-all` foreground run + survey
  note generation. Pure IO + log analysis. Output:
  `private/notes/p9-9.13-0-survey.md` (gitignored).
- **W1** — `run_remote_windows.sh test-all` × 10 + flake-rate
  measurement. Output:
  `private/notes/p9-d028-flake-rate.md` (gitignored).

**Non-delegable (main session only):**

- WA ADR draft (text work that benefits from §18 + framing
  discipline applied in main).
- W2–W6 (code/architectural changes; require diff review +
  ubuntu defer chain per ADR-0076 D2/D3).

**Subagent prompt template** (for the resume cycle that
dispatches W0): see §7 below.

## §4 Hosts + scripts (pre-flight)

- **windowsmini**: `ssh windowsmini` (mDNS). Clone at
  `~/Documents/MyProducts/zwasm_from_scratch`.
- **`scripts/run_remote_windows.sh`**: wrapper. Does
  `git fetch + reset --hard origin/zwasm-from-scratch` on
  windowsmini, then `zig build <step>`. Log to `/tmp/win.log`
  (overwrite).
- **`scripts/should_gate_windows.sh --record`**: phase-boundary
  gate result recorder (run after W4 green).

## §5 Work item details

### W0 — survey (subagent-eligible)

- Command: `bash scripts/run_remote_windows.sh test-all > /tmp/win.log 2>&1`
  (Bash timeout ≥ 1200000 ms; cold build is slow).
- Read log tail (last 400 lines via `tail -n 400 /tmp/win.log`).
- Produce `private/notes/p9-9.13-0-survey.md`:
  - For each FAIL: test name, error class, file:line if
    available, mapping to one of D-022 / D-028 / D-084 / D-136
    (or "new — file new debt row").
  - For pass/skip counts: pasted as-is.
  - Recommended W1–W6 priority order based on evidence.
- Commit: NONE (gitignored notes). Handover update at chunk
  close per main-session Step 7.

### W1 — D-028 flake rate measurement (subagent-eligible)

- Loop: `for i in 1..10; do bash scripts/run_remote_windows.sh test-all > /tmp/win-$i.log 2>&1; echo "run $i exit=$?"; done`
- Aggregate: count `error: test runner failed to respond` per
  run; record exit codes.
- Produce `private/notes/p9-d028-flake-rate.md`: rate / 10,
  named hypothesis if pattern visible (timing? specific test?
  cold-cache only?).
- Commit: NONE (gitignored notes). If rate is 0 over 10 runs,
  W1 close commit may discharge D-028 with rate-reduction
  rationale + ADR.

### W2 — D-084 Win64 v128 marshal residual

- Read: `src/engine/codegen/x86_64/op_call.zig`
  (`captureCallResult`, `marshalCallArgs`) + sibling for
  v128 hidden-pointer handling.
- Identify: where SysV (Linux x86_64) path branches and
  whether Win64 branch exists / is correct.
- Implement: missing Win64 v128 path; mirror SysV semantics
  via Win64 ABI register/stack-slot rules.
- Test gate: Mac fg (`zig build test-all` if substrate
  classification = logic/cohort); ubuntu deferred via
  ADR-0076 D3. windowsmini verified at W4.
- Exit: D-084 row removed from `.dev/debt.md`; relevant
  fixture in `test/spec/` for v128 multi-result green.

### W3 — D-136 Win64 SEH bridge

**Architectural-typed**. ADR draft FIRST per
`.claude/rules/architectural_spike.md`:

- `.dev/decisions/NNNN_win64_seh_bridge.md`:
  - Context: `installSigsegvHandler` is no-op on Windows;
    `sigsetjmp` / `siglongjmp` unavailable; assert_trap
    fixtures cause OS-level process kill.
  - Decision: small C/asm shim (`src/runtime/platform/
    windows_seh_bridge.c` or `.zig` via inline asm)
    wrapping `__try` / `__except` blocks; expose
    `seh_arm()` / `seh_disarm()` / `seh_recover()` Zig-
    callable boundary; semantically equivalent to POSIX
    `sigsetjmp` / `siglongjmp` pair.
  - Alternatives: AddVectoredExceptionHandler (rejected:
    process-wide global state); manual SEH frame walking
    (rejected: undocumented frame layout in Zig).
  - Consequences: D-136 close; `spec_assert_runner_non_simd`
    on windowsmini matches Mac/ubuntu behaviour; 3-host
    bit-identical for assert_trap fixtures.
- After ADR Proposed: implement shim → wire to
  `spec_assert_runner` non-simd runner → windowsmini gate.
- Test gate: same as W2. windowsmini verified at W4.
- Exit: D-136 row removed; `spec_assert_runner_non_simd`
  green on windowsmini.

### W4 — cross-module Windows compat verification

- Run windowsmini `test-all` again after W3 lands.
- For any new FAIL not in W0 survey: file as new debt row OR
  fix inline if mechanical (≤ 5 min). D-022 (Win64 cross-
  platform residual) is the umbrella row for fallout here.
- Exit: D-022 closed; windowsmini `test-all` exit 0.

### W5 — Q6 std.posix.* Windows availability

- Grep for `std.c.write` / `std.c._exit` / `std.c.getenv` /
  `std.c.munmap` in `src/`. If any remaining: convert to
  `std.posix.*` if Windows-available; otherwise leave with
  `// FILE-SIZE-EXEMPT`-style comment naming the constraint.
- Cross-compile sanity: `zig build -Dtarget=x86_64-windows-gnu`
  on Mac (just compile, don't run).
- Exit: build green for Windows target on all hosts.

### W6 — build-option DCE 6 combos × Windows

- Run on windowsmini:
  `for w in v1_0 v2_0 v3_0; do for wasi in p1 p2; do
   zig build -Dwasm=$w -Dwasi=$wasi test-build-completeness;
   done; done`
- Use `nm` / `objdump --syms` to verify excluded ops are
  truly absent from the binary (per ADR-0073 DCE substrate).
- Exit: 6 combos green; `check_build_dce.sh` exit 0 on
  windowsmini.

### WA — §9.12-F exit re-framing ADR (parallel, main only)

- File: `.dev/decisions/NNNN_phase9_debt_exit_reframe.md`
  (assign next NNNN per `.dev/decisions/README.md`).
- Status: `Proposed`.
- Context: §9.12-F current exit "debt active rows < 15";
  current count 19; 13 are deferred to Phase 10+ (structural,
  not closable in Phase 9 scope); 4 are §9.13-0 Cat IV
  (covered by W0–W6 above); 2 are trigger-not-fired
  (D-094 / D-062).
- Decision: re-frame exit to "phase-9-eligible debt cohort
  substantially addressed" — defined as:
  (a) all §9.13-0 Cat IV closed (= W0–W6 done);
  (b) trigger-not-fired debts left with `Status: blocked-by:
       <specific external event>` (testable barrier);
  (c) deferred-to-Phase-N debts left with explicit Phase
       target row.
- Alternatives: hold the numeric bar (rejected: forces
  premature Phase 10+ work); drop the criterion (rejected:
  loses Phase-close hygiene).
- ROADMAP §9.12-F amendment text: included in ADR.
- Surface to user at flip time.

## §6 Work sequence (authoritative — `/continue` reads this)

Each row is one autonomous resume cycle (or close to one).
Step 0–7 of `/continue` per-task TDD loop applies. The
subagent-eligible rows note dispatch protocol; non-delegable
rows proceed in main session.

| # | Item | Type | Subagent? | Output |
|---|---|---|---|---|
| 1 | **W0** survey | `survey` | YES (background) | `private/notes/p9-9.13-0-survey.md`; handover update names W1+W2 priority |
| 2 | **WA** ADR draft | `architectural` (doc-only) | NO | `.dev/decisions/NNNN_phase9_debt_exit_reframe.md` Status: Proposed |
| 3 | **W1** D-028 flake measurement | `survey` | YES (background, after W0 returns OR parallel with WA) | `private/notes/p9-d028-flake-rate.md`; if rate 0 → discharge commit |
| 4 | **W2** D-084 v128 marshal | `emit` | NO | Source diff + Mac green; ubuntu deferred |
| 5 | **W3.a** SEH bridge ADR draft | `architectural` (doc-only) | NO | `.dev/decisions/NNNN_win64_seh_bridge.md` Status: Proposed |
| 6 | **W3.b** SEH shim impl | `emit` (post-ADR) | NO | C/Zig shim + spec_assert_runner integration; Mac+ubuntu green |
| 7 | **W4** windowsmini reconcile run | verification | NO | `bash scripts/run_remote_windows.sh test-all` exit 0; D-022 close |
| 8 | **W5** posix.* Windows availability | `infrastructure` | NO | grep+convert; cross-compile green |
| 9 | **W6** build-option DCE × Windows | verification | NO | 6 combos green; check_build_dce 0 |
| 10 | §9.13-0 close + Phase 9 boundary | phase-boundary | NO | §9.13-0 [x]; `should_gate_windows.sh --record`; §9.12-I batch ADR Status flip; SHA backfill |

## §7 Subagent prompt template — W0 / W1 dispatch

The resume cycle that dispatches W0 uses this brief
verbatim (Agent tool, `subagent_type: Explore`, with
`run_in_background: true`):

```
zwasm v2 project (~/Documents/MyProducts/zwasm_from_scratch/).
Run windowsmini test-all and produce a survey note.

1. Foreground bash:
   bash scripts/run_remote_windows.sh test-all > /tmp/win.log 2>&1
   (Bash timeout 1200000 ms; cold build is slow)
2. Check exit code from /tmp/win.log tail. Read last 400 lines.
3. Produce private/notes/p9-9.13-0-survey.md (markdown):
   - Test run metadata: HEAD sha, host, exit code, pass/fail/skip counts
   - Per-FAIL: test name, error class, file:line if available,
     mapping to one of D-022/D-028/D-084/D-136 (or "NEW")
   - Recommended W1-W6 priority order from evidence
4. DO NOT commit. Notes are gitignored; main session
   captures the artifact reference at next resume.
5. Return a 200-word summary of what was found.

Constraints:
- No source code changes.
- No git commits or pushes.
- Single bash invocation for the test run.
- If windowsmini SSH fails, return with that as the result;
  do not retry beyond once.
```

W1 dispatch uses the same shape with the loop `for i in
1..10; do ...; done` instead of single run, output to
`private/notes/p9-d028-flake-rate.md`.

## §8 Termination criteria

This plan closes when:

- All §6 rows 1–10 complete.
- §9.13-0 row in ROADMAP is `[x]`.
- handover.md retargets to §9.13 (Phase 10 entry hard gate;
  user touchpoint per `/continue` hard-gate detection).

At that point, this file is **archived** (delete or move to
`.dev/archive/` per `.claude/rules/lessons_vs_adr.md`'s
demotion path — this is a plan-doc, not an ADR, so deletion
is the canonical close).

## §9 Subagent monitoring across resumes

Background subagents launched in one resume cycle may
complete in a later one (notification arrives mid-Step). The
main session's next resume:

- Checks `.task-notification` / `BashOutput` arrivals via
  the standard task-tool flow.
- If W0 / W1 subagent has completed → read its output file
  reference + the produced `private/notes/p9-*.md` →
  proceed to row 4 (W2) per §6.
- If W0 still running → fire WA ADR draft (row 2) instead,
  re-arm at end. Both tracks make progress.
- If W0 errored (windowsmini unreachable, etc.) →
  `extended_challenge.md` 3-step procedure on the surfaced
  error.

This avoids the failure mode where main session blocks on
subagent completion or polls — the resume cycle simply
picks whichever row in §6 is unblocked next.

## §10 References

- `.dev/handover.md` — Cold-start pointer.
- `.dev/ROADMAP.md` §9.13-0 (line ~1316) — exit criterion.
- `.dev/debt.md` — D-022, D-028, D-084, D-136 rows.
- `.dev/decisions/0049_*.md` — windowsmini gate deferral.
- `.dev/decisions/0067_*.md` — ubuntunote-x86_64 pivot
  (Rosetta race; informs Win64 expectations).
- `.dev/decisions/0076_*.md` — single-push commit pair;
  ubuntu defer chain.
- `.claude/rules/architectural_spike.md` — W3 ADR-first.
- `.claude/rules/handover_framing.md` — framing discipline.
- `.claude/skills/continue/SKILL.md` Step 1a — close-plan
  override mechanic.
