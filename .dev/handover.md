# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/debt.md` — discharge `Status: now` rows before the active
   task (`/continue` Step 0.5).
3. `.dev/lessons/INDEX.md` — keyword-grep for the active task's
   domain (`/continue` Step 0.4).
4. `.dev/decisions/0014_redesign_and_refactoring_before_phase7.md`
   — historical: §9.6 / 6.K block + Beta-vs-Alpha funcref.
5. `git log --grep="§9.7 / 7\." --oneline` — per-cycle table for
   §9.7 / 7.0–7.4c lives here (was inline; archived 2026-05-04).

## Current state — autonomous loop PAUSED by user 2026-05-04

- **Phase**: Phase 7 IN-PROGRESS — §9.7 / 7.0–7.2 closed; 7.3 op
  coverage CLOSED (111 ops); 7.4a/b/c closed.
- **Last commit**: `cee0be8` (handover sync after `93e2f2c` 7.4c).
  718/718 unit / 3-host green. Phase 6 close at `68843b0`.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active discussion — redesign decisions pending user direction

User raised concerns mid-loop and we agreed on a priority plan
(2026-05-04 chat). Cold-start should treat **A** as the next
concrete action and wait for user direction on B/C/D/E ordering.

### Concerns surfaced

1. **regalloc pool overlaps reserved invariants** (重大)
   `allocatable_gprs = caller_saved_scratch_gprs ++ callee_saved_gprs`
   = X9..X15 + X19..X28. `slotToReg(14..16)` returns X26..X28 →
   silent overwrite of caller-supplied `X24..X28` invariants when
   ≥14 vregs live. Not yet hit (tests use ≤2 slots), but
   structural latent bug. Doc/impl divergence — `abi.zig` says
   "NOT in regalloc pool" but pool includes them.
2. **Linux/Windows hosts skip JIT spec gate** until x86_64 emit
   (currently scheduled Phase 8). User wants this pulled forward
   into Phase 7 to avoid 3-host asymmetry bugs accumulating.
3. **D-014 (Runtime injection)** still caller-supplied skeleton;
   X24..X28 invariant set has grown to 5 — needs structural
   Runtime-driven ABI.
4. **emit.zig 3700+ lines** over 2000 hard cap. Pre-existing.
   Responsibility split is feasible (numeric / memory / call /
   conversion / control / helpers) but **not urgent**.
5. **Edge-case test culture** — need a "気軽に追加" rule for
   boundary tests as optimization phase approaches.

### Agreed priority order (pending final user OK)

| # | Action | Status |
|---|--------|--------|
| A | regalloc pool: drop X24..X28; add `reserved_invariant_gprs` | **NEXT — small, do first** |
| B | Runtime structurization (D-014 dissolve): X0 = `*const JitRuntime`, prologue LDRs X24..X28; ADR required | After A |
| C | x86_64 emit pulled into Phase 7 (ROADMAP edit + ADR per §18) | Parallel/separate track; large |
| D | Edge-case-test rule (`.claude/rules/edge_case_testing.md` + `/continue` Step-4 hook + `audit_scaffolding` check) | Parallel; small |
| 7.4d | wasm-1.0 spec testsuite via JIT | After B (ABI change would force re-write of test harness) |
| E | emit.zig responsibility split | After B/C/7.4d, opportunistic |

### Open user-decision points

1. Is the order A → B → 7.4d → D∥C → E correct?
2. **C scope**: full ARM64+x86_64 parity in Phase 7, or just
   x86_64 foundation in Phase 7 with numeric ops in Phase 8?
3. **B ABI design**: X0 = `*const JitRuntime` with Wasm args
   shifted to X1+, vs. another reg convention?

## Recently closed (per `git log`)

- §9.7 / 7.3 sub-h3b `348a6ef` (trapping trunc f64 source).
- §9.7 / 7.3 op coverage CLOSED (111 ops total).
- §9.7 / 7.4a `1e71b53` JitBlock (mmap MAP_JIT + W^X toggle).
- §9.7 / 7.4b `3e34d1a` linker (first JIT-to-JIT call works).
- §9.7 / 7.4c `93e2f2c` entry frame (i32.load through X28 verified
  end-to-end via inline-asm shim).

## Open structural debt

- **D-014** Runtime injection — see priority B above.
- **D-022** Diagnostic M3 / trace ringbuffer — sub-f trap surfaces
  exist; can dissolve when Phase 7 settles.
- **D-026** env-stub host-func wiring — 4 embenchen + 1
  externref-segment skip-ADR'd; cross-module dispatch.
- **NEW** regalloc/reserved overlap — see priority A above.
- **NEW** 3-host asymmetry (JIT only on Mac aarch64) — see C.

## Phase 6 close — archival snapshot

- 14 §9.6 rows all [x] with SHA. 2 active skip-ADRs (5 fixtures).
- 14 active debt rows, all `blocked-by:` named barriers.
- 2 lessons recorded. v1-class hyperfine baseline at Phase 6 close
  (26 fixtures: 9 shootout + 11 TinyGo + nbody + 5 cljw).
