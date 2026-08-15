# ADR-0210 — Spec runners account for their own denominator

- **Status**: Accepted
- **Date**: 2026-08-15
- **Author**: zwasm v2
- **Tags**: spec-assert, conformance, test-infrastructure, verifiability

## Context

Every conformance number zwasm publishes — "Wasm 3.0 100% spec, 0 skip",
the per-proposal tallies, the JIT lane's pass/fail/skip — comes out of the
spec assertion runners. Those numbers were not checkable, because no
runner printed what it had enumerated.

Measured on `main` @ `8f24e0aee`, interp lane, `test-spec-wasm-3.0-assert`:

- The per-proposal line printed `return=N (pass=P fail=F)` where **N ≠ P+F**
  for four of six proposals; **73 `assert_return` directives** reached
  neither pass, fail nor skip. Four `continue` paths in the arm incremented
  no counter at all.
- The grand total printed `15175 directives` next to pass/fail pairs
  summing to `14577`. The 598 difference had no explanation on the line
  (489 `module` + 36 `skip` + the 73 above).
- `assert_uninstantiable` (20 lines) incremented `asserts_trap`, so the
  printed `trap=2573` could not be reconciled with the corpus's 2553
  `assert_trap` lines.
- `skip-adr-*` (95 lines) had no `Kind`, parsed as `.unknown`, and hit a
  `=> {}` arm: absent from every tally *and* from the denominator.
- `register` (30) and `invoke` (209) were executed but uncounted, while a
  successful `register` also incremented the shared `skips` bucket.
- `parseLine(...) catch continue` dropped 3 corpus lines before the kind
  switch, so `asserts_return` (11289) undercounted the corpus (11292).
- `15175` was itself inflated: a ref-uncomparable `assert_return`
  incremented both `asserts_return` and `skips`.

Six other lanes (`test-spec`, `test-spec-assert`, `test-spec-simd`,
`test-spec-wasm-2.0-assert`, `test-spec-threads-assert`,
`test-spec-wasm-2.0`) printed pass/fail/skip with **no denominator at
all**, so the same class of gap was undetectable there by construction.

Separately, `zig build test-spec` printed 8 `PASS` lines across three
consecutive runs while its two summaries claimed 3 + 9 = 12, one line
spliced mid-token; the exes run standalone printed 3 and 9 intact.

## Decision

**A spec runner must account for its own denominator, check the identity
itself, and exit non-zero when it does not hold.**

For the wasm-3.0 runner, in full:

1. `lines` — every non-blank manifest line — is the denominator, and
   `lines == module + register + invoke + skip + unknown + unparsed +
   Σ(assertion category totals)`.
2. Each assertion category closes: `total == pass + fail + skip`.
3. The denominator is **re-derivable without running the binary**:
   `cat test/spec/wasm-3.0-assert/*/*/manifest.txt | wc -l`.
   `scripts/check_spec_manifest_shape.sh --gate` pins the property that
   makes that true (one directive per line; no blanks, comments, or
   indentation), and is wired into `ci_gate.sh`'s core leg (every PR, all
   three OSes) plus `gate_commit.sh`. A guard nothing invokes pins
   nothing.
4. Both identities are printed (`RECONCILE` / `ACCOUNTING: CLOSED|OPEN`)
   and gated. A conformance number computed from a tally that cannot
   account for its own denominator is worse than no number: it reads as
   authoritative and is not.
5. `unparsed` and `unknown` are counted and named on stdout but are **not**
   themselves gated — a harness gap must be visible without being
   reported as a spec failure.
6. A fail must be **locatable in a default run**. The per-manifest locator
   keys off `jit_return.fail` as well as `ret.fail` / `trap.fail`: in jit
   mode the verdict lands in `jit_return`, so a JIT return-fail used to
   appear in the totals with nothing naming the manifest unless
   `--fail-detail` was passed. That was the symptom that started this
   work, and closing the accounting did not by itself close it.
7. The lanes that print a bare `residual` also print `overcounted`.
   `residual` saturates at zero, so a corpus whose columns claim more
   lines than were read — a line tallied twice, the exact defect the
   wasm-3.0 shared `skips` bucket had — would read as perfectly
   accounted.

The five counting defects above are fixed rather than papered over: split
`uninstantiable` from `trap`, give `skip-adr-*` a `Kind`, give every
category its own `skip` column instead of a shared bucket, count
`register`/`invoke` into the denominator, and count parse failures.

### Rejected: print the denominator without fixing the model

