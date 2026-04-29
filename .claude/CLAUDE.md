# zwasm

Standalone Zig WebAssembly runtime — library AND CLI tool.
Zig 0.16.0. Memo: `@./.dev/memo.md`. Roadmap: `@./.dev/roadmap.md`.

## Language Policy

- **All code in English**: identifiers, comments, docstrings, commit messages, markdown

## TDD (t-wada style)

1. **Red**: Write exactly one failing test first
2. **Green**: Write minimum code to pass
3. **Refactor**: Improve code while keeping tests green

- Never write production code before a test (1 test → 1 impl → verify cycle)
- Progress: "Fake It" → "Triangulate" → "Obvious Implementation"
- Zig file layout: imports → pub types/fns → private helpers → tests at bottom

## Critical Rules

- **One task = one commit**. Never batch multiple tasks.
  (During experimental work: uncommitted experiments are fine to revert.
  Only committed code follows this rule.)
- **Architectural decisions only** → `@./.dev/decisions.md` (D## entry, D100+ numbering).
  Bug fixes and one-time migrations do NOT need D## entries.
- **Update `@./.dev/checklist.md`** when deferred items are resolved or added.

## Branch Policy

**main = stable release branch.** ClojureWasm depends on zwasm main via GitHub URL.

- **All development on feature branches**: `git checkout -b <stage>/<task>`
- **Merge to main only after Merge Gate** (below)
- **Tag + CW release**: Use `/release` skill.
- **Orient step**: At session start, check branch. If on main with pending work, branch first.

## Autonomous Workflow

**Default mode: Continuous autonomous execution.**

### Loop: Orient → Plan → Execute → Commit → Repeat

**1. Orient** (every iteration / session start)

```bash
git log --oneline -3 && git status --short && git branch --show-current
```

Read `@./.dev/memo.md` → `## Current Task`:
- **Has design details** → Execute
- **Title only or empty** → Plan

**2. Plan** — Write design in `## Current Task`. Check roadmap + checklist for context.

**3. Execute**

- TDD cycle: Red → Green → Refactor
- Run tests: `zig build test`
- Spec tests: `python3 test/spec/run_spec.py --build --summary` (when changing interpreter/opcodes)
- **Investigation**: Check reference impls when debugging, designing, OR optimizing:
  - wasmtime: `~/Documents/OSS/wasmtime/` (JIT patterns, cranelift codegen)
  - zware: `~/Documents/OSS/zware/` (Zig idioms, API patterns)
  - **Clone more if needed**: `~/Documents/OSS/` — other runtimes as reference
  - **Web search**: Use WebFetch/WebSearch for specs, blog posts, papers
- **Optimization**: Study cranelift codegen for the same operation. Goal is parity (1x).

**4. Complete** — Run Commit Gate → update memo.md → commit → loop back immediately.

### No-Workaround Rule

1. **Fix root causes, never work around.** Missing feature? Implement it first.
2. **Spec fidelity over expedience.** Never simplify API to avoid gaps.
3. **Checklist new blockers.** Add W## entry for missing features discovered mid-task.

### When to Stop

Stop **only** when: user requests, ambiguous requirements, or current stage done.
Do NOT stop for: merges, branch boundaries, empty queue, large context, user not responding.
When in doubt, **continue**.

### Commit Gate Checklist

**One-liner**: `bash scripts/gate-commit.sh` runs items 1-5 + 8 in order.
Add `--bench` for item 6, `--only=NAME` / `--skip=NAME` to scope.

0. **TDD**: Test written/updated BEFORE production code (skip for doc-only)
1. **Tests**: `zig build test` — all pass, 0 fail, 0 leak
2. **Spec tests**: `python3 test/spec/run_spec.py --build --summary` — fail=0, skip=0
   (Required when modifying vm.zig, predecode.zig, regalloc.zig, opcode.zig, module.zig, wasi.zig, validate.zig)
3. **E2E tests**: `python3 test/e2e/run_e2e.py --convert --summary` — fail=0, leak=0
   (Required when modifying interpreter/opcodes)
4. **Real-world compat**: `python3 test/realworld/run_compat.py` — PASS=50, FAIL=0, CRASH=0
   (Required when modifying vm/wasi/JIT)
5. **FFI tests**: `bash test/c_api/run_ffi_test.sh --build` — 0 failed
   (Required when modifying c_api.zig, build.zig lib targets, or include/zwasm.h)
6. **Benchmarks**: Required for optimization/JIT tasks.
   - Quick check: `bash scripts/run-bench.sh --quick`
   - **Record**: `bash bench/record.sh --id=ID --reason="REASON"` (appends to history.yaml)
7. **Size guard**: Binary ≤ 1.60 MB stripped (Linux ELF ~1.56 MB; Mac ~1.20 MB),
   memory ≤ 4.5 MB RSS. Originally 1.50 MB on Zig 0.15; raised to 1.80 MB
   as a pragmatic compromise during the Zig 0.16 / `link_libc = true`
   transition; pulled back to 1.60 MB after W46 (link_libc=false restored)
   and W48 Phase 1 (panic / segfault / u8-main trim). Reaching the original
   1.50 MB target is tracked as W48 Phase 2 — non-blocking.
8. **Minimal build** (when adding tests): `zig build test -Djit=false -Dcomponent=false -Dwat=false`
   Tests using WAT must guard with `if (!build_options.enable_wat) return error.SkipZigTest;`
   Tests using JIT must guard with `if (!build_options.enable_jit) return error.SkipZigTest;`
9. **decisions.md / checklist.md / spec-support.md / memo.md**: Update as needed

### Merge Gate Checklist

**One-liner**: `bash scripts/gate-merge.sh` runs the Commit Gate +
items 8-9. Run on **BOTH Mac AND Ubuntu x86_64**. No skipping.
(see `@./.dev/references/ubuntu-testing-guide.md`, setup: `@./.dev/references/setup-orbstack.md`)

1. `zig build test` — all pass, 0 fail, 0 leak
2. `python3 test/spec/run_spec.py --build --summary` — fail=0, skip=0
3. `python3 test/e2e/run_e2e.py --convert --summary` — fail=0, leak=0
4. `python3 test/realworld/run_compat.py` — PASS=50, FAIL=0, CRASH=0
5. `bash test/c_api/run_ffi_test.sh --build` — 0 failed
6. `zig build test -Djit=false -Dcomponent=false -Dwat=false` — 0 fail (minimal build)
7. Benchmarks pass (no regression)
8. **CI green**: `gh run list --branch main --limit 1` — check after push
9. **versions.lock ↔ flake.nix consistency**: `bash scripts/sync-versions.sh`
   exits 0. Run automatically by `gate-merge.sh` and by the CI
   `versions-lock-sync` job.
10. **Local bench record on Mac, every merge**: after the PR is squash-merged
    and main is checked out (`git checkout main && git pull --ff-only`),
    `bash scripts/record-merge-bench.sh` appends one row to
    `bench/history.yaml` keyed on the merge commit SHA. Always full
    hyperfine (5 runs + 3 warmup, ~5 min) — `bench/history.yaml` is the
    canonical Mac M4 Pro absolute-time baseline used at tag time, so
    every entry must be measurement-grade. Lower run/warmup counts are
    only for `bench/run_bench.sh --quick`'s interactive smoke tests, not
    for durable history. Skipped automatically on Linux/Windows because
    the file's `env:` block is Darwin-only. Commit the resulting
    `history.yaml` change directly to main as a follow-up
    `Record benchmark for <subject>` commit; CI runs but is not gating
    for that small commit.

CI Linux runners separately enforce a soft regression check
(`bench/ci_compare.sh --base=origin/main --threshold=20 --runs=3
--warmup=1` on PR, `continue-on-error: true`) — Ubuntu-vs-Ubuntu, never
mixed with the Mac history. Treat the two baselines as independent
artefacts, not as values to compare against each other.

Items 1-6 must pass on BOTH platforms before merge. Run them in parallel:
Mac items can run locally, Ubuntu items via `orb run -m my-ubuntu-amd64`.
Fix root cause before merging if Ubuntu reveals new failures.

Environment setup, tool versions, and CI ↔ local mapping: `@./.dev/environment.md`.

## Build & Test

```bash
zig build test                     # Run all tests
zig build test -- "X"              # Specific test only
./zig-out/bin/zwasm run file.wasm  # Run wasm module
```

## Fuzzing

Fuzzing infrastructure in `test/fuzz/`. Corpus files (`.wasm`/`.wat`) are gitignored — generate locally.

### Corpus

```bash
bash test/fuzz/gen_corpus.sh       # Generate ~1800 wasm modules (9 categories via wasm-tools smith)
bash test/fuzz/gen_edge_cases.sh   # Hand-crafted edge cases (truncated, bad magic, oversized LEB, etc.)
```

Categories: mvp, simd, gc, eh, threads, mem64, tailcall, all (kitchen sink), invalid (malformed bodies).

### Running

```bash
bash test/fuzz/run_corpus.sh --build           # Quick corpus test (~1800 modules)
bash test/fuzz/fuzz_campaign.sh --duration=30   # Full campaign: corpus + fresh gen + mutation (30 min)
bash test/fuzz/fuzz_wat_campaign.sh --duration=30  # WAT-specific campaign: parse + mutation (30 min)
```

Overnight (snapshot binary, runs in background):
```bash
nohup bash test/fuzz/fuzz_overnight.sh --duration=660 > /dev/null 2>&1 &     # wasm, ~11h
nohup bash test/fuzz/fuzz_overnight_wat.sh --duration=360 > /dev/null 2>&1 &  # WAT, ~6h
tail -f /tmp/zwasm_fuzz_overnight.log     # Check progress
```

Results: `.dev/fuzz-overnight-result.txt`, `.dev/fuzz-overnight-wat-result.txt`.

### Harnesses (Zig)

| File                      | Purpose                                                              |
|---------------------------|----------------------------------------------------------------------|
| `src/fuzz_loader.zig`     | Stdin wasm → WASI fallback + parameterized invoke + JIT trigger (11x) |
| `src/fuzz_wat_loader.zig` | Stdin WAT → parse + encode + parameterized invoke + JIT trigger (11x)  |
| `src/fuzz_gen.zig`        | Structure-aware generators + phase-separate tests                     |

Harness features: WASI sandbox fallback (all caps denied), parameterized function invoke
(up to 8 args synthesized from input bytes), multi-value returns (up to 8), JIT compilation
trigger (calls each function HOT_THRESHOLD+1 times).

Generators in `fuzz_gen.zig`: deep nesting, many locals, unreachable code, many types/functions,
br_table, memory boundary, if/else chains, call_indirect, bulk memory, multi-value, tail call,
SIMD basic, GC struct, GC array, exception handling, typed select.

Phase-separate fuzz tests in `fuzz_gen.zig` (run via `zig build test`):
decoder, validator, predecode, regalloc — each tested independently with `std.testing.fuzz`.

### CI

Nightly (`nightly.yml`, weekly Wed): 60-min fuzz campaign on Ubuntu.
Crash files auto-saved to `test/fuzz/corpus/crash_*`.

## Context Efficiency

- **Read with offset/limit**: Never read an entire large file.
- **LSP first, Read second**: Use `xref-find-references`, `imenu-list-symbols`, or
  `xref-find-apropos` to locate the exact line range, then Read that range only.
- **Grep for discovery**: Grep with context (`-C`) is far cheaper than reading a whole file.

## References

Zig tips: `@./.claude/references/zig-tips.md` — check before writing Zig code.
Benchmarks: `@./.claude/rules/bench-check.md` (auto-loads on bench/jit/vm edits).
JIT: `@./.claude/rules/jit-check.md` (auto-loads on jit.zig edits).
Development: `@./.claude/rules/reliability-work.md` (auto-loads on src/test/bench edits).
Roadmap: `@./.dev/roadmap.md` (zwasm phases). The integrated zwasm/CW
roadmap lives in shota's `private/` directory (gitignored, not part of
the repo) — fresh checkouts on other machines do not have it.
Allocator injection: `@./.dev/archive/allocator-injection-plan.md` — Phase 11 design + task breakdown (D128, completed in v1.5.0; archived).
SIMD performance: `@./.dev/decisions.md` → D132 — two-phase SIMD optimization plan (W43 addr cache, W44 reg class).
Environment: `@./.dev/environment.md` — Mac/Linux/Windows setup, tool versions, CI ↔ local mapping (D136).
Ubuntu testing: `@./.dev/references/ubuntu-testing-guide.md` — OrbStack VM test commands.
OrbStack setup: `@./.dev/references/setup-orbstack.md` — VM creation and tool installation.
