# Trust exit codes, not output tails, for gate verification

**Date**: 2026-05-28
**Citing**: cycle-65 retrospective (`1e88350f` + `2f33dc06` shipped
with broken local Mac test; ubuntu kick failed at cycle 66 resume).

## What happened

Cycle 65 added "multi-memory" to `spec_assert_runner_wasm_3_0.zig`'s
PROPOSALS list (5 → 6 entries) but missed updating the pinning test
at `:440` (`expectEqual(@as(usize, 5), PROPOSALS.len)`). The bug was
local — Mac `zig build test` would have failed clearly. But the
commit message claimed "test-all + lint green on Mac aarch64",
shipped to origin, and Ubuntu kick exposed the lie on resume.

## Root cause

The cycle-65 gate verification used:

```sh
zig build test-all 2>&1 > /tmp/test_run.log; echo "EXIT=$?"; tail -3 /tmp/test_run.log
```

`tail -3` on a 5.7MB output captured the LAST runner's summary
(`wast_runner: 1158 passed, 0 failed`) — but the *failing test* was
in a different layer (`zig build test` proper). The `EXIT=$?` line
DID print `EXIT=1` (the build failed), but the format made it easy
to skim past — the eye drops to the tail summary and reads "green".

The narrower `zig build test` would have shown the failure cleanly,
but I went straight to `test-all` for thoroughness and lost the
signal in the volume.

## Rule

When verifying a gate before commit:

1. **Always check `echo $?` / `EXIT=$?` first**, before any tail/grep.
   If non-zero, gate failed; stop and find the error.
2. If using `test-all` or any multi-step gate, **explicitly grep for
   `error:` / `failed:` / `fail \d` patterns in the full log**, not
   just the tail. Multi-step gates have many runners; only some
   emit a final summary line.
3. **Never claim "X green" in a commit message without re-checking
   the exit code from this exact run.** The `[gate_commit]` lines
   from the pre-commit hook don't substitute — they only cover the
   `--fast` shape that skips `zig build test`.

## Mechanical detection

A `scripts/verify_gate_green.sh` wrapper that fails loudly when:

- `zig build test-all` exit non-zero
- OR any line in the output matches `^error:` or `failed:` outside
  a known-stderr-noise allowlist (e.g., negative-case
  `compileWasm: ... → validate StackTypeMismatch` lines that are
  expected output from assert_invalid tests)

would catch this class of bug at gate time. Filed as future-cycle
infra (no debt row yet — small enough to land in a single
infrastructure cycle when surface area justifies).

## Related

- ADR-0076 D3 (3-host gate via ubuntu kick) — the kick was the
  *second line of defense* that caught the bug, but the first line
  (local Mac gate) should not have let it through.
- `.claude/skills/continue/GATE.md` — gate workflow (revisit
  exit-code primacy when this lesson stabilises).
