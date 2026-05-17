# Cross-module no-op import stub hangs the runner on control-flow-dependent fixtures (D-138)

Citing: §9.9-III chunk (c)-2 attempt at commit `29dbaed2` (reverted);
debt D-138.

## Observation

Phase 9 Cat III (c)-1c landed the runner-side `registered`
StringHashMap so `(register "M" $inst)` directives populate a
session-local registry. The natural next step ((c)-2) was to relax
`hasUnbindableImports` to permit function imports from registered
aliases — routing them through the existing shared `hostImportTrapStub`
no-op (matching the spectest path landed at (c)-1b).

The relaxation **hung `zwasm-spec-wasm-2-0-assert` past 180 s** on at
least one previously-skipped fixture. Reverted at chunk close.

## Root cause hypothesis

The spectest no-op stub works because **spectest functions are
side-effect-only** (`print_i32`, `print_f32`, etc.) — fixtures that
call them don't depend on observable return state or shared mutation.
Cross-module functions, by contrast, are arbitrary user code: a
common shape is the importer expecting the import to advance a
counter / mutate shared memory / return a control-flow signal.
No-op stubbing those breaks the importer's termination contract.

A specific likely shape (not yet bisected; would require enabling +
isolating individual fixtures): an importer with a loop calling the
imported function, expecting it to decrement a counter or return 0
when done. The no-op stub never does that → the loop iterates forever
→ harness times out.

## Angles

### no-workaround

The relaxation IS a workaround (let it compile, accept wrong
semantics). Per [`no_workaround.md`](../../.claude/rules/no_workaround.md)
this is forbidden unless paired with a debt row naming the
structural barrier. D-138 was filed at revert + the chunk was
reverted — but the lesson here is that the workaround **didn't even
hold the gate green** (it hung). "Stub that returns" only works for
genuinely-side-effect-only host functions; generalizing it to user
code is unsound.

### こうすればもっとデバッグが楽だった

- The 180-s hang surfaced as `exit 142 = SIGALRM` from the build
  harness's outer timeout, NOT from a clear infinite-loop indication.
  Direct binary invocation with `timeout 180` confirmed the hang
  was inside the runner.
- A **per-fixture isolation tool** (`zig build run-spec-fixture
  -Ddir=<corpus> -Dline=N`) would have let me bisect to the
  specific (register, import-using-the-alias) pair that hangs.
  Today's runner is monolithic — runs the whole corpus.
- A **time-budget per fixture** in the runner (e.g. 1s wall-clock
  per `assert_return`, abort with `FAIL  <fixture>: timeout`)
  would have made the hang visible as a localized failure rather
  than a global SIGALRM. Costs perf in normal runs but cheap to
  add.

### 今後のために

- **The (c)-2 design ADR must address control-flow semantics**:
  per-import bound dispatch isn't just about getting bytes to flow;
  the binding has to deliver the actual function's behaviour
  (return value + side effects). Stub-only paths are unsound for
  any caller that observes results.
- **Mark "no-op return is correct" cases explicitly**: today's
  spectest no-op stub (per (c)-1b) is documented as "spectest void
  functions only" but enforcement is absent. If a future spectest
  signature added a non-void return, the no-op would silently
  miscompile. Either lint the spectest import shapes OR add the
  per-import bound dispatch as a hard requirement.
- **Apply the lesson to (c)-1b retrospectively**: (c)-1b worked
  by coincidence (spectest's current spec API is void-only). The
  generalization "no-op stub is fine for spec runner" is wrong —
  document the narrow precondition.

### 見えた設計課題

1. **Single shared `host_dispatch_base` slot** for all imports is
   a foundational gap. Per-import slot indexing is a hard
   prerequisite for any cross-module work. The fact that the
   spectest path worked obscured this — until cross-module
   surfaced the structural limit.
2. **Skip-vs-fail classification opacity**: SKIP-CROSS-MODULE-IMPORTS
   counts toward `skipped` not `failed`, but reading the count
   doesn't tell you whether those fixtures would PASS, FAIL, or
   HANG if the skip were lifted. The (c)-2 attempt was the first
   live measurement → 1 hang fixture among ~136 skipped. Pre-
   measurement assumed mostly PASSable. Future skip-relaxation
   chunks should run with per-fixture time budget to catch hangs
   early instead of via 180s SIGALRM.
3. **Cost of premature relaxation**: Cat III progress that
   doesn't add real semantic binding (just removes skip
   classification) trades green-skip for hidden hangs. The
   chunk-granularity discipline should weight "test gate
   completed in reasonable time" as a non-trivial signal of
   whether the change is a real fix vs surface-level relaxation.

## Cited from

- `.dev/debt.md` D-138 (Status: blocked-by per-import bound dispatch)
- `.dev/handover.md` (active task: (c)-2 with bound-dispatch design)
- `.dev/phase9_close_plan.md` §6 step (c) sub-chunk 2 (cross-module
  import linker)
