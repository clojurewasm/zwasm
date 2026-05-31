---
description: "Fix root causes; never work around. Forbid silent fallbacks (catch {} / catch |err| return null / catch |err| .default) AND indefinite workarounds (quick fix / temporarily skip / disable for now). Absorbs former no_fallback_on_failure.md per ADR-0118 D3."
paths:
  - "src/**/*.zig"
  - "build.zig"
  - "test/spec/spec_assert_runner_base.zig"
  - "test/spec/spec_assert_runner_non_simd.zig"
---

# No workaround / no silent fallback

> Lean stub (ADR-0118 D2). Full principles / v1 anti-patterns / reviewer checklist: [`../references/no_workaround.md`](../references/no_workaround.md) (→ `no_workaround_details.md`).

## Invariant (PRESERVE — ROADMAP P1 / P3 / P14)

1. **Fix root causes.** Missing feature → implement. Spec gap → file a ROADMAP task. Don't paper over.
2. **Spec fidelity over expedience** — don't simplify the API/IR to dodge a gap.
3. **Defer, don't workaround** — genuinely-not-ready → later phase + `// TODO(p<N>): <line>`. No indefinite workarounds.

### Forbidden silent-fallback patterns (grep-enforced, VERBATIM)

- `catch |err| return null` / `catch |err| return undefined`
- `catch |err| .<default_value>` (silent semantic demotion)
- `catch |err| switch (err) { else => continue }`
- `catch {}` (complete silence)
- New code emitting `SKIP-*` runtime tokens (ADR-0050 ratchet)

Allowed: `!void`/`!T` propagate; exhaustive `switch (err)` with justified arms;
`switch (err) { else => |e| return e }`. Rare unavoidable → `// EXEMPT-FALLBACK:
<reason citing ADR-NNNN or D-NNN>` (vague reason rejected).

### Forbidden commit phrases

`quick fix` · `temporarily skip` · `disable for now` · `workaround for <upstream>` (without ADR ref).

## Enforcement

`bash scripts/check_fallback_patterns.sh --gate` (FAIL on silent patterns) + commit-message grep.

Full Why + when-a-workaround-is-genuinely-needed bar + v1 D116/W54/D117 anti-patterns: [`../references/no_workaround.md`](../references/no_workaround.md).
