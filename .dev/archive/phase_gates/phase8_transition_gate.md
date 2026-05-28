# Phase 7 → Phase 8 transition gate

> **Doc-state**: ARCHIVED

> **Hard human-in-loop gate** before §9.8 opens. The autonomous
> `/continue` loop **must stop** when it reaches this gate and
> surface to the user; no `ScheduleWakeup` fires until the gate
> checklist below is collaboratively cleared.
>
> Anchored from ROADMAP §9.7 / 7.13 (the gate row) and from
> `.claude/skills/continue/SKILL.md` §"Phase boundary — inline,
> no stop" carve-out for Phase 7 → 8.

## Why this gate exists

v1 had multiple "interpreter was actually fast" surprises (W43 /
W44 / W45 hoist, coalescer, post-hoc liveness drift, D116
abandoned address-mode folding). Phase 8 in v2 is the JIT
optimisation foundation — the wrong starting baseline here
contaminates Phase 9 / 11 / 15 measurements for the rest of the
project. We want **a single deliberate-skepticism pause** to
confirm:

1. Phase 7 actually delivers a clean baseline (3-host green,
   realworld coverage, three-way differential 🔒).
2. Debt is honestly cleared, not parked.
3. The design still reads cleanly when extrapolated to AOT +
   Wasm 3.0 + WASI extensions + SIMD landing.
4. The optimisation candidate space is enumerated and triaged
   **before** we start adopting things, so we adopt on bench
   numbers — not gut feel.

