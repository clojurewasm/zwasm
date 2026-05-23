# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Fresh-session start here

**Authoritative remaining-work source**:
[`phase9_close_master.md`](./phase9_close_master.md)
(§5.3a Phase 9 真スコープ expansion 2026-05-23).

**Mandatory before any §9.x [x] flip**:
`bash scripts/check_phase9_close_invariants.sh --gate`.

**Gate state (mac-host)**: 18/18 passed.
**windowsmini state (2026-05-23 cycle 9)**: D-165 verified
PASS on isolated `test/private/d-165/` mirror of upstream
`fac/manifest.txt` (7 passed, 0 failed; `[d-165] kind=4
count=1` on exhaustion). Full `test-all` reconcile in
background (verifies broader Win64 surface).

## Phase 9 close blockers (current; post-D-165)

3 outstanding items + 1 hard gate:

1. **D-157** (Phase 9 真スコープ, §5.3a) — extend
   `runtime/instance/instantiate.zig` to verify
   table / memory / global import-type at bind time. 56
   Wasm 2.0 `assert_unlinkable` fixtures stop emitting
   `SKIP-NO-LINK-TYPECHECK`. Autonomous-eligible.
2. **D-079 (ii)** (Phase 9 真スコープ, §5.3a) — extend
   `Runtime.globals: []*Value` (ADR-0052 §3 scalar-only) to
   v128-aware via per-entry width carried in
   `globals_offsets/valtypes`; plumb into `instantiate.zig`
   cross-module import wiring. Paired in-source test in
   `src/api/instance.zig`. Autonomous-eligible.
3. **D-139** (Phase 9 真スコープ, §5.3a) — audit c_api
   Instance behaviours lacking spec-corpus coverage; route
   spec_assert through c_api OR add per-c_api-feature
   in-source tests in `src/api/instance.zig`.
   Autonomous-eligible.
4. **§9.13** collab review (hard gate) — ADR-0105 + ADR-0106
   `Proposed → Accepted` flip. User-gated.

After (1-3) land, windowsmini reconcile re-verifies; §9.13-0
[x] flip is then a routine SHA-backfill. Phase 9 = DONE
gated on (4).

## Closed this session (2026-05-23)

- ✅ **R3 / D-162**, **R2**, **R1**, **D-094**, **D-164**.
- ✅ **D-163** SKIP-WIN64-CALL-INDIRECT-TRAP arm retired
  (`0de438a6`); windowsmini cycle 8 verified PASS.
- ✅ **D-165** Win64 internal JIT-to-JIT MEMORY-class + cap
  fix (`75f96dee` + `99a047f6`). Real trigger: pick0's 2nd
  i64-result silently truncated by Win64 cap=1 in
  `captureCallResult`. Verified PASS on windowsmini isolated
  test (cycle 9).

## Cycle 9 follow-up: debug knowledge codification

windowsmini SSH debug workflow learnings codified at:
- `.dev/lessons/2026-05-23-windowsmini-ssh-quoting-traps.md`
  (8 traps + stable `cmd /c` orchestration form).
- `.claude/skills/debug_jit_auto/SKILL.md` Recipes 15-17:
  - 15: `ssh windowsmini cmd /c` orchestration pattern.
  - 16: JIT bytes dump via runner instrumentation (HANG-
    friendly, no debugger needed).
  - 17: manifest-bisect via `test/private/d-165/` scratch.
- `.dev/windows_ssh_setup.md` "cmd /c short-circuit"
  section + log-path convention.
- `build.zig`: `installArtifact(non_simd_assert_runner_exe)`
  for stable `zig-out/bin/zwasm-spec-wasm-2-0-assert[.exe]`
  path (no more `.zig-cache/o/HASH` hunting).

windowsmini SSH-reachable, autonomous-eligible per ADR-0049.

## See

- [`phase9_close_master.md`](./phase9_close_master.md) §5.3a + §6.
- ADR-0104 Revision 2026-05-23 (scope expansion).
- `.dev/debt.md` D-157 / D-079 / D-139 (`now`, Phase 9 scope).
- `.dev/lessons/2026-05-23-{win64-i64-shape-probe-divergence,windowsmini-ssh-quoting-traps}.md`.
- `.claude/skills/debug_jit_auto/SKILL.md` Recipes 15-17.
