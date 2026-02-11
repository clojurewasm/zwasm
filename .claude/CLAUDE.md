# zwasm

Standalone Zig WebAssembly runtime — library AND CLI tool.
Zig 0.15.2. Memo: `.dev/memo.md`. Roadmap: `.dev/roadmap.md`.

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
- **Architectural decisions only** → `.dev/decisions.md` (D## entry, D100+ numbering).
  Bug fixes and one-time migrations do NOT need D## entries.
- **Update `.dev/checklist.md`** when deferred items are resolved or added.

## Branch Policy

**main = stable release branch.** ClojureWasm depends on zwasm main via GitHub URL.
Breaking main breaks CW for all users.

- **All development on feature branches**: `git checkout -b <stage>/<task>` (e.g. `5/5.6-matrix-opt`)
- **Commit freely to feature branches**: one task = one commit rule still applies
- **Merge to main only after**:
  1. `zig build test` passes (zwasm)
  2. `python3 test/spec/run_spec.py --summary` passes (if interpreter/opcodes changed)
  3. CW verification: `cd ~/ClojureWasm && zig build test && bash test/e2e/run_e2e.sh`
     (update CW's build.zig.zon hash to point at the feature branch HEAD first)
  4. `bash bench/run_bench.sh --quick` shows no regression
- **Tag after milestones**: `git tag v0.X.Y` after merging significant features.
  Update CW's build.zig.zon hash to the new tag.
- **Orient step**: At session start, check if you're on main or a feature branch.
  If on main with pending work, create a feature branch first.

## Autonomous Workflow

**Default mode: Continuous autonomous execution.**
After session resume, continue automatically from where you left off.

### Loop: Orient → Plan → Execute → Commit → Repeat

**1. Orient** (every iteration / session start)

```bash
git log --oneline -3 && git status --short && git branch --show-current
```

**Branch check**: If on `main` and about to start new work, create a feature branch first.
See Branch Policy above.

Read `.dev/memo.md` → look at `## Current Task`:
- **Has design details** → skip Plan, go straight to Execute
- **Title only or empty** → go to Plan

Lazy load: roadmap.md, decisions.md, checklist.md, bench-strategy.md (only when needed).

**2. Plan**

1. Write task design in `## Current Task` (approach, key files)
2. Check `roadmap.md` and `.dev/checklist.md` for context

**3. Execute**

- TDD cycle: Red → Green → Refactor
- Run tests: `zig build test`
- Spec tests: `python3 test/spec/run_spec.py --summary` (when changing interpreter or opcodes)
- `jit.zig` modified → `.claude/rules/jit-check.md` auto-loads
- `bench/`, `vm.zig`, `regalloc.zig` modified → `.claude/rules/bench-check.md` auto-loads
- **Investigation**: Check reference impls when debugging, designing, OR optimizing:
  - wasmtime: `~/Documents/OSS/wasmtime/` (JIT patterns, cranelift)
  - zware: `~/Documents/OSS/zware/` (Zig idioms, API patterns)
  - WasmResearch: `~/Documents/MyProducts/WasmResearch/docs/` (spec analysis)
- **Optimization profiling**: When a benchmark has a performance gap vs wasmtime,
  read the corresponding cranelift codegen to understand what optimizations they apply.
  Key paths in wasmtime: `cranelift/codegen/src/isa/aarch64/` (ARM64 lowering),
  `cranelift/codegen/src/opts/` (optimization rules).
  The goal is parity (1x), not just "close enough" — study what they emit.

**4. Complete** (per task)

1. Run **Commit Gate Checklist** (below) — memo.md update is part of the gate:
   - Mark task `[x]` in Task Queue
   - `## Previous Task` ← one-line completed summary
   - `## Current Task` ← next task title only (no design yet — Orient decides)
   - Update `## Current State` only if metrics changed (LOC, test count, etc.)
2. Single git commit (code + memo in same commit)
3. **Immediately loop back to Orient** — do NOT stop, do NOT summarize,
   do NOT ask for confirmation. The next task starts now.

### No-Workaround Rule

1. **Fix root causes, never work around.** If a feature is missing and needed,
   implement it first (as a separate commit), then build on top.
2. **Spec fidelity over expedience.** Never simplify API shape to avoid gaps.
3. **Checklist new blockers.** Add W## entry for missing features discovered mid-task.

### When to Stop

See `.dev/memo.md` for task queue and current state.
See `.dev/roadmap.md` for stage order and future plans.
Do NOT stop between tasks within a stage.

Stop **only** when:

- User explicitly requests stop
- Ambiguous requirements with multiple valid directions (rare)
- **Current stage's Task Queue is empty AND next stage requires user input**

Do NOT stop for:

- Task Queue becoming empty (plan next task and continue)
- Session context getting large (compress and continue)
- "Good stopping points" — there are none until the current stage is done

When in doubt, **continue** — pick the most reasonable option and proceed.

### Commit Gate Checklist

Run before every commit:

0. **TDD**: Test written/updated BEFORE production code in this commit
1. **Tests**: `zig build test` passes
2. **Spec tests**: `python3 test/spec/run_spec.py --summary` — REQUIRED when modifying
   vm.zig, predecode.zig, regalloc.zig, opcode.zig, module.zig, wasi.zig
3. **Benchmarks**: REQUIRED for optimization/JIT tasks.
   Quick check: `bash bench/run_bench.sh --quick`
   Record: `bash bench/record.sh --id=TASK_ID --reason=REASON`
4. **decisions.md**: D## entry for architectural decisions (D100+)
5. **checklist.md**: Resolve/add W## items
6. **spec-support.md**: Update when implementing opcodes or WASI syscalls
7. **memo.md**: Update per Complete step 1 format above

### Merge Gate Checklist (feature branch → main)

Run before merging to main (in addition to commit gate):

1. **CW build**: `cd ~/ClojureWasm && zig build test` — compiles and passes
2. **CW e2e**: `bash test/e2e/run_e2e.sh` — all e2e tests pass
3. **CW portability**: `bash test/portability/run_compat.sh` — all pass
4. **Tag**: `git tag v0.X.Y` if milestone warrants a version bump
5. **CW hash update**: After tagging, update CW's `build.zig.zon` hash to new tag

### Stage Completion

When Task Queue empty:

1. If next stage exists in `roadmap.md`: create Task Queue in memo.md
2. If not: plan new stage:
   - Read `roadmap.md`, `.dev/checklist.md`
   - Priority: bugs > blockers > deferred items > features
   - Update memo.md with new Task Queue
   - Commit: `Plan Stage X: [name]`
3. Continue to first task

## Build & Test

```bash
zig build              # Build (Debug)
zig build test         # Run all tests
zig build test -- "X"  # Specific test only
./zig-out/bin/zwasm run file.wasm          # Run wasm module
./zig-out/bin/zwasm run file.wasm -- args  # With arguments
```

## Context Efficiency

Minimize context consumption to extend session life:

- **Read with offset/limit**: Never read an entire large file. Use `offset` and `limit`
  to read only the function or section you need.
- **LSP first, Read second**: Use `xref-find-references`, `imenu-list-symbols`, or
  `xref-find-apropos` to locate the exact line range, then Read that range only.
- **Grep for discovery**: Use the Grep tool to find relevant lines before reading files.
  A Grep result with context (`-C`) is far cheaper than reading a whole file.

## Benchmarks

Benchmark discipline: `.claude/rules/bench-check.md` (auto-loads on bench/jit/vm edits).
**YAML-first**: Before running benchmarks, check `bench/history.yaml` and
`bench/runtime_comparison.yaml` for existing data. Fresh runs are only needed
after code changes — commit gate handles recording automatically.
Zig tips: `.claude/references/zig-tips.md` — check before writing Zig code.
Reference index: `.dev/memo.md` § References
