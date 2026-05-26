---
ADR: 0122
Title: Test-time skip categorization via helper module
Status: Accepted
Date: 2026-05-27
Related: ADR-0078 (runtime SKIP-* token taxonomy — orthogonal layer),
         test_discipline.md §4 (host-conditional gate rule), D-180
---

## Context

`error.SkipZigTest` is currently used at 63 sites across `src/` + `test/`
with no mechanical category distinction. The category lives at best
in a free-text comment near the call site. This has bitten us:

- **D-180 (2026-05-28)**: a Mac-only EH catch_all test gate hid a
  Linux x86_64 SysV miscompile for ~2 days. `test_discipline.md` §4
  was written in response but lacks mechanical enforcement.
- **Audit-time ambiguity**: `audit_scaffolding §G` can grep skip
  sites but cannot distinguish "phase-end-deferred" from "blocker-
  driven" from "spec-pinned" without parsing comments.
- **Loop-time noise**: the `/continue` per-cycle TDD loop cannot
  ask "which skips should I attempt to ungate this commit?" because
  the categories are textual, not enum.

The user surfaced this 2026-05-27: "スキップ部分を判定する術がいま
どれくらいあるんかな…テスト時のスキップマーカーの区別をした方が、
AIにとっても人間にとっても分かりやすい". Specifically: 2 mandatory
categories (iteration-skip vs blocker-driven), resisting ad-hoc
category growth, and removing the "永遠不問" abuse vector.

Orthogonal to ADR-0078 (which classifies runtime SKIP-* tokens
emitted by spec-corpus runners). This ADR covers compile-time
`error.SkipZigTest` from Zig `test "..."` blocks.

## Decision

### D1 — Two skip categories + comptime-guard for arch-pinned

The skip surface is reduced to exactly **two** runtime-visible
categories (helper-enforced) plus a **third path** (`comptime`
guard) that does not surface as a skip at all:

| Category | Helper call | Visible as skip? | AI-review at commit? |
|---|---|---|---|
| Phase-end batch deferral | `skip.phaseEnd(.win64)` | ✅ counted | ❌ skipped per ROADMAP |
| Blocker-driven (debt-paired) | `skip.blocker(.@"D-192")` | ✅ counted | ✅ "try ungate 3 min" |
| Arch-specific assertion | `comptime` early-return | ❌ no skip count | ❌ structurally inapplicable |

The `comptime` arch path replaces the previous "spec-pinned" runtime
skip category which the user flagged as a Bad Smell (abuse vector
where "spec-pinned" gets argued for impl-sabotage cases).

### D2 — Helper module shape

`src/test_support/skip.zig` (Zone 0; ADR-0023 §A1 layering):

```zig
//! Test-time skip helpers. ADR-0122-enforced; do not use
//! `error.SkipZigTest` directly outside this module + the
//! migration-grace sites enumerated below.

const std = @import("std");

pub const Win64Phase = enum { win64 };

pub const Blocker = enum {
    @"D-192",  // EH runtime path: exnref ValType + cross-module register
    @"D-186",  // typed-funcref Value shape (return_call_ref blocked)
    @"D-179",  // wabt 1.0.41+ for gc spec corpus baking
    // Add per migration as blockers surface. Each enum value MUST
    // appear as a row in `.dev/debt.md`; `scripts/check_skip_helpers.sh
    // --gate` enforces the pairing.
};

/// Phase-end batch deferral. Test is intentionally not reviewed
/// per-commit; the iteration cost of running it inline would
/// dominate. Audit at phase boundary discharges the batch.
pub fn phaseEnd(comptime _: Win64Phase) anyerror {
    return error.SkipZigTest;
}

