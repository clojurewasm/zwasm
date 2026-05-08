# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/phase8_transition_gate.md` — 🔒 Phase 7→8 hard gate (all 5 sections ☑; awaits user 7.13 sign-off).
3. `.dev/meta_audits/2026-05-08-phase7-close.md` — Phase 7 close meta-audit findings.
4. `.dev/decisions/0019_x86_64_in_phase7.md` / 0021 / 0023 / 0025 / 0026 / 0027 / 0028 / 0029 — recent ADRs.
5. `.dev/debt.md` — discharge `Status: now` rows; review `blocked-by` triggers.
6. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain.
7. `.dev/optimisation_log.md` — F-NNN / R-NNN / O-NNN ledger.

## Current state — Phase 7 / §9.7 / 7.13 🔒 hard gate (5/5 sections ☑; awaiting user sign-off)

直近 commits (latest at top):

- (pending C2) chore(p7): §9.7 / 7.13 gate-close artefacts —
  meta_audit + lesson + bench Phase 7 close baseline + gate doc
  marks; 7.13 row stays `[ ]` pending user sign-off
- `cde3405` refactor(p7): split x86_64/inst.zig (2530→1104 LOC, 4
  ISA-family siblings) + arm64/emit_test.zig (2356→28 LOC + 6
  op-family siblings); discharges §3 file-size box (modulo D-051)
- `bf138df` chore(p7): mark §9.7 / 7.12 [x] (audit boundary pass)
- `a6d9e47` chore(p7): mark §9.7 / 7.11 [x] (three-way differential)
- `fa23eb5` chore(p7): mark §9.7 / 7.10 [x]

**Phase status**: §9.7 / 7.5 + 7.8 + 7.9 + 7.10 + 7.11 + 7.12
all `[x]`. Phase 7 残 row = **7.13 🔒** (hard gate; all 5 gate
sections now ☑) + 7.14 (open §9.8 inline; gated on 7.13).

## 🔒 Phase 7 → Phase 8 hard gate — gate doc fully populated

`.dev/phase8_transition_gate.md` all 5 sections ☑ as of this
commit:

1. **Functional completion** ☑ — 3-host green at `cde3405`
   verified post-split (Mac 28/28 + 1114/1119; Orb 28/28 +
   1098/1119; Win run_remote_windows OK + all runners 0-fail).
   `check_three_host_diff.sh` PASS at `bf138df`.
2. **Debt-ledger** ☑ — 14 Active rows (post D-051 add), all
   `blocked-by:` with concrete barriers; 0 `now`. Barrier-walk
   verified each barrier still holds. `audit_scaffolding §F`
   0 block findings.
3. **Design cleanliness** ☑ — AOT/GC/EH/WASI-p2/SIMD slots all
   reserved + verified. File-size: 2 of 3 hard-cap files split
   this gate (commit `cde3405`); `x86_64/emit.zig` deferred to
   Phase 8 via D-051. Lesson recorded.
4. **§3a deferred-work DAG** ☑ — D-035/D-036/D-037 closed;
   D-029 deferral rationale recorded in §5a.
5. **Strategic review** ☑ — ROADMAP §1+§2 read-back consistent
   with Phase 7 actual; `meta_audit` produced
   `.dev/meta_audits/2026-05-08-phase7-close.md` (4 findings,
   no §1/§2/§4/§5/§9/§14 amendment ADR triggered); §9.8 scope
   text fine as-is (D-050 = Phase 8.0 first task, not scope-text
   change).

**User sign-off needed**: confirm gate doc reads well and flip
ROADMAP §9.7 / 7.13 → `[x]`. After that the loop autonomously
expands §9.8 (per Phase boundary procedure) starting with
D-050 (WASI subset for JIT path) as the first task.

## Phase 7 close baseline (bench)

`bench/results/history.yaml` Phase 7 close entries (commit pending):

- `aarch64-darwin` at `bf138df` — Phase 7 close baseline
- `x86_64-linux` (OrbStack Ubuntu) at `bf138df` — Phase 7 close baseline

Mac vs Orb host-difference baseline IS the load-bearing anchor
for O-002's Phase 8 trigger condition (per gate doc §5b).
windowsmini bench wiring deferred to Phase 8.0 (separate Mac vs
Win bench run is more involved than shared-fs Mac+Orb case).

## Open structural debt (pointers — current; full list in `.dev/debt.md`)

- **D-050** WASI subset for JIT path → Phase 8.0 first task
  (sharpens 7.11 per-fixture comparator).
- **D-051** x86_64/emit.zig 4305 LOC prologue extraction →
  Phase 8 entry-task (mirror of ADR-0021; ADR-grade).
- **D-022** ADR-0028 M3-a-2 trap event runtime write.
- **D-026** env-stub host-func wiring (cross-module dispatch).
- **D-029** parallel-move complete — Phase 8 deferred per §5a.
- 詳細・全 14 Active rows は `.dev/debt.md` 参照。

**Pre-existing infra (out-of-scope)**: `.githooks/pre_commit`
fmt/file_size/lint gate not firing per snake_case mismatch.

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`。