The gate is intentionally **collaborative** — `audit_scaffolding`
is automatic and flags drift, but the strategic judgment ("is
this clean enough?") is human-in-loop.

## Checklist (must all be ☑ before §9.8 opens)

### 1. Phase 7 functional completion

- [x] `zig build test-all` green on all three hosts (Mac
      aarch64 + OrbStack Ubuntu x86_64 + windowsmini), latest
      pushed commit. Verified at `cde3405` (post file-size
      split): Mac 28/28 steps + 1114/1119 tests, Orb 28/28 +
      1098/1119, Win run_remote_windows OK + all runners 0-fail.
- [x] §9.7 / 7.5 spec gate: pass=fail=skip=0 via ARM64 JIT
      on Mac. `spec_assert_runner: 212 passed, 0 failed,
      20 skipped (= 0 skip-impl + 20 skip-adr)` per ADR-0029.
- [x] §9.7 / 7.8 spec gate: pass=fail=skip=0 via x86_64 JIT
      on both Linux x86_64 + Windows x86_64. Identical
      `212/0/20` total on Orb + Win at `cde3405`.
- [x] §9.7 / 7.9 + 7.10 realworld: ≥ 40/50 samples passing
      on both ARM64 and x86_64. ARM64 47/50 effective
      (compile-pass 52/55), x86_64 40/50 effective
      (compile-pass 45/55) on both Orb + Win.
      `realworld_run_jit_runner: 45/55 compile-pass`
      IDENTICAL on both x86_64 hosts.
- [x] §9.7 / 7.11 three-way differential 🔒 lock: 0 mismatch
      over spec + realworld on each host. **This is the
      load-bearing 🔒 of the project.**
      `bash scripts/check_three_host_diff.sh` PASS at `bf138df`
      (cross-host total anchors all matched); same anchors
      preserved at `cde3405` (split is engine-pure, no
      semantic delta).

### 2. Debt-ledger honest reconciliation

- [x] Every `Status: now` row in `.dev/debt.md` discharged.
      Verified at gate-prep: 0 `now` rows. D-049 was the most
      recent discharge (2026-05-08, §9.7 / 7.10-m via
      `ff1e62a`).
- [x] Every `Status: blocked-by:` row whose named barrier was
      dissolved during Phase 7 flipped to `now` and discharged
      (or re-justified with current `Last reviewed`). Gate-prep
      barrier-walk on all 14 Active rows (D-026, D-007, D-009,
      D-010, D-011, D-016, D-017, D-018, D-020, D-021, D-022,
      D-028, D-050, D-051): every named barrier still concrete
      (Zig=0.16.0, build.zig=570 < 600 LOC, private/dbg has 1
      entry < 5, Phase 14/8/M3-a-2/etc. not yet open).
- [x] No row's `Last reviewed` older than the start of Phase
      7. Phase 7 start = 2026-05-03 (commit `b336e78`).
      Earliest `Last reviewed` = 2026-05-04 (D-026, D-016-021).
- [x] `audit_scaffolding §F` produces zero `block` findings on
      debt coherence.
      `private/audit-2026-05-08-phase7-close.md`: 0 block /
      3 soon / 3 watch (none of the 3 watch are §F-class).

### 3. Design cleanliness extrapolation

Phase 8 is followed by Phase 11 (AOT), Phase 14 (concurrency
+ thread support), Phase 15 (advanced JIT optimisation), and
proposal-driven Phases for Wasm 3.0 GC / EH / SIMD / WASI
preview2. The current shape must remain clean under that
horizon.

- [x] **AOT**: `engine/codegen/aot/` slot exists (already
      reserved per ADR-0023). Confirmed: `src/engine/codegen/aot/`
      directory present (single placeholder file, awaiting Phase
      11). JIT codegen consumes ZIR+regalloc.Allocation; AOT
      will reuse the same outputs without interpreter coupling.
- [x] **Wasm 3.0 GC** (proposal phase advance expected post
      Phase 8): `Value` extern union + `feature/gc/` slot
      reserved. Confirmed: `src/feature/gc/register.zig` exists;
      `Value` (in `src/runtime/value.zig`) extern-union-encodes
      funcref + externref; `(ref T)` type widening lands by
      adding union variants without restructuring callers.
- [x] **Wasm EH** (proposal phase advance expected post Phase
      8): trap stub design (`bounds_fixups` → ADR-0028 M3 ring
      buffer) extends naturally to per-tag exception payloads.
      Confirmed: `bounds_fixups` shape is per-trap-reason
      labelled (= per-tag-payload-ready); ADR-0028 M3-a-1 ring
      buffer infra landed; M3-a-2 (D-022) still pending but is
      Phase 8+ work, not Phase 7 close blocker.
- [x] **WASI preview2**: `wasi/` subsystem can extend to
      `WasiP2Component` without breaking p1 (`preview1.zig`)
      consumers. Confirmed: `src/wasi/preview1.zig` +
      `src/wasi/jit_dispatch.zig` are p1-namespaced; p2 lands
      as new `wasip2.zig` siblings (mirror pattern).
- [x] **SIMD**: `feature/simd/` slot exists. `Value.v128`
      already lands in `extern union`. Confirmed: ZIR has full
      v128 opcode space (load/store, lane ops, all i8x16/i16x8/
      i32x4/i64x2/f32x4/f64x2 families) + `simd` RegClass +
      `simd_base_special` reservation per ROADMAP §4.2.
- [x] Zone architecture (post-ADR-0023) has zero violations
      (`bash scripts/zone_check.sh --gate` exit 0). Verified
      at `cde3405`.
- [x] File-size soft caps: no Phase 7 file at > 2× soft-cap
      LOC. **Disposition this gate** (per user filter
      「意味があるならやりたい」): `x86_64/inst.zig` (2530 →
      1104 LOC) + `arm64/emit_test.zig` (2356 → 28 LOC
      orchestrator + 6 op-family siblings, all under 1000 LOC)
      split this gate (commit `cde3405`). `x86_64/emit.zig`
      (4305 LOC) deferred to Phase 8 entry-task via D-051
      (mirror of ADR-0021 prologue extraction; ADR-grade).
      Lesson recorded: `2026-05-08-file-size-blindspot.md`
      surfaces the §14 acknowledgment-vs-enforcement gap that
      let emit.zig regrow post-D-030 split.

#### 3a. Phase 7 → 8 deferred-work dependency DAG

Phase 7 closing leaves a stack of "Phase 8 follow-up" deferred
pieces whose **inter-dependency is implicit** across debt rows
and ADR References. Surface that dependency before §9.8 opens
so we can sequence Phase 8 work without false-start re-deletions.

Discovered during §9.7 / 7.5-spec-assertion-driver-{o,p,q}:

```
    ┌─────────────────────────────┐
    │ Class-aware regalloc        │ ← root of the DAG
    │ (per-class max_reg_slots,   │
    │  not the GPR-sized cap)     │
    └────────┬────────────────────┘
             │
             ├──► FP-class spill staging (V-class scratch +
             │    encLdrSImm/encStrSImm spill paths)
             │     │
             │     └──► op_alu_float / op_convert / bounds_check
             │          (17 sites today flagged by
             │           `scripts/spill_aware_check.sh`)
             │
             ├──► Wasm 2.0 multi-value blocks (D-035)
             │     │
             │     ├──► parser typeidx-blocktype path
             │     ├──► validator multi-result resolve
             │     └──► op_control.emitBlock multi-value merge
             │
             └──► x86_64 emit refactor (D-030: 9-module split,
                  + D-029 parallel-move) reuses ARM64's
                  spill-staging shape but only after
                  class-aware regalloc lands; otherwise the
                  same `max_reg_slots` mismatch trap fires
                  on x86_64 with 4-vs-8 register-pool sizing
                  (cross-module sync rule, per
                  `.dev/lessons/2026-05-06-regalloc-pool-size-mismatch.md`).
```

**`skip=0` semantics anchor (ADR-0029)**: §9.7 / 7.5 + 7.8 exit
criteria's `skip=0` counts only `skip-impl` (implementation-gap +
test-shape); `skip-adr-<id>` (proposal-skip ADR) is excluded by
construction. Every proposal-skip ADR cited under
`.dev/decisions/skip_*.md` MUST have a removal condition
consistent with §9.8+ phase plan — gate review checks this.

