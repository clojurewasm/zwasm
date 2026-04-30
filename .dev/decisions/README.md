# Architecture Decision Records

> ADRs document **deviations from `.dev/ROADMAP.md` discovered during
> development**, not founding decisions. Founding decisions live in
> the ROADMAP itself (§1–§14). When the ROADMAP is found to be wrong
> or incomplete, follow ROADMAP §18 (Amendment policy): edit the
> ROADMAP in place AND write an ADR explaining the deviation.
>
> Skip ADRs for ephemeral choices ("not worth it right now") or for
> facts that are obvious from the code.

## Filename convention

`NNNN_<snake_slug>.md`

- `NNNN` — 4-digit sequential index, zero-padded
- `<snake_slug>` — short English identifier in snake_case
- `0000_template.md` — template (do not delete or renumber)

## Required structure

Use [`0000_template.md`](./0000_template.md) as the starting point. Every
ADR has:

- **Status**: Proposed / Accepted / Superseded by NNNN / Deprecated
- **Context**: what motivated the decision (constraints, prior art)
- **Decision**: what was chosen
- **Alternatives considered**: what was rejected and why
- **Consequences**: positive, negative, neutral
- **References**: ROADMAP §, related ADRs, external docs

## Lifecycle

- **Add**: when a load-bearing decision is made that **diverges from
  the ROADMAP**. Number = max(existing) + 1.
- **Supersede**: do not edit a historical ADR. Add a new one and mark
  the old one `Status: Superseded by NNNN`.
- **Reject after debate**: also add an ADR with `Status: Proposed →
  Rejected`. Records why the path was not taken.

## When to write an ADR

- Layer/contract changes (new register class, new ZIR op family that
  was not in the day-1 catalogue)
- IR shape changes (ZirInstr layout, ZirFunc field add/remove)
- C ABI surface changes (`zwasm.h` additions; `wasm.h` follows
  upstream)
- Phase order changes
- Allowing a benchmark regression (with magnitude + reason)
- Tier promotions (a previously deferred Wasm proposal entering scope)
- Any one-time trade-off that conflicts with a §2 principle but is
  justified

## When NOT to write an ADR

- Bug fixes
- Spelling / typo corrections
- Doc additions
- Refactors with no public API change
- Anything already documented in ROADMAP §1–§14 (founding decisions)
