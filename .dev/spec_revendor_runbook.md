# Spec / wasm-tools re-vendor runbook

> **Doc-state**: ACTIVE

The sustainable procedure for following upstream Wasm spec + `wasm-tools`
drift and re-vendoring the conformance corpus. Triggered when
`scripts/check_spec_bump.sh` reports DRIFT (the nightly leg, §14.3) or before a
release tag. **CI is intentionally NOT wired yet** (user-gated 2026-06-14) —
this is a manual/cron-ready procedure.

## 0. Detect drift (the "nightly check")

```sh
bash scripts/check_spec_bump.sh          # report spec/testsuite drift vs pin
```
Drift = upstream `WebAssembly/{spec,testsuite}` advanced beyond
`.dev/spec_pin.yaml`. Also re-review `.dev/proposal_watch.md` quarterly.
(`wasm-tools` version drift — the byte-churn + JSON-dialect driver — is the
other axis; track the flake's pinned version against the corpus's last bake.)

## 1. Refresh the reference clones (read-only mirrors)

```sh
for r in spec testsuite; do
  git -C ~/Documents/OSS/WebAssembly/$r fetch origin && \
  git -C ~/Documents/OSS/WebAssembly/$r checkout -q origin/main
done
```
The 5 GC/EH/tail-call/function-references/memory64 proposal repos are FROZEN at
their post-Wasm-3.0-Recommendation HEADs (their tests merged into mainline
`spec`); they don't move. Never edit/commit from these mirror paths.

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
