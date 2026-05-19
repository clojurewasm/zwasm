---
description: "Anti-fallback / anti-silent-degradation discipline for Phase 9 completeness substrate. Errors must propagate as named errors or be handled by exhaustive switch with ADR-justified rationale; silent skip / default-on-failure / try-simpler-path patterns are forbidden."
paths:
  - "src/**/*.zig"
  - "test/spec/spec_assert_runner_base.zig"
  - "test/spec/spec_assert_runner_non_simd.zig"
---

# Anti-fallback / anti-silent-degradation

> **Status**: landed at §9.12-A (2026-05-19). Auto-loaded on every
> `src/**/*.zig` edit + the two spec-assert-runner files. Enforced by
> `scripts/check_fallback_patterns.sh --gate` (pre-commit, wired in
> a follow-up §9.12-A chunk once the 10 existing `catch {}` sites
> are addressed / EXEMPT-FALLBACK marked).

## The rule

Forbid patterns in error handling that constitute **silent degradation**.
Specifically:

- `catch |err| return null` (returns false information to the caller)
- `catch |err| return undefined` (same)
- `catch |err| .<default_value>` (silently demotes the intended semantics)
- `catch |err| switch (err) { else => continue }` (= "ignore unknown errors")
- `catch {}` (= complete silence)
- Adding new code that emits `SKIP-*` tokens at runtime (= bypasses the
  skip-impl ratchet per ADR-0050 D-5)

Allowed alternatives:

- Propagate the error type as a named error union (`!void` / `!T`)
- Exhaustive switch (`switch (err) { error.X => ..., error.Y => ... }`)
  where every arm has a justified action
- Trap-class errors must be observable per the spec, so propagate via
  `Error.Trap` etc.
- "Re-throw unknown errors": `switch (err) { else => |e| return e }`

## Exemption marker

When a `catch {}` or `catch |err| return null` site is unavoidable (rare),
mark it explicitly with a comment on the **immediately preceding line**:

```zig
// EXEMPT-FALLBACK: <one-line reason citing an ADR or debt-row>
stderr.flush() catch {};
```

`scripts/check_fallback_patterns.sh` skips sites with this marker. The
reason must cite a concrete artifact (`ADR-NNNN` or `D-NNN`); vague text
("legacy", "best-effort") is insufficient.

Canonical legitimate-exemption cases (so far observed):

- Trailing `stderr.flush() catch {}` in diagnostic paths where the error
  itself originates from the diagnostic facility — propagating would
  cause infinite re-entry.
- `catch {}` in async-signal-safe signal handler bodies where stdlib I/O
  cannot be used (= the error is propagated through a different
  mechanism such as a sigaction-captured pointer).

## Why

Bugs in the D-026 / D-082 family (silent skip where the damage is found
only later) surfaced repeatedly on the way to Phase 9 completeness. The
primary exit criterion of Phase 9 completeness is "skip-impl == 0"
(§9.12-E), and a single silent fallback anywhere collapses that exit.

## Enforcement

- `scripts/check_fallback_patterns.sh` — `--gate` mode emits a FAIL
  exit code on any unexempted forbidden pattern. Lives behind
  pre-commit hook integration (wired once existing 10 sites are
  cleaned up; tracked in §9.12-A follow-up chunk).
- `audit_scaffolding §G.6` (extension in §9.12-A): periodic re-grep
  on the active branch.
- ADR-0050 D-5 (skip-impl one-way ratchet): any rise in skip-impl
  count requires an `exempt: ADR-NNNN` row in
  `bench/results/skip_impl_history.yaml`.

## Reviewer checklist

When reviewing a diff that adds error-handling code:

- [ ] Are there any `catch {}` / `catch |err| return null` / `catch
      |err| .<default>` sites? Each must have an immediately-preceding
      `// EXEMPT-FALLBACK: <ADR-NNNN | D-NNN reason>` comment, OR be
      replaced by `try` / `!T` propagation.
- [ ] If a new `Error.X` variant is added but only handled by one
      caller, did the other callers update? Run `grep -rE
      "error\.X\b" src/` to confirm.
- [ ] If a new `SKIP-X` token is added to a runner, is the
      `skip_impl_history.yaml` row + `exempt: ADR-NNNN` present?

## Stale-ness

- The grep patterns in `scripts/check_fallback_patterns.sh` may
  produce false positives if Zig 0.16+ adds new `catch` forms (e.g.
  `catch unreachable` which IS legitimate — unreachable propagates a
  trap). `audit_scaffolding §G.6` verifies the rule's anchor commands
  still apply.
- Pairs with **dedup sweep** scheduled in §9.12-C: this rule overlaps
  partially with `no_workaround.md` (which forbids SKIP-X-MISSING
  shortcuts paired with no investigation). The §9.12-C sweep
  consolidates / clarifies the boundary; until then both apply.

## Related

- ADR-0050 amend (D-5 / D-6 skip-impl one-way ratchet)
- ADR-0071 §Q3/§Q5 (Phase 9 substrate audit resolution)
- ADR-0073 (all-layer build-option DCE substrate)
- Master plan §7.4
- `.claude/rules/no_workaround.md` (sibling; SKIP-* prohibition;
  dedup boundary clarified in §9.12-C)
- `.claude/rules/extended_challenge.md` Step 4 (spike-driven
  alternative exploration before giving up)
