# Step 5 — Test gate (scope-adaptive; ADR-0076 D1)

Sibling of [`SKILL.md`](SKILL.md). SKILL.md gives the Step 5 outline;
this file has the full pipeline + Step 5b bench-delta sub-step.

## Classify first

```sh
bash scripts/classify_chunk_scope.sh
```

Map the printed class to the **foreground Mac** gate command (ADR-0076
D1). The **background ubuntu** gate is unconditionally `test-all`
(ADR-0076 **D6** — D5-b's no-wait ubuntu removed the latency that once
justified narrow scope; closes the D-260/D-262 x86_64-RUN coverage gap):

| Class       | Mac gate (foreground, waited-on) | ubuntu gate (background, after push) |
|-------------|----------------------------------|--------------------------------------|
| `substrate` | `zig build test`                 | `zig build test-all` (always)        |
| `logic`     | `zig build test-all`             | `zig build test-all` (always)        |
| `cohort`    | `zig build test-all`             | `zig build test-all` (always)        |
| `unclear`   | `zig build test-all`             | `zig build test-all` (always)        |

The classifier drives the **Mac column only**. The ubuntu kick never
consults it — there is no scope decision to get wrong (the D-260
foot-gun: an emit chunk eyeballed to narrow `test`). The script IS the
rule for the Mac column; when its heuristic is wrong, edit
`scripts/classify_chunk_scope.sh` (mirroring `gate_commit.sh` /
`zone_check.sh` discipline). LOOP.md does NOT maintain the judgement
table in prose.

Phase-0 sub-steps 0.1 / 0.2 / 0.3 stay at `zig build` only (build
verify; predates this rule, unaffected).

## Pipeline (ADR-0076 D2 + D3)

1. **Mac runs foreground** with the gate from the class column. Use
   `bash scripts/mac_gate.sh` (no arg = auto-classify; or pass
   `test`/`test-all`) — it runs the scope step + the Mac lint gate and
   exits 0 iff BOTH pass, with an unambiguous `[mac_gate] OK/FAIL` line.
   **Do NOT do `zig build test-all > log; grep -c … log`**: a trailing
   `grep -c` exits 1 on zero matches, which the harness misreports as a
   "command failed" notification on a green build. Inspect the build by
   READING `$MAC_GATE_LOG` (default `/tmp/mac_gate.log`) as a SEPARATE
   step — never append a grep to the gate invocation's exit path.
   Fail-fast — next steps (commit pair / push) need its result inline.
2. **ubuntu does NOT run here.** Kicked AFTER the single push in
   Step 6+7 (ADR-0076 D2), against just-pushed HEAD. Verification of
   prior cycle's ubuntu happens at NEXT cycle's Resume Step 0.7
   (ADR-0076 D3).
3. **windowsmini is a CADENCE-driven BACKGROUND monitoring gate (ADR-0076 D7)** —
   Step 6+7 runs `should_gate_windows.sh`; exit 0 → kick `run_remote_windows.sh
   test-all` (background), then `--record` after the green verify. The **BATCHED**
   cadence (ADR-0076 **D8**: ≥6 commits if the batch touched ABI/calling-convention/
   frame-layout paths, else ≥12; ABI-risk no longer immediate) runs windows once per
   BATCH — keep iteration fast on Mac+ubuntu; **NEVER poll-wait on windows** (kick it
   bg, keep chaining, verify at next Step 0.7). **Win64 red is NOT auto-reverted**
   (heisenbug-prone): re-run once → reproduces = real bug; flake =
   `track_heisenbug.sh` + proceed. (Supersedes the old ADR-0049 stance that
   IGNORED should_gate_windows.sh; the phase-boundary reconcile remains the *strict*
   A13-merge gate.) **OrbStack retired** from
   per-chunk gate per ADR-0067 (D-134 Rosetta race; ubuntunote
   replaces it).
4. **ubuntunote's stdout+stderr redirects to `/tmp/ubuntu.log`**. Log
   is single source of truth. **Re-running `run_remote_ubuntu.sh` just
   to re-grep output is forbidden** — builds take minutes; Read the
   file.

