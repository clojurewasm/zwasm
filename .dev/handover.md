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
   — §9.6 / 6.K work-item block.
5. `.dev/decisions/0012_first_principles_test_bench_redesign.md`
   — Phase 6 reopen scope.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** — 6.K + 6.E + 6.F all `[x]`.
  6.G〜6.J pending. Today's session also landed a meta-improvement
  pass (debt + lessons + extended-challenge + ADR amend) — **not
  pushed yet**.
- **Last commit**: `d9aecda` — chore(meta) §14 anchor extended_challenge
  rule. (ahead of origin by ~10 meta commits since `ccd537d`.)
- **Branch**: `zwasm-from-scratch`. **Push pending user approval**
  (per CLAUDE.md "Pushing outside the autonomous /continue loop
  requires explicit user approval"; today's commits were authored
  in dialogue not in the loop).

## Active task — §9.6 / 6.G (ClojureWasm guest end-to-end)

Per ROADMAP §9.6 / 6.G: substrate is CW v1 (vendoring procedure
in [`.dev/cw_guest_setup.md`](cw_guest_setup.md), landed today
in `65b155a`). CW v2's wasm backend ships at CW Phase 14+; the
path-dep mechanism is deferred until then.

Concretely: vendor `~/Documents/MyProducts/ClojureWasm/bench/wasm/{fib,gcd,arith,sieve,tak}.wasm`
into `test/realworld/wasm/cljw_*.wasm`, run the existing 3-runner
pipeline (parse / run / diff vs wasmtime), close 6.G.

## Today's meta-improvement landings (Phase 6 honest-debt cycle)

Driven by user dialogue (2026-05-04) on why Phase 6 accumulated
workarounds + needed repeated user intervention. Step A landed
the indispensable instruction-system gaps (debt / lessons /
extended_challenge / ADR-vs-lesson rule / scripts / audit
checks); Step B paid down the most concrete specific debt and
amended the ADRs / ROADMAP for honesty.

Commits (`8be96bc..d9aecda`):

| SHA       | What                                                                                    |
|-----------|-----------------------------------------------------------------------------------------|
| `def3222` | /continue — add Step 0.4 (lesson scan) + Step 0.5 (debt sweep)                          |
| `40106e5` | CLAUDE.md — point at debt + lessons + extended-challenge                                |
| `0a83216` | trace-audit fixes — lesson+ADR-amend coexistence rule + skip-ADR fixture path           |
| `8be96bc` | close D-001/2/3/5/13/19 — drift sweep + extracted helper                                |
| `e4e7493` | close D-004 + D-015 — ADR-0014 honest amend (Beta footprint + spike-discovered partial-init) |
| `65b155a` | §9.6 / 6.G — substrate procedure (CW v1 vendor) + ROADMAP amend                         |
| `d9aecda` | §14 — anchor extended_challenge rule as forbidden pattern                               |

(Plus 3 prior in this conversation: doc-system bundle + scripts
+ audit_scaffolding update — see `git log --grep "chore(meta):"`.)

## ROADMAP §9.6 — task table snapshot (authoritative is `.dev/ROADMAP.md`)

| #     | Description                                                                          | Status         |
|-------|--------------------------------------------------------------------------------------|----------------|
| 6.K.* | 6.K.1〜6.K.8 (per ADR-0014 §2.1)                                                     | all [x]        |
| 6.E   | misc-runtime re-measure + close (266 PASS / 5 deferred via 2 skip-ADRs)              | [x] `b569b8f`  |
| 6.F   | test-realworld-diff 30+ matches + re-add to test-all (39/50 matched, 0 mismatched)   | [x] `ccd537d`  |
| 6.G   | CW guest end-to-end (CW v1 vendor per [`cw_guest_setup.md`](cw_guest_setup.md))      | [ ] **NEXT**   |
| 6.H   | bench honest-baseline migration (per ADR-0012 §7)                                    | [ ]            |
| 6.I   | bench restructure + sightglass (per ADR-0012 §3)                                     | [ ]            |
| 6.J   | strict close gate (100% PASS or skip-ADR; Phase Status widget flip)                  | [ ]            |

## Open questions / blockers

- Push of meta-commits requires user approval (autonomous push
  policy is per-`/continue`-loop only; this conversation is
  dialogue-driven).
- 6.G vendoring (the actual `cp` of CW v1 wasm files) is not in
  this session's scope — next /continue cycle picks it up.

## Phase 6 close → Phase 7 (JIT v1 ARM64) — direct transition

ADR-0014 cancels the placeholder "post-Phase-6 refactor phase"
wiring. Phase 7 is unchanged. The `continue` skill's standard
§9.<N> → §9.<N+1> phase boundary handler applies as-is once
6.G + 6.H + 6.I + 6.J all `[x]`.