/// Blocker-driven skip. Test would compile + run but cannot
/// pass until the named debt is discharged. `/continue` Step 4
/// loop checks each such site every commit and attempts a
/// 3-minute ungate when the blocker dissolves.
pub fn blocker(comptime _: Blocker) anyerror {
    return error.SkipZigTest;
}
```

The `comptime` parameter ensures the category is fixed at compile
time and surfaces to grep / IDE.

### D3 — Arch-pinned tests use `comptime` early-return, not skip

```zig
test "encStp X29,X30 emits 0x29,0x00,0x00,0xA9 byte-shape" {
    if (comptime builtin.cpu.arch != .aarch64) return;
    // ... aarch64-specific assertions
}
```

The test compiles + runs on all archs but does nothing on non-target
arch. Test counter shows it as **passing**, not as **skipped** — which
is structurally honest: the test has no meaningful work to do.

**Discipline**: every `comptime ... != X) return` test MUST have a
sibling test (in the cross-arch source file) covering the equivalent
assertion for the other arch. Comment:

```zig
// SIBLING-AT: src/engine/codegen/x86_64/wrapper_thunk_test.zig:142
if (comptime builtin.cpu.arch != .aarch64) return;
```

The `SIBLING-AT:` marker is grep-enforced by D5's audit script.

### D4 — `test_discipline.md` §4 amended

§4's `Mac-only path is fully wired; verify there first` forbidden
phrase list extends to:

- Raw `if (builtin.os.tag == ...) return error.SkipZigTest;` outside
  `src/test_support/skip.zig` after the migration cycle lands.
- `if (comptime ... != X) return;` without a paired `SIBLING-AT:`
  comment.

### D5 — Mechanical gate: `scripts/check_skip_helpers.sh --gate`

New script invoked from `scripts/gate_commit.sh` (alongside the
existing `check_skip_taxonomy_pairing` for the runtime token layer).
Behaviors:

1. **Raw-skip gate**: error if `error.SkipZigTest` appears in any
   `src/` or `test/` file other than `src/test_support/skip.zig`
   (after the migration grace period; tracked via in-script
   GRACE_BASELINE counter, currently the migration cycle's
   remaining-untouched count).
2. **Blocker enum vs debt.md**: for each `skip.blocker(.@"D-NNN")`
   call site, verify `D-NNN` row exists in `.dev/debt.md`. Missing
   → block.
3. **SIBLING-AT marker**: for each `if (comptime ... != X) return;`
   under `src/engine/codegen/`, verify the comment's `SIBLING-AT:`
   path exists. Missing/dead link → block.
4. **Win64 phase-end count widget**: count `skip.phaseEnd(.win64)`
   sites; emit info-level "Win64 phase-end batch = N tests" so phase
   close knows the discharge surface.

### D6 — `/continue` Step 4 inline checklist amendment

Existing Step 4 boundary-fixture check gains a sibling check:

> **Skip-judgment check** — diff added a new skip site?
> - `skip.phaseEnd(.win64)` → OK, land.
> - `skip.blocker(.@"D-NNN")` → confirm D-NNN debt row exists
>   (or file it same commit).
> - Bare `error.SkipZigTest` in non-test_support code → REJECT;
>   pick one of the two helpers.
> - `if (comptime ... != X) return;` → SIBLING-AT comment required.
>
> **Existing-skip review (budget 3 minutes)** — pick 1-2 sibling
> `skip.blocker(...)` sites in the same file; attempt ungate (delete
> the skip line + run the test).
> - green → keep ungated, include in commit, mention blocker discharge.
> - red within 30s → revert, leave skip.
> - takes > 3 min → revert, file the attempt outcome to debt row's
>   Hypothesis section (per investigation_discipline.md §1).

### D7 — Migration plan (this ADR's same-cycle execution)

This ADR's acceptance triggers the migration in the same continuous
work block (user-authorized 2026-05-27 night session):

1. Create `src/test_support/skip.zig` per D2.
2. Migrate all 17 Win64 sites → `skip.phaseEnd(.win64)`. Pure
   mechanical; no judgment.
3. Migrate ~21 Mac aarch64-only sites case-by-case:
   - Pure byte-shape / encoding assertion → `comptime` guard + SIBLING-AT.
   - Impl-pending integration test (entry.zig style) → attempt
     ungate; if red after 30s probe, mark `skip.blocker(.@"D-NNN")`
     and file the debt row.
4. Migrate ~12 build-flag sites: stay as-is (build-flag guards are
   exempt per test_discipline.md §4 "When §4 does NOT fire").
5. Land `scripts/check_skip_helpers.sh` + hook into `gate_commit.sh`.
6. Self-review pass: re-grep `error.SkipZigTest` and verify each
   remaining site is either in skip.zig, a build-flag guard, or has
   a paired GRACE marker.

Migration grace: any site not yet migrated must carry a top-of-line
comment `// SKIP-MIGRATION-PENDING: <one-line reason>`. The gate
script counts these and refuses to let the count increase beyond
the post-migration baseline.