## Per-chunk commands

- `zig build <step> > /tmp/mac.log 2>&1` (Mac aarch64, foreground;
  `<step>` from the Mac column).
- `bash scripts/run_remote_ubuntu.sh test-all > /tmp/ubuntu.log 2>&1`
  (Linux x86_64 via SSH; Bash timeout ≥ 600000 ms for cold builds;
  **`run_in_background: true`**). **Always `test-all`** (ADR-0076 D6 —
  the background gate does not scope-adapt). Wrapper does `git fetch +
  reset --hard origin/zwasm-from-scratch` on remote, then runs `nix
  develop --command zig build test-all` (pinned Zig 0.16.0 from
  `flake.nix`).

## Phase-boundary windowsmini reconciliation (NOT per-chunk)

```sh
bash scripts/run_remote_windows.sh test-all > /tmp/win.log 2>&1
```

Runs once at Phase close. Script does `git fetch + reset --hard
origin/zwasm-from-scratch` on windowsmini clone at
`~/Documents/MyProducts/zwasm_from_scratch` and runs `zig build
test-all`. After full green: `bash scripts/should_gate_windows.sh
--record`. See [`LOOP.md`](LOOP.md) §"Phase-boundary Windows
reconciliation".

## Gate verdict per cycle

**Mac MUST be green to proceed to Step 6+7**; ubuntu verified one
cycle later at Resume Step 0.7; windowsmini per Phase boundary.

Prior cycle's ubuntu FAIL at Step 0.7 → current cycle reverts prior
commit pair and switches to fix mode.

## Host setup pointers

- ubuntunote SSH: `.dev/ubuntunote_setup.md` (mDNS `ubuntunote.local`,
  key auth, NOPASSWD sudo, Determinate Nix + flake-pinned Zig).
- Windows SSH: `.dev/windows_ssh_setup.md`.
- OrbStack scratch: `.dev/orbstack_setup.md` (interactive dev only;
  NOT per-chunk gate).

## Host apparent-absence — extended challenge

If a host appears absent (`ssh: connection refused` / no DNS for
ubuntunote / windowsmini), bucket-2 stop requires "provably absent" —
and what counts as "provable" is defined by
[`extended_challenge.md`](../../rules/extended_challenge.md). Walk the
3-step procedure (Confirm → Self-provision → Document specifically)
**first**; only stop if Steps 1+2 actually ran and confirmed
structural absence. "I assume it's absent" is NOT a proof.

Provisioning failures or missing tooling on an otherwise-reachable
host (e.g. windowsmini's wasmtime-stub case from §9.6 / 6.F) are
usually not stop conditions — file a debt entry naming the structural
barrier and proceed.

## Step 5b — Bench-delta sub-step (Phase 8b only; ADR-0032)

After three-host test gate passes AND active task is a **bench-driven
optimisation row** (currently §9.8b rows; future Phases tagged the
same way), capture per-fixture bench delta:

```sh
bash scripts/run_bench.sh --quick --diff HEAD~1 > /tmp/bench-delta.md
```

Output table goes verbatim into commit message body under `## Bench
delta` heading. **Both positive and negative movements surface** —
loop neither cherry-picks positives nor hides regressions. Regression
on any recorded fixture without paired explanation in commit body is
a Step-7 forbid.

### Trigger conditions (ALL must hold)

- Active row is in §9.8b OR a Phase-section explicitly tagged
  "bench-driven" in its ROADMAP description.
- Diff modifies `src/ir/`, `src/engine/codegen/`, or other
  optimisation-pass-touching files.
- §9.8a foundation rows 8a.1 / 8a.2 / 8a.3 are all `[x]` (bench-delta
  script + observability infra exist).

When ANY trigger fails, Step 5b is **skipped** — Phase 8a foundation
work and non-optimisation Phase rows don't require per-commit bench
delta (would be ceremony noise).

Discipline exists because the autonomous loop demonstrated in §9.8 /
8.4 cycles that landing optimisations without measuring per-pass
effect produces "implemented but unmeasured" work; ADR-0032 codifies
the bench-driven sequencing.
