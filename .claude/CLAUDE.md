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

## Autonomous Workflow

**Default mode: Continuous autonomous execution.**
After session resume, continue automatically from where you left off.

### Loop: Orient → Plan → Execute → Commit → Repeat

**1. Orient** (every iteration)

```bash
git log --oneline -3 && git status --short
```

Read: `.dev/memo.md` (current state, task queue, handover notes)
Do NOT read other .dev/ files unless the current task requires them.
Lazy load: roadmap.md (stage planning), decisions.md (arch context),
checklist.md (deferred items), bench-strategy.md (bench design).

**2. Plan**

1. Move current `## Current Task` content → `## Previous Task` (overwrite previous)
2. Write new task design in `## Current Task`
   Include key architectural context from the old Previous Task if the new task builds on it.
3. Check `roadmap.md` and `.dev/checklist.md` for context

**3. Execute**

- TDD cycle: Red → Green → Refactor
- Run tests: `zig build test`
- Spec tests: `bash test/spec/run.sh` (when changing interpreter or opcodes)
- `jit.zig` modified → `.claude/rules/jit-check.md` auto-loads
- `bench/`, `vm.zig`, `regalloc.zig` modified → `.claude/rules/bench-check.md` auto-loads
- **Investigation**: When debugging spec or designing, check reference impls:
  - wasmtime: `~/Documents/OSS/wasmtime/` (JIT patterns, cranelift)
  - zware: `~/Documents/OSS/zware/` (Zig idioms, API patterns)
  - WasmResearch: `~/Documents/MyProducts/WasmResearch/docs/` (spec analysis)

**4. Complete** (per task)

1. Run **Commit Gate Checklist** (below)
2. Single git commit
3. Update memo.md: advance Current State and Task Queue
4. **Immediately loop back to Orient** — do NOT stop, do NOT summarize,
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
2. **Spec tests**: `bash test/spec/run.sh` — REQUIRED when modifying
   vm.zig, predecode.zig, regalloc.zig, opcode.zig, module.zig, wasi.zig
3. **Benchmarks**: REQUIRED for optimization/JIT tasks.
   Quick check: `bash bench/run_bench.sh --quick`
   Record: `bash bench/record.sh --id=TASK_ID --reason=REASON`
4. **decisions.md**: D## entry for architectural decisions (D100+)
5. **checklist.md**: Resolve/add W## items
6. **spec-support.md**: Update when implementing opcodes or WASI syscalls
7. **memo.md**: Advance Current Task, update Task Queue

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

## Benchmarks

Benchmark discipline: `.claude/rules/bench-check.md` (auto-loads on bench/jit/vm edits).
Zig tips: `.claude/references/zig-tips.md` — check before writing Zig code.
Reference index: `.dev/memo.md` § References
