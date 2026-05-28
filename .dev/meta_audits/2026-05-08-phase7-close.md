# Meta-audit 2026-05-08 — Phase 7 → Phase 8 transition gate

> **Doc-state**: ARCHIVED-IN-PLACE

## Trigger

Phase boundary (§9.7 / 7.13 collaborative review) + user-explicit
invocation per gate doc Section 5.

## Read-list (Step 0)

ROADMAP §1 / §2 / §9.7 / §14 / §15 + the 5 most recent ADRs
(0025-0029) + `handover.md` + `debt.md` + `lessons/INDEX.md`.

## Findings (Step 1, 4 honest-lens questions)

### Q1 — Phase scope drift

Phase 7 landed 5 mid-stream ADRs (0025-0029). Each is honest
(real Alternatives, named removal conditions). The volume signals
that Phase 7's original ROADMAP shape was less complete than
designed; ADR-0019 already amended the phase scope mid-stream
(ARM64 + x86_64 baseline together rather than staggered). Healthy
adaptation, not silent drift.

### Q2 — Recent-ADR honesty

ADR-0028 (Diagnostic M3 ringbuffer) explicitly defers M3-a-2 with
D-022 as the concrete tracker. ADR-0029 (skip-impl vs skip-adr-N)
sharpens an ambiguity the autonomous loop would otherwise have
silently resolved. ADR-0023 (src/ directory normalization)
landed mid-Phase-7 as a rolling hard gate. All 5 ADRs read as
load-bearing; no Revision-history "refinement" that should have
been a fresh ADR.

### Q3 — §14 near-misses (load-bearing)

**File-size hard cap (A2)**: 3 active violations at Phase 7
close — `x86_64/emit.zig` (4305 LOC), `x86_64/inst.zig` (2530
LOC), `arm64/emit_test.zig` (2356 LOC). emit.zig regrew by ~1500
LOC over 2 days post the D-030 8-chunk split, with no pause from
the autonomous loop. The line was crossed silently, and
"acknowledged + tracked" was treated as "fine to continue".
**This is the worked example the meta_audit skill was designed
to catch.** Disposition this gate: inst.zig + emit_test.zig
split during the gate review (user filter "意味があるなら");
emit.zig deferred via D-051 (mirror of ADR-0021's prologue
extraction). Lesson recorded:
`.dev/lessons/2026-05-08-file-size-blindspot.md`.

No other §14 lines crossed.

### Q4 — §15 decision-point readiness

§15 "End of Phase 7" entry asks: "does the interpreter v1-surface
readiness merit pulling forward Phase 11 (WASI 0.1 full) or Phase
13 (wasm-c-api full) before Phase 8 JIT optimisation?"

7.10 realworld JIT data: 45/55 compile-pass on x86_64; 0/55
RUN-PASS because the JIT side has no WASI host wiring. Interp
side completes 44/55 because WASI host stubs exist there. This is
exactly D-050's territory: a minimal WASI subset (proc_exit /
fd_write / fd_read / etc.) wired to JIT-callable host_dispatch
thunks would unlock the per-fixture interp-vs-JIT execution
comparator and convert ~40 RUN-TRAP fixtures to RUN-PASS.

**§15 finding**: there IS evidence to pull a **WASI subset (per
D-050 sub-task 1)** into early Phase 8 (= part of §9.8.0 or
§9.8.1), not full Phase 11. This isn't a phase reorder, it's a
targeted scope blend. User decision is whether §9.8 scope text
should mention this explicitly OR D-050 stays as `now` debt
that Phase 8's first task picks up.

## Artefacts produced

- Lesson: `.dev/lessons/2026-05-08-file-size-blindspot.md` —
  the §14 acknowledgment vs enforcement gap (Q3 finding).
- This report: `.dev/meta_audits/2026-05-08-phase7-close.md`.
- Debt row: `D-051` (added pre-meta_audit; Phase 8 prologue
  extraction tracker; cited by this report's Q3 disposition).
- Gate-doc Section 5: `D-029 deferral rationale` text + Phase 11
  pull-forward note + `O-002` trigger sharpening (host-baseline
  derivation per Mac-vs-Orb bench).

## Out of scope (deferred)

- ADR for §9.8 scope text amendment — only fires if user accepts
  Q4 finding's "pull WASI subset forward" framing.
- ROADMAP §14 amendment to make "acknowledged + tracked" weaker
  than "fixed in this commit" — deferred. The lesson + LOOP /
  CHECKS process refinement is sufficient until the next phase
  produces another worked example.

## Trigger conditions to refine

- `audit_scaffolding §J` should escalate file-size hard-cap
  violations from `watch` to `block` at phase boundaries
  specifically (not just `soon`). Today's audit-2026-05-08-
  phase7-close.md called the 3 hard-cap violations `watch`,
  which is one severity below what §14 demands.

## Self-review (Step 3)

Pass 1 (completeness + ordering): all 4 lens questions answered;
artifacts cover lesson + report + gate-doc + debt; no source code
edits proposed by this audit (subagent splits handle the
mechanical part separately). ✓

Pass 2 (risk + commit granularity): zero code risk (all
process docs); single commit per ROADMAP §18.2 — the meta-audit
artifacts + the file-size split + gate-doc edits land together as
the Phase 7 close commit. ✓

## Trigger backfill

This meta_audit fired at Phase boundary per default trigger.
`audit_scaffolding §J.7` (suggest meta_audit) emitted on
2026-05-08-phase7-close audit; user gate cleared via
collaborative review at gate doc Section 5 step.
