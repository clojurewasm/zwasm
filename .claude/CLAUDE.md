# zwasm

Standalone Zig WebAssembly runtime — library AND CLI tool.
Zig 0.15.2. Memo: `@./.dev/memo.md`. Roadmap: `@./.dev/roadmap.md` + `@./private/roadmap-production.md`.

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
- If on `strictly-check/reliability-*` branch → also read `@./.dev/reliability-handover.md`
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
- **Reliability work**: done when all phases in `@./.dev/reliability-handover.md` are `[x]`.
Do NOT stop for: merges, branch boundaries, empty queue, large context, user not responding.
When in doubt, **continue**.

### Commit Gate Checklist

0. **TDD**: Test written/updated BEFORE production code (skip for doc-only)
1. **Tests**: `zig build test` — all pass, 0 fail, 0 leak
2. **Spec tests**: `python3 test/spec/run_spec.py --build --summary` — fail=0, skip=0
   (Required when modifying vm.zig, predecode.zig, regalloc.zig, opcode.zig, module.zig, wasi.zig, validate.zig)
3. **E2E tests**: `bash test/e2e/run_e2e.sh --convert --summary` — fail=0, leak=0
   (Required when modifying interpreter/opcodes)
4. **Real-world compat**: `bash test/realworld/run_compat.sh` — PASS=30, FAIL=0, CRASH=0
   (Required when modifying vm/wasi/JIT)
5. **Benchmarks**: Required for optimization/JIT tasks.
   - Quick check: `bash bench/run_bench.sh --quick`
   - **Record**: `bash bench/record.sh --id=ID --reason="REASON"` (appends to history.yaml)
6. **Size guard**: Binary ≤ 1.5MB (stripped), memory ≤ 4.5MB RSS
7. **decisions.md / checklist.md / spec-support.md / memo.md**: Update as needed

### Merge Gate Checklist

**Mac AND Ubuntu x86_64** (see `@./.dev/ubuntu-x86_64.md`):
- `zig build test` — all pass, 0 fail, 0 leak
- `python3 test/spec/run_spec.py --build --summary` — fail=0, skip=0
- `bash test/e2e/run_e2e.sh --convert --summary` — fail=0, leak=0
- `bash test/realworld/run_compat.sh` — PASS=30, FAIL=0, CRASH=0
- Benchmarks pass (no regression)
Fix root cause before merging if Ubuntu reveals new failures.

## Build & Test

```bash
zig build test                     # Run all tests
zig build test -- "X"              # Specific test only
./zig-out/bin/zwasm run file.wasm  # Run wasm module
```

## Context Efficiency

- **Read with offset/limit**: Never read an entire large file.
- **LSP first, Read second**: Use `xref-find-references`, `imenu-list-symbols`, or
  `xref-find-apropos` to locate the exact line range, then Read that range only.
- **Grep for discovery**: Grep with context (`-C`) is far cheaper than reading a whole file.

## References

Zig tips: `@./.claude/references/zig-tips.md` — check before writing Zig code.
Benchmarks: `@./.claude/rules/bench-check.md` (auto-loads on bench/jit/vm edits).
JIT: `@./.claude/rules/jit-check.md` (auto-loads on jit.zig edits).
Reliability: `@./.claude/rules/reliability-work.md` (auto-loads on src/test/bench edits).
