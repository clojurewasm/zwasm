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
8. **A stricter corpus contract, accepted deliberately.** Because a
   manifest that fails to read now gates, a sub-corpus directory with no
   `manifest.txt` at all turns the build red rather than being skipped.
   Only the six `raw/` dirs qualify today and those are explicitly
   skipped, so the tree is clean — but `scripts/regen_spec_3_0_assert.sh`
   `mkdir -p`s the output directory before writing the manifest, so an
   aborted regen leaves an empty sub-corpus that now fails the gate. That
   is the intended direction: a half-regenerated corpus should be loud,
   not silently smaller. Re-run or remove the stray directory.
9. **What the identity cannot see, gates separately.** The identity is
   invariant under "drop a whole manifest": a sub-corpus that fails to
   open contributes zero to both sides, so `lines` and the buckets shrink
   together and the run still prints CLOSED. Verified by injecting a
   `chmod 000` manifest — `ACCOUNTING: CLOSED` with 47 fewer lines. That
   is the ADR-0174 windows path-resolution class, and it is why manifest
   read / sub-dir open / engine init are counted as `manifest_errors` and
   gated on their own rather than trusted to the identity. For the same
   reason the runner cross-checks that every directory under the corpus
   root appears in `PROPOSALS`: the identity certifies that everything
   *enumerated* is accounted for, not that the enumeration covers the
   corpus.

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

**The accounting is correct and the remaining `fail=1` is real.** It is not
an artifact of how directives were counted — the identity closes with it
present. It is a genuine defect in the multi-value entry path
(`invokeMulti`, `src/engine/runner.zig`): the same module and export return
`1 1` correctly through the CLI on both engines, so the codegen for this
shape is right and only the persistent-instance route traps. Whether the
defect is in `invokeMulti` itself or in the runner's use of it was not
isolated, and is not claimed either way.

Its disposition is **out of scope for this ADR and unsettled** — recorded
as **D-590**, decided at #12 when the JIT lane's CI gating is designed.
Leaving it unfixed and gating the lane with one accepted fail is one
candidate; it conflicts with ADR-0153 (a measured violation of a 完成形
dimension "schedules a rework"), and 100% spec is one of those dimensions.
Nothing here depends on how that resolves: this ADR's subject is whether
the numbers can be checked, and they can be with the fail present.

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

**The lost `test-spec` output was the runners' own writer, not the build
layer.** `std.Io.File.stdout().writer(io, buf)` defaults to `.positional`
mode with `pos = 0`, so every process restarts writing at offset 0 of a
seekable stdout. Two runners redirected to the same file therefore
overwrite each other — which is the spliced ` sections)` line in the
original measurement. Isolated by running the two exes directly, with no
`zig build` involved: `( exe smoke; exe wasm-1.0 ) > log` gave 9 `PASS`
lines and 1 summary instead of 12 and 2, sequentially, deterministically.

Every runner under `test/` now uses `writerStreaming` — all 22, since the
defect is in the idiom rather than in the spec lanes; `src/` already used
`writerStreaming` throughout, so this is the harness catching up with the
product. After the change the same command prints 12 and 2 with no
corrupted lines, and so does `zig build test-spec` under both a file
redirect and a pipe.

Two earlier hypotheses were wrong and are recorded because they were
plausible and cost time: that the build runner's output *forwarding* was
lossy (it is not — the loss reproduces with no build runner), and that the
two runs *interleaving* was the cause (they still lost lines when
sequential). Ordering the two run steps is kept as cheap insurance against
genuine concurrent interleaving; `stdio = .inherit` was tried and reverted,
because it does not address the cause and it silently disables run-step
caching (both spec runs then re-execute on every `test-all`).

The durable protection is still not the printing: `runner.zig` checks
`passed + failed == enumerated` and exits non-zero otherwise, so a lost
line cannot hide a lost verdict whatever happens to stdout.

## Note on scoping

ADR-0208 (#183) deliberately separated its decision from its
implementation. This one bundles them, on a different criterion: that
decision could be evaluated in the abstract, whereas this one is the
empirical claim *"fixing these five defects makes the identity close."*
Writing that down unimplemented would itself be an unverified claim. The
criterion is whether the decision can be judged without the code, not
whether it is an ADR.