**Sequencing constraint**: each successor needs its predecessor
landed first; otherwise the same lessons re-pay. Specifically:

- [x] `class-aware-regalloc` chunk landed (separate
      `max_reg_slots_gpr` / `max_reg_slots_fp`). D-036
      discharged 2026-05-06 via commit `f1c3ce3`. The
      `chunk-q resolveFp shim` is gone; FP boundary flows
      through the standard `Allocation.slot(vreg, class)` API.
- [x] `fp-spill-machinery` chunk landed. D-037 substantially
      discharged 2026-05-06 via commit `2daaded`:
      `abi.allocatable_v_regs` shrunk + V29/V30 reserved as
      `fp_spill_stage_vregs`; `fpLoadSpilled` / `fpDefSpilled`
      / `fpStoreSpilled` helpers added; 15 of 17 BASELINE
      sites migrated. D-038 closed the residual op_control
      sites 2026-05-07 via `<this>` (BASELINE 2 → 0).
- [x] D-035 (Wasm 2.0 multi-value) landed. Closed via
      commits `601c7da` (validator + lower) +
      `a2679f4` (emit gate) + `13701e6` (emit-side N-MOV
      chain). Both backends widen `Label.merge_top_vregs:
      [8]u32 + result_arity: u8`.
- [x] D-030 + D-029 disposition: D-030 (x86_64 emit 8-chunk
      split) discharged 2026-05-07 across commits
      `cd3ced5`/`874b10b`/`aec4e3c`/`981d879`/`edd9d20`/
      `ec37a59`/`4a7fe4a`/`78bb577`. D-029 (parallel-move
      complete) explicitly deferred to Phase 8 — rationale
      recorded in §5 Strategic review below + tracked via
      O-002 in `.dev/optimisation_log.md`.

The **why**: v1's W54 post-mortem proved that "we'll fix it
later" deferrals compound silently when the dependency
direction isn't published. Every deferred piece in this DAG
has at least one predecessor it cannot bypass — landing them
out of order means re-doing earlier work.

