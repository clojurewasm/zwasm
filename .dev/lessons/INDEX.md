# Lessons index

> Lightweight "we tried this and learned X" notes. Lessons are **not
> ADRs** — they record observations, spike outcomes, and re-derivable
> design intuitions that don't justify a load-bearing decision
> document but should not be lost across sessions.
>
> See `.claude/rules/lessons_vs_adr.md` for the decision tree
> distinguishing lesson from ADR.

## How to use this file

1. Before starting a non-trivial task, **grep the keyword column**
   below for the area you're about to touch (interpreter,
   cross-module imports, ABI, build.zig, etc.). If a lesson exists,
   read it first.
2. After a spike or surprise, add a row here AND drop the lesson
   file under `.dev/lessons/<YYYY-MM-DD>-<slug>.md`. Keep the file
   ≤ 50 lines.
3. If the same lesson is cited in 3+ places (commits / ADRs / chat
   transcripts), promote to ADR per the lessons-vs-ADR rule.

## Index

| Date       | Slug                                  | Keywords                                                       | One-line                                                                                              |
|------------|---------------------------------------|----------------------------------------------------------------|-------------------------------------------------------------------------------------------------------|
| 2026-05-04 | beta-funcref-encoding-rejected        | funcref, Value.ref, instance identity, cross-module dispatch   | Beta-style packed (instance_id, funcidx) was originally preferred on aesthetics; survey of wasmtime + wazero revealed Alpha (zombie keep-alive) is industry-standard. Beauty-driven design loses to 10 years of production experience. |
| 2026-05-04 | autoregister-spike-regression         | wast_runtime_runner, register, embenchen, linking-errors       | Mirroring wasmtime's `(module $X ...)` → bare-name auto-register made 4 embenchen pass but regressed 9 linking-errors fixtures (5→14 fails); root cause is c_api's import-type validation gap, not the auto-register itself. |

## Promotion to ADR — when to escalate

A lesson promotes to ADR when **any** are true:

- The same lesson has been cited (in commit messages, code comments,
  ADR Alternatives sections) 3+ times.
- The lesson contains a load-bearing decision (one path adopted,
  alternatives explicitly rejected, removal condition spelled out).
- A subsequent ROADMAP / Phase / scope decision rests on the lesson.

Promotion procedure: open `.dev/decisions/NNNN_<slug>.md` with the
lesson content as Context, write the Decision / Alternatives /
Consequences sections, then **delete** the lesson file (the ADR
supersedes it). Update this INDEX accordingly.

## Stale-ness policy

- Lessons that are 6 months old and have never been re-read are
  candidates for archival, **not** deletion. Move to a yearly
  `.dev/lessons/archive/<year>/` subdir; keep the INDEX row but
  shorten the keywords if more recent lessons cover the same area.
- `audit_scaffolding` skill is responsible for periodically
  validating that each lesson row's referenced commit / ADR / file
  path still exists.
