# Spec / wasm-tools re-vendor runbook

> **Doc-state**: ACTIVE

The sustainable procedure for following upstream Wasm spec + `wasm-tools`
drift and re-vendoring the conformance corpus. Triggered when
`scripts/check_spec_bump.sh` reports DRIFT (on-demand since ADR-0211 D1) or
before a release tag. **CI is intentionally NOT wired** (user-gated
2026-06-14; the nightly.yml automation was retired 2026-08-19, D-593) —
this is a manual procedure.

## 0. Detect drift

```sh
bash scripts/check_spec_bump.sh          # report spec/testsuite drift vs pin
```
Drift = upstream `WebAssembly/{spec,testsuite}` advanced beyond
`.dev/spec_pin.yaml`. Also re-review `.dev/proposal_watch.md` quarterly.
(`wasm-tools` version drift — the byte-churn + JSON-dialect driver — is the
other axis; track the flake's pinned version against the corpus's last bake.)

## 1. Check out the CORRECT spec ref per corpus (NOT `main`)

**CRITICAL**: the version corpora bake from their W3C Recommendation TAGS, not
the evolving `spec` `main`. Baking from `main` pulls post-3.0 content into the
2.0 corpus → false failures (`elem`/`data`/`ref_null` reject 3.0 init-exprs /
heap types). Map:
- **wasm-1.0 / wasm-2.0 corpora** ← `git -C <spec> checkout wg-2.0` (the 2.0
  Recommendation; frozen). These specs are DONE — the corpora are already current.
- **wasm-3.0 corpus** ← the frozen proposal repos `~/Documents/OSS/WebAssembly/
  {gc,exception-handling,tail-call,function-references,memory64}` (at their
  post-Rec HEADs) via `import_proposal_corpus.sh`, OR the spec `wg-3.0` tag.
- **simd / threads** ← `testsuite` (`checkout origin/main` — these track the suite).

```sh
git -C ~/Documents/OSS/WebAssembly/spec fetch --tags
git -C ~/Documents/OSS/WebAssembly/spec checkout wg-2.0   # for 1.0/2.0 bakes
git -C ~/Documents/OSS/WebAssembly/testsuite checkout origin/main
```
Never edit/commit from these read-only mirror paths.

## 2. Refresh the Wasm-3.0 static `raw/` corpus (only if proposal sources moved)

`test/spec/wasm-3.0-assert/<proposal>/raw/` is a COMMITTED snapshot — regen does
NOT pull upstream changes for it. To refresh:
```sh
bash scripts/import_proposal_corpus.sh --copy-all
```

## 3. Re-bake the corpus (needs the gen shell)

```sh
nix develop .#gen -c bash -c '
  for s in regen_spec_1_0_assert regen_spec_2_0_assert regen_spec_simd_assert \
           regen_spec_threads_assert regen_spec_3_0_assert \
           regen_test_data regen_test_data_2_0 regen_wasmtime_misc; do
    bash scripts/$s.sh || echo "FAIL $s"
  done'
```
All distillers consume the shared value-dialect lib
**`scripts/spec_distill/refdialect.py`** (`fmt_value` / `kind_alias` /
`is_ref_type`). **If a regen dies on a value shape** (`KeyError`/`ValueError`),
the fix goes in `refdialect.py` ONCE (add the new wasm-tools JSON shape + a
self-test case), not per-distiller. Re-run; the gate runs the self-test on
commit. New spec test FILES (renames/relocations, e.g. the 3.0 reorg moved
`memory_copy`/`table_fill`/… out of `spec/test/core`) require updating the
per-distiller curated `NAMES` lists to the new layout.

## 4. Review the corpus diff

```sh
git status --short test/spec test/wasmtime_misc | grep manifest.txt   # SEMANTIC deltas
git status --short test/spec test/wasmtime_misc | wc -l                # incl. byte-churn
```
Manifest changes = real assertion deltas (validate these). `.wasm`-only churn =
benign re-encoding by a newer `wasm-tools` (semantically equivalent). Keep the
corpus **0-skip**: no new `skip-impl` lines (see `grep -rh skip-impl test/spec`).

**VALIDATE-then-REVERT discipline** (the established D-290 practice): the
committed corpus is a SNAPSHOT. Re-baking with a newer `wasm-tools` churns the
`.wasm` bytes (semantically null) — do NOT commit that churn. Re-bake to PROVE
the suite still passes against the current sources/tooling, then `git checkout
-- test/` the data back. Commit data ONLY when a genuine SEMANTIC delta (a real
new/changed assertion) is incorporated. Cosmetic JSON shifts (e.g. newer
wasm-tools dropping the `$` sigil from module names in skipped cross-module
lines) are not semantic — leave them reverted.

## 5. Verify + gate

```sh
zig build test-all          # Mac; investigate any FAIL as a REAL conformance
                            # gap (fix the runtime, not the corpus)
```
Then 3-host per `GATE.md` (ubuntu always; windows `--resume` for a tag).

## 6. Bump the pin + (optionally) tag

Update `.dev/spec_pin.yaml` (spec/testsuite SHAs + date; + wasm-tools version)
and `.dev/proposal_watch.md` review-log. Commit the re-vendor. **Tagging is
user-only (ADR-0156)**; the loop never tags. Pre-release tags are tag-only, no
GitHub Release (memory `project_zwasm_v2_prerelease_tagging`).

## Why this is sustainable

The brittleness was 8 duplicated embedded-python bakers each re-deriving the
value dialect. Centralizing it in `refdialect.py` (gate-self-tested) makes a
future `wasm-tools` JSON change a one-file fix; this runbook + `check_spec_bump`
make the cadence repeatable without CI.