### 4. Optimisation log triage

- [x] `.dev/optimisation_log.md` has `bench/results/history.yaml`
      datapoints recorded for Phase 7 close baseline (= zero
      point for every Phase 8 measurement). Three entries
      now in history.yaml:
      - `aarch64-darwin` at `bf138df`, reason "Phase 7 close
        baseline (Mac aarch64; Quick mode 3 runs + 1 warmup)"
        — full 26-fixture inventory.
      - `x86_64-linux` at `bf138df`, reason "Phase 7 close
        baseline (Linux x86_64 OrbStack Ubuntu; Quick mode
        3 runs + 1 warmup)" — full 26-fixture inventory.
      - `x86_64-windows` at `22147629`, reason "Phase 7 close
        baseline (Windows x86_64 windowsmini; Quick mode
        3 runs + 1 warmup; PARTIAL — 3/26 fixtures)" —
        captured before manual halt at fixture 5. Pulled
        forward at user direction; finding: Windows hyperfine
        is ~12x slower than Mac on hot fixtures (fib2 took
        8m24s/run × 4 runs = 33min on windowsmini vs 40s/run
        on Mac aarch64). Full windowsmini inventory ≈ 5+
        hours; deferred to Phase 8.0 once CI bench picks up
        the slack OR a windowsmini-specific subset is
        defined. matrix and beyond not captured.
- [x] Every `O-NNN` candidate row reviewed: O-001 + O-007 stay
      `Investigating` (count 2, threshold 3). O-002, O-004,
      O-005, O-006, O-008, O-009, O-010 are `Deferred` with
      concrete triggers (most are spec-proposal-phase-advance
      or bench-landing gated). O-002's trigger sharpening
      surfaced in §5 Strategic review below — needs a
      Mac-vs-Orb host-baseline derivation before "x86_64 N%
      slower than ARM64" is meaningful.
- [x] Every `R-NNN` row's re-evaluation trigger re-checked:
      none of the 8 R-NNN row triggers fired during Phase 7
      (Wasm 3.0 GC at spec phase 3 not 4; no bench-driven
      hot-loop slowdown observed; Zig 0.16 still in use; etc.).
      No mirrors to O-NNN required.
- [x] No `Adopted` row missing commit SHA. No `Deferred` row
      missing concrete trigger. **Verification**: zero `Adopted`
      O-NNN rows exist (Phase 8+ candidates haven't begun
      adoption). All `Deferred` rows carry concrete triggers
      (spec-phase advance / bench landing / phase boundary)
      except O-002 — which is sharpened below in §5.

### 5. Strategic review (collaborative, human-in-loop)

This is the only checklist item the autonomous loop **cannot**
self-resolve. The user and assistant work through:

- [x] Re-read ROADMAP §1 (project mission) and §2 (P/A
      principles). Does Phase 7's actual landing match what
      §1/§2 promised?
      **Verdict**: yes. §1.1's three Phase-7-relevant claims —
      "shared mid-IR (ZIR)", "single-pass JIT for ARM64 +
      x86_64", "differential-tested" — all delivered: ARM64 +
      x86_64 emit consume the same ZIR + regalloc.Allocation;
      no SSA optimisation passes (P6); `check_three_host_diff`
      🔒 PASS at `bf138df`. §1.2's v0.1.0 commitments
      (Wasm 3.0 / WASI / wasm-c-api full) remain Phase 8-13
      work — Phase 7 was never expected to deliver them.
      §2 P1/P3/P6/P7/P10/P11/P12/P13/P14 all consistent with
      Phase 7's actual shape. No drift detected.