Cheaper, and worse. A denominator computed from a tally that merges two
directive kinds, drops a third, and double-counts a fourth is a number
that looks checkable and isn't. It would have made the next reader more
confident, not more correct.

### Rejected: gate `unparsed > 0`

That conflates "the harness cannot read this line" with "the
implementation fails this assertion". The first must be loud; only the
second may claim a spec failure.

## Consequences

Numbers that move (interp lane, same corpus, no implementation change):

| | before | after | why |
|---|---:|---:|---|
| denominator | `15175 directives` | `lines=15478` | double-count removed; `skip-adr`/`register`/`invoke` counted |
| `assert_return` total | 11289 | 11292 | 3 lines recovered from `catch continue` |
| `assert_return` pass | 11216 | **11218** | 2 recovered lines execute and pass |
| `assert_return` skip | — | 74 | the 73 unattributed + 1 recovered multi-value |
| `assert_trap` | 2573 | 2553 | `uninstantiable` split out |
| `assert_uninstantiable` | — | 20 | new column |
| `skip` | 36 | 97 | 95 `skip-adr` counted; `register` no longer double-counted |

Every one of these now equals an independent `grep -c` of the corpus.

JIT lane (measured 2026-08-15 with PR #186 merged locally, since the lane
SEGVs without it): `return=11292 (pass=10853 fail=1 skip=438)`, `CLOSED`.
`skip` moved 435 → 438 — exactly the 3 recovered lines. The JIT lane stays
report-only (ADR-0128); `ret.fail` is not gated in jit mode, so making the
accounting close did not silently promote the opt-in lane into a gate.

No number changed by this ADR is cited anywhere in the repository
(verified by grep over `*.md`, `*.yaml`, `*.sh`, `*.zig`, and PR #186's
body). Artifacts outside this repository were not checked; the table above
is the diff to reconcile them against.

The other six lanes get the denominator (`lines` / `accounted` /
`residual`), not the full identity — enough to detect the same class of
gap. Every residual reconciles against an independent `grep -c` of its
corpus, so none of them is currently hiding a dropped directive:

| lane | lines | accounted | residual | reconciles to |
|---|---:|---:|---:|---|
| `test-spec` | 3 + 9 files | 3 + 9 | 0 | gated: `passed + failed == enumerated` |
| `test-spec-assert` | 243 | 232 | 11 | 11 `module` |
| `test-spec-simd` | 26067 | 25587 | 480 | 482 `module` − 2 that raised a runtime skip |
| `test-spec-wasm-2.0-assert` | 27210 | 26074 | 1136 | 1115 `module` + 21 `register` |
| `test-spec-threads-assert` | 297 | 294 | 3 | 3 `module` |
| `test-spec-wasm-2.0` | 1158 | 1158 | 0 | fully accounted |

Turning those residuals into a gated identity — naming the non-assertion
directives per category the way the wasm-3.0 runner does, so the runner
rather than a human does the reconciliation — is follow-on work,
deliberately not bundled: a comparable-sized change across a 4196-line
shared base runner that three currently-green lanes sit on. It warrants a
debt row.

`zig build test-spec` runs the two corpora through `.inherit` stdio and in
sequence, so the printed detail is the child's own output rather than a
re-forwarded copy, and the two runs cannot interleave.

Scope of that claim, stated precisely: the forwarding layer was observed
corrupting output twice — the spliced ` sections)` line in the original
3-run measurement, and a piped `--summary all` run that dropped every
`PASS` line and truncated the summary's leading token. With `.inherit` and
the ordering, a run in which both steps execute prints 12 `PASS` lines and
both summaries in order with no splicing. It was **not** possible to
re-demonstrate the original plain-form failure afterwards: subsequent
invocations reuse the cached smoke run, and neither `touch build.zig` nor a
fresh `--cache-dir` reproduced the both-steps-run plain condition — the
unmodified baseline behaves identically under those conditions. So the
change is justified by the observed corruption, not by a before/after on
the original symptom.

That is also why the durable protection is not the printing: `runner.zig`
now checks `passed + failed == enumerated` and exits non-zero otherwise, so
a lost line cannot hide a lost verdict regardless of what the build layer
does to stdout.

## Note on scoping

ADR-0208 (#183) deliberately separated its decision from its
implementation. This one bundles them, on a different criterion: that
decision could be evaluated in the abstract, whereas this one is the
empirical claim *"fixing these five defects makes the identity close."*
Writing that down unimplemented would itself be an unverified claim. The
criterion is whether the decision can be judged without the code, not
whether it is an ADR.
