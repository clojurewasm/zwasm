# Gate consolidation study (§9.12-A / A6)

> Measurement + analysis of the 15 enforcement scripts + 2 build-step
> gates that fire across `gate_commit.sh` / `gate_merge.sh` / manual
> Step 4 / `audit_scaffolding`. Output of master plan §9.12-A "Measure
> execution time of the existing 8 gates + study consolidation room".
>
> **Host**: Mac aarch64 (Apple M-series), 2026-05-19. Cold zig-cache
> baseline for `zig build`; warm for repeated runs.

## §1 Per-gate measurements

| Gate                              | Wall (ms) | stdout | stderr | Notes |
|-----------------------------------|----------:|-------:|-------:|-------|
| `zig fmt --check src/`            |       123 |      0 |      0 | Fast; zero noise on clean tree. |
| `zone_check --gate`               |    15 607 |      0 |      0 | **Slowest non-build gate.** Scans every src/*.zig import. |
| `file_size_check --gate`          |     2 585 |      1 |     23 | Stderr lines = WARN entries (22 files > 1000 LOC). |
| `spill_aware_check`               |       494 |      0 |      7 | Fast. |
| `check_skip_adrs --gate`          |    11 133 |     94 |      0 | Walks every skip_*.md ADR + manifest line. |
| `check_adr_history --gate`        |     4 256 |    219 |      0 | High-volume stdout (per-ADR backfill status). |
| `check_lesson_citing`             |       155 |      5 |      0 | Cheap. |
| `check_invariant_comments`        |       108 |     64 |      0 | Cheap; stdout lines = candidate match list. |
| `check_md_tables`                 | (pending) |        |        | Pre-tool-use PreToolUse hook gate. |
| `check_libc_boundary`             | (pending) |        |        | A1 new; classifies std.c.* sites per ADR-0070. |
| `check_fallback_patterns`         | (pending) |        |        | A1 new; greps src/ for catch{} / catch return null. |
| `check_skip_impl_ratchet --report`| (pending) |        |        | A1 new; reads bench/results/skip_impl_history.yaml. |
| `check_subrow_exit --check 9.12-F`| (pending) |        |        | A1 new; per-sub-row exit-criterion check. |
| `p9_completion_status`            | (pending) |        |        | A1 new; live Phase 9 completion progress reader. |
| `zig build lint -- --max-warnings 0` | (pending; ~120 s cold, ~5-10 s warm) | | | ADR-0009 Mac-only; runs zlinter on src/. |

(Pending rows are filled when the in-flight measurement run completes;
this report is amended in a follow-up commit.)

## §2 Top time-consumers in `gate_commit.sh`

The pre-commit gate runs (in order): zig fmt → zone_check →
file_size_check → check_skip_adrs → check_lesson_citing (warn-only) →
zig build test (conditional; skipped on docs-only).

Cumulative time on docs-only commits:

```
123 (fmt) + 15 607 (zone) + 2 585 (size) + 11 133 (skip_adrs)
+ 155 (citing) ≈ 29.6 s
```

Three slowest contributors: `zone_check` (15.6 s, 53 % of pre-commit
gate), `check_skip_adrs` (11.1 s, 38 %), `file_size_check` (2.6 s, 9 %).
Combined = ~96 % of pre-commit time.

`zig build test` (when fired) adds another ~30-60 s; that's the
dominating cost on source diffs, but it's structurally necessary.

## §3 Consolidation room

### §3.1 zone_check — slowest non-build gate

15.6 s is high for a docs-config diff. Profile: the script greps every
`@import("…/foo.zig")` in `src/` and resolves the zone direction
against ROADMAP §4.1. On 2 393-line ROADMAP + ~200 src files this is
~5 000 grep operations.

**Consolidation candidates**:

- Replace per-file `grep` loops with a single `grep -rnE` of the
  unified pattern + post-process in awk (~5-10× speedup typical).
- Cache the file→zone map (a small JSON or yaml regenerated when
  ROADMAP §4.1 changes); zone_check looks up rather than re-derives.
- For docs-only diffs, skip the zone check entirely (no src/ change
  → no zone violation possible).

The third option is the cheapest win — gate_commit.sh already detects
docs-only diff for the test step; the same condition can short-circuit
zone_check.

### §3.2 check_skip_adrs — slow due to manifest walks

11.1 s is high. Profile: the script walks `.dev/decisions/skip_*.md`
+ every `manifest.txt` + every `wat` artefact. The path-existence and
prefix-vocabulary cross-check is fundamentally many small file reads.

**Consolidation candidates**:

- Single-pass walk of all manifests with one `find` + `xargs grep`.
- Cache the skip-ADR ↔ fixture cross-reference; re-derive only when
  `skip_*.md` or `manifest.txt` files change since last invocation.

### §3.3 file_size_check — moderate; WARN noise dominates

2.6 s + 23 stderr lines (file-size WARN entries). Each gate-commit run
prints the same 22 WARN lines. **Noise reduction**: only print WARN
lines that **changed** since the previous gate-commit run (caching
via `.zig-cache/file_size_baseline.txt`).

### §3.4 check_adr_history — 219 lines of stdout (high noise)

219 lines for a routine pre-commit is excessive. The information is
valuable at Phase boundary / `--gate` mode but should be silent on
docs-only commits when no ADR file changed.

**Fix**: when no `.dev/decisions/*.md` was modified in the staged diff,
skip the ADR-history walk and emit a single `(unchanged)` line.

### §3.5 New A1 scripts (libc / fallback / ratchet / subrow_exit / build_dce)

These were authored at §9.12-A / A1 and are **not yet wired into
gate_commit.sh / pre-push**. The wiring chunk (A7) decides which fire
pre-commit (cheap, mechanical) vs pre-push (expensive, like
check_build_dce which builds 6 binaries).

Recommended pre-commit additions (cheap):

- `check_libc_boundary` — fast grep, ~100 ms expected.
- `check_fallback_patterns` — fast grep, ~150 ms expected.

Recommended pre-push (expensive but rare):

- `check_skip_impl_ratchet --gate` — only when bench/results/yaml or
  src/runner files changed.
- `check_subrow_exit --gate` — only when ROADMAP §9.12-X [x] flip
  detected in HEAD diff.
- `check_build_dce --sample 2` — only on §9.12-B chunks (substantial
  build cost; ~3-5 min on Mac).

## §4 Noise reduction strategies (cross-cutting)

1. **Docs-only short-circuit**: extend the existing
   `gate_commit.sh` docs-only detection to also short-circuit
   zone_check + check_skip_adrs + check_adr_history when no src/ or
   ADR file changed.
2. **WARN delta**: file_size_check + check_adr_history print only
   changes vs previous baseline (cached in `.zig-cache/<gate>_baseline`).
3. **--quiet mode**: every check_*.sh gains a `--quiet` flag that
   suppresses informational stdout (used by gate_commit; full output
   on manual invocation).

## §5 Skip-rule extensions

`gate_commit.sh`'s current diff classification:

```
src/*|test/*|include/*|build.zig|build.zig.zon|flake.nix|flake.lock
```

triggers `zig build test`. The proposal:

- `src/*` + `test/*` + `include/*` + `build.zig*` → run zig build test.
- `flake.*` → run `nix flake check` instead (Zig build re-eval is
  redundant if the Nix shell didn't actually change).
- `.dev/*.md` + `.claude/*` + `scripts/*` + `*.md` → skip zig build
  test + skip zone_check + skip check_skip_adrs + skip
  check_adr_history (currently only the build is skipped).

This converts ~30 s of pre-commit cost to ~3 s on doc-only commits.

## §6 Recommended §9.12-A / A7 follow-up actions

| Item | Effort | Effect |
|---|---|---|
| Add docs-only short-circuit to zone_check + check_skip_adrs + check_adr_history wrappers | 1 commit (30 LOC each) | -27 s on doc-only pre-commit |
| WARN-delta caching for file_size_check + check_adr_history | 1 commit (50 LOC) | -2.6 s + clean stdout |
| `--quiet` flag across check_*.sh | 1 commit (15 sites × 5 LOC) | Reduced log volume |
| Wire A1 scripts into gate_commit (libc / fallback) + pre-push (ratchet / subrow_exit) | 1 commit (gate_commit.sh edit + pre-push hook) | Establishes new enforcement; ~250 ms added to pre-commit |

Estimated cumulative gain on doc-only pre-commit: **29 s → 3 s** (≥
20 % gate_commit improvement, master plan §9.12-A target).

## §7 Open questions

- Whether to keep `check_adr_history` in `gate_commit.sh` at all when
  no ADR changed. Alternative: move to pre-push only.
- `check_md_tables` measurement is pending (PreToolUse hook context
  only; not directly invoked).
- `zig build lint` cold-vs-warm timing (warm should be < 10 s; cold
  ~120 s due to zlinter compile).

## §8 References

- Master plan §9.12-A (the chunk this study fulfils).
- `scripts/gate_commit.sh` (the orchestrator the study optimises).
- ADR-0009 (Mac-host lint gate).
- ADR-0029 (skip-impl vs skip-adr semantics; check_skip_adrs basis).
- ADR-0050 D-5 / D-6 (skip-impl ratchet; check_skip_impl_ratchet basis).
- ADR-0070 (libc boundary; check_libc_boundary basis).
- ADR-0072 (comment-as-invariant rule; check_invariant_comments basis).
- ADR-0050 D-1 (ADR Status lifecycle; check_adr_history basis).