- [x] **`meta_audit` skill invocation** — runs the periodic
      deliberate-skepticism pass against ROADMAP §1/§2/§9/§14/§15
      and recent ADRs. Output:
      `.dev/meta_audits/2026-05-08-phase7-close.md`.
      Findings: Q1 (5 mid-Phase ADRs = healthy adaptation),
      Q2 (ADR honesty preserved), Q3 (file-size hard-cap blind
      spot — addressed this gate via split commit `cde3405`
      + D-051 deferral + lesson `2026-05-08-file-size-blindspot.md`),
      Q4 (§15 signal: D-050 WASI subset is a Phase 8.0
      candidate per the Phase-7 realworld-JIT-RUN gap).
- [x] Phase 8 scope confirmation: is "JIT optimisation foundation"
      still the right framing?
      **Verdict**: framing is correct, scope text is fine as-is.
      D-050 (minimal WASI host wiring for JIT-callable
      `host_dispatch_base` thunks) is a **first task within
      Phase 8** rather than a §9.8 scope-text amendment — it
      unlocks the per-fixture interp-vs-JIT execution
      comparator (= sharpened 7.11 follow-up) before the
      optimisation work proper begins. No ADR needed; D-050
      stays as `now` debt that Phase 8.0 picks up.
- [x] Adoption-trigger audit: of the candidates moved to
      `Adopted` in step 4, are bench numbers actually present?
      **Verdict**: zero `Adopted` O-NNN rows exist
      (`optimisation_log.md` Candidate table has only
      `Investigating` / `Deferred` rows). Trivially passes —
      no gut-feel adoption to demote. R-001 / R-008 stay
      `Rejected` (their re-evaluation triggers stayed cold).
- [x] Decision log: open `.dev/decisions/NNNN_phase7_close.md`
      ADR if any §1/§2/§4/§5/§9/§14 text needs amendment as a
      result of this review.
      **Verdict**: no §1/§2/§4/§5/§9/§14 amendment needed.
      meta_audit's findings are process refinements (lesson
      + LOOP/CHECKS gap callout), not load-bearing decisions.
      Per `lessons_vs_adr.md` decision tree, this is lesson
      territory, not ADR. No new ADR fires from this review.

#### 5a. D-029 (parallel-move) deferral rationale

Per §3a's last bullet, D-029's deferral to Phase 8 must be
recorded here. Rationale:

- **Structural impossibility today**: parallel-move complete
  coverage requires the x86_64 regalloc to be class-aware
  (D-036 closed; foundation laid) AND for `regalloc2`-class
  slot reuse + cycle detection algorithm to be ported. This
  is registered as `O-002` in `optimisation_log.md` — a
  Phase 8 candidate, not a Phase 7 close blocker.
- **Why not now**: porting parallel-move atop the just-closed
  D-036 + D-037 + D-035 stack would re-pay the cost of
  re-deriving them under the new constraint set. ROADMAP P14
  ("optimisation lands last in commit order") and the
  `bug_fix_survey.md` discipline argue for **bench-driven
  adoption**: land Phase 8.0's WASI subset (D-050) first to
  enable per-fixture comparators, then measure whether
  parallel-move's expected 3-5% on hot loops surfaces
  meaningfully on real workloads.
