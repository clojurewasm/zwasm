# No workaround / no silent fallback — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/no_workaround.md`](../rules/no_workaround.md).

# No workaround / no silent fallback

Two faces of the same root-cause discipline. Both forbid bypassing a
real problem with code that *looks* like it handles it.

## Three workaround principles (ROADMAP §P1 / §P3 / §P14)

1. **Fix root causes.** Missing feature → implement it. Spec gap →
   file a ROADMAP §9.<N+1> task. Don't paper over.
2. **Spec fidelity over expedience.** Don't simplify the API / IR to
   avoid a gap. Wasm spec is ground truth (P1).
3. **Defer, don't workaround.** Genuinely-not-ready feature → later
   phase + `// TODO(p<N>): <one line>` comment with the phase number.
   No indefinite workarounds.

## Forbidden silent-fallback patterns

Auto-detected by `scripts/check_fallback_patterns.sh --gate`:

- `catch |err| return null` / `catch |err| return undefined` (false info)
- `catch |err| .<default_value>` (silent semantic demotion)
- `catch |err| switch (err) { else => continue }` (ignore unknowns)
- `catch {}` (complete silence)
- New code emitting `SKIP-*` runtime tokens (bypasses ADR-0050 D-5 skip-impl ratchet)

**Allowed alternatives**: propagate via `!void` / `!T`, exhaustive
`switch (err)` with justified per-arm action, `switch (err) { else => |e| return e }` (re-throw unknowns).

## EXEMPT-FALLBACK marker

Rare unavoidable cases (e.g. `stderr.flush() catch {}` in diagnostic
path where propagation = infinite re-entry):

```zig
// EXEMPT-FALLBACK: <one-line reason citing ADR-NNNN or D-NNN>
stderr.flush() catch {};
```

Marker reason MUST cite concrete artifact; vague text ("legacy",
"best-effort") rejected by the gate script.

## Forbidden commit-message phrases

- `quick fix` — escalate to root cause OR file ADR for the limitation
- `temporarily skip` — spec skip=0 is release gate (A10)
- `disable for now` — disable forever or fix; no third option
- `workaround for <upstream>` without an ADR reference

## When a workaround is genuinely needed (gate bar)

Upstream broken? Bar:

1. ADR documents workaround (upstream issue link, expiry condition, removal plan)
2. Containment in one file (`src/platform/` for OS quirks, `src/util/` for stdlib gaps)
3. `// TODO(adr-NNNN): remove once <condition>` marker
4. `audit_scaffolding §G "lies" check` periodically re-verifies removal condition

## Sibling rules

- [`spike_discipline.md`](spike_discipline.md) — when experimentation
  belongs in `private/spikes/`. On-branch architectural spikes (helper
  先 land → wire-up 別 cycle, D-153 pattern) are forbidden under this
  rule too.
- [`extended_challenge.md`](extended_challenge.md) — the 3+2 step
  procedure when stuck. Step 1 (specifically identify what's missing)
  + Step 2 (self-provision when in scope) MUST run before declaring
  "absent" and reaching for a fallback.

## References

- ADR-0050 (skip-impl ratchet)
- ADR-0070 (libc dependency policy — `replaceable` category embodies P14)
- ADR-0071 §Q3/§Q5 (Phase 9 substrate audit resolution)
- `references/no_workaround_details.md` — v1 anti-patterns D116/W54/D117,
  spike boundary, full reviewer checklist
- `bench/results/skip_impl_history.yaml` — skip-impl one-way ratchet