## Alternatives

(A) **Comment markers (`// SKIP-WIN-PHASE-END` etc.) without helper
function** — easier migration, but no compile-time category
enforcement. A `// SKIP-WIN-PHASE-END` comment can be added in front
of any skip without picking a real category. Rejected per the user's
"ad-hocに増やさないようにしたい" intent.

(B) **Keep `specPinnedArch` as a third runtime skip category** — the
"永遠不問" abuse vector dominates. Rejected by the user explicitly
2026-05-27.

(C) **3 categories with explicit phase-boundary discharge for all
3** (phaseEnd / blocker / archOnly-with-SIBLING-AT) — rejected
because the third category doesn't actually need to be a runtime
skip; `comptime` early-return achieves the same arch-pinning
without the count noise.

(D) **Migrate Win-only first, defer Mac aarch64 case-by-case
migration to a later cycle** — rejected because the Mac aarch64
sites are exactly where D-180-class regressions hide. The user's
explicit goal is to surface those at commit time.

## Consequences

+ Skip counter becomes interpretable: every counted skip is an
  action item, gated by either Phase-end discharge (Win) or
  blocker debt review (everything else).
+ D-180 class of "Mac-only gate hides cross-host miscompile" is
  structurally blocked: Mac-only impl gaps must declare a `blocker`
  debt, and the `/continue` Step 4 amendment requires a 3-min
  ungate probe at every commit touching neighbouring code.
+ Helper enum forces category at compile time; ad-hoc category
  drift impossible (adding a new category requires editing
  `src/test_support/skip.zig`, which is an ADR-grade choice).
+ Audit no longer needs to parse comments; grep on the helper
  call site is authoritative.
- Migration touches ~60 files in one cycle; review burden is
  high. Mitigated by the `SKIP-MIGRATION-PENDING` grace marker
  + per-site case judgment notes.
- `Blocker` enum must be kept in sync with `.dev/debt.md`. The
  gate script enforces this; orphan entries fail the gate.
- Adding a new blocker debt requires adding an enum variant +
  the debt row in the same commit. Slightly heavier than the
  prior comment-only flow.

## References

- ADR-0078 — runtime SKIP-* token taxonomy (orthogonal; covers
  spec-corpus runner emissions, not test-time gates).
- `.claude/rules/test_discipline.md` §4 — host-conditional gate rule.
- `.dev/lessons/2026-05-28-x86_64-uses-runtime-ptr-eh-gap.md` — D-180
  case study that motivated §4 and now this ADR.
- `.claude/skills/audit_scaffolding/CHECKS.md` §G — extend with
  raw-skip grep (this ADR adds §G.N for it).
- `.claude/rules/lessons_vs_adr.md` — this artifact is load-bearing
  (changes test-authoring rule) so ADR, not lesson.

## Revision history

- 2026-05-27 — Initial draft; user-authorized migration as same-
  session work block (10.G op_gc cycle 18 boundary).
