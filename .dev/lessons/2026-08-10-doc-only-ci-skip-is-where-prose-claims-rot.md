# The doc-only CI skip makes prose the least-gated text in the repo

- **Date**: 2026-08-10
- **Area**: `.github/workflows/ci.yml` doc-only short-circuit; docs/benchmarks.md;
  ISSUE_TEMPLATE/bug_report.yml; ROADMAP §10.2
- **Trigger**: issue #163 (jtakakura) — `zwasm --help` (fixed in v2.4.1) and
  `docs/benchmarks.md` disagreed about which engine `zwasm run <m>` uses.

## Observation

The default engine flipped to `auto` (JIT-preferring, interp fallback) in D-496
ch6 on 2026-06-22, before `v2.0.0`. "interp is the default" nevertheless
survived in `--help` until v2.4.1 and in **five** more places until #163 —
including `.dev/ROADMAP.md` §10.2, the repo's own declared source of truth, and
the bug-report template's Execution-mode dropdown, which offered no way to say
"I did not pass `--engine`" and so *invited* every reporter to mislabel their
run.

Two adjacent claims in the same paragraphs were stale by the same mechanism:
§10.2 still said the JIT was compute-only and rejected `--dir` (D-244 closed
that), and the cljw handoff still listed JIT fuel / memory-cap / table-cap as a
gap (shipped on both engines; only D-314(a) remains).

## Why it survived

Not "nobody looked" — the loop *audits* docs. The structural reason is that a
doc-only PR takes the `changes` short-circuit and skips the entire 3-host
`gate`, so the class of text with the **weakest** mechanical net is exactly the
class of text a reader acts on. Every `check_*` script that could have caught it
was wired behind the docs-only skip in `gate_commit.sh` too. Meanwhile the
benchmark numbers were never wrong: `run_bench.sh --engines=` passes `--engine`
explicitly, so the harness was more honest than the prose describing it.

Sibling of [`2026-08-03-ungated-negative-doc-claim-rotted-into-a-lie.md`](2026-08-03-ungated-negative-doc-claim-rotted-into-a-lie.md):
there the claim was a negative nothing exercised; here it was a positive that
code contradicted line-for-line and no check compared them.

## Rule

- A check whose **subject is prose** must not sit behind a docs-only skip. Run
  it unconditionally — `doc-truth` in CI, before the short-circuit in
  `gate_commit.sh`.
- Anchor the gate on the code, not on a list of doc strings: assert the CLI
  usage text still says `default auto`, *then* sweep for contradicting prose. A
  legitimate future flip then fails loudly and forces the sweep instead of
  silently inverting it.
- A default that changes is a **doc-sweep obligation**, not a code change. Grep
  for the old default's phrasings in the same commit that flips it.
- An enum dropdown in an issue template is a claim too — omitting "default"
  from the options makes every reporter's answer wrong.

Landed: `scripts/check_engine_default_claims.sh` (anchor + sweep), wired into
`gate_commit.sh` (always) and a new always-on CI `doc-truth` job; 5 stale sites
corrected (PR for #163).