- **Concrete Phase 8 trigger** (sharpens O-002): "when bench
  shows x86_64 hot-loop fixture (e.g. `rust_sha256` /
  `tinygo_tak` / `cljw_*`) is N% slower than ARM64 on the
  same fixture, AFTER subtracting the Mac-vs-Orb host-
  difference baseline derived from this gate's
  `bench/results/history.yaml` Phase 7 close entries". The
  host-difference baseline IS the load-bearing prerequisite
  the user surfaced ("そもそも Mac の OrbStack Ubuntu と
  Mac 側でなにか一般的に速度差がどれくらいあるのかを計測
  できるものを用意して比較してから算出"); without it,
  "x86_64 5% slow" conflates JIT quality with the
  virtualisation-on-Mac penalty.

#### 5b. Host-difference baseline (Phase 7 close)

Per-host bench at the Phase 7 close gate:

- **Mac aarch64-darwin** at `bf138df` — full 26-fixture inventory.
- **Linux x86_64 OrbStack Ubuntu** at `bf138df` — full 26-fixture inventory.
- **Windows x86_64 windowsmini** at `22147629` — PARTIAL
  3-fixture (fib2, sieve, nestedloop) before manual halt.

**Observed Mac:Win slowdown ratios** (load-bearing for O-002
trigger derivation):

| Fixture | Mac aarch64 | Win x86_64 | Ratio Win/Mac |
|---|---|---|---|
| shootout/fib2 | 43102 ms | 504584 ms | **11.70x** |
| shootout/sieve | 15110 ms | 75518 ms | **4.99x** |
| shootout/nestedloop | ~6.6 ms | 23.4 ms | **3.54x** |

The slowdown ratio varies by fixture (3-12x), implying it's
not a uniform host-speed delta but rather a Windows-specific
penalty that scales with workload type (likely interpreter
hot-loop overhead amplified by MSVC ABI + unoptimised release
build path on windowsmini's older hardware).

**Implication for Phase 8 O-002 (x86_64 regalloc port + parallel-
move) trigger derivation**: when a Phase 8 hot-loop bench
shows "x86_64 is N% slower than ARM64", the comparison must
explicitly state which x86_64 host (Linux OrbStack vs Win
windowsmini) AND subtract the corresponding Phase 7 close
host-baseline ratio above before claiming a JIT-quality
delta. Conflating host-speed difference with JIT-quality
difference would risk re-pre-mature O-002 adoption (= the
gut-feel-adoption anti-pattern §4 explicitly forbids).

User-facing analysis tooling (per-fixture ratio extractor +
host-baseline subtraction calculator) deferred to Phase 8.0
— out-of-scope for Phase 7 close, but the load-bearing
**raw data** is preserved in `bench/results/history.yaml`.

**Why windowsmini bench is genuinely Phase 8.0 deferral**:
fib2 alone took 33 minutes on windowsmini for 4 runs (warmup
1 + runs 3). Full 26-fixture inventory at this rate = 5+
hours per push, which is incompatible with the inline-gate-
review cadence. The CI bench workflow added at this gate
(`.github/workflows/bench.yml`) does NOT include windowsmini
(no GitHub-hosted Win runner in scope for Phase 7 close).
Phase 8.0 candidate work: either define a Windows-specific
hot-fixture subset (~3-5 fast fixtures) for periodic local
verification, OR wire SSH-from-Linux-runner CI integration.

## Gate exit conditions

The `7.13` row in ROADMAP §9.7 flips to `[x]` **only when all
five sections above are ☑**. Until then:

- The autonomous `/continue` loop refuses to open §9.8.
- `ScheduleWakeup` is not armed when the next-task lookup
  resolves to "open §9.8" — instead, the loop surfaces to user
  with a one-sentence handoff: "Phase 8 entry gate
  (`.dev/phase8_transition_gate.md`) needs collaborative review;
  pausing autonomous mode."
- The user re-engages by working through the checklist sections,
  marking ☑ as items resolve, and finally asking for the gate
  to be cleared.

## Why no ADR for this gate?

This gate document + the `7.13` ROADMAP row + the SKILL.md
carve-out together define a **workflow regime**, not a §1/§2/§4/§5
design choice. ROADMAP §18.2 deviation watch lists the §-numbers
that require ADRs; "Phase boundary procedure" isn't among them.
A new row added inline in §9.7's task table is precisely the
"routine status update / expanding the phase table" path §18 lets
through without an ADR.

If a future cycle decides to **remove** this gate (= autonomous
Phase 8 opens), that decision **does** need an ADR — because it
reverses a load-bearing workflow rule. Removal is the gated
direction, not introduction.

## Future use

The same gate template should be reused at Phase 11 close (→
Phase 12+ horizon — release readiness, AOT shipping) and any
other place where a "deliberate skepticism pause" is desirable.
Replicate this file's structure under
`.dev/phase<N>_transition_gate.md` and add a corresponding
`<N>.gate` row to that phase's task list.
