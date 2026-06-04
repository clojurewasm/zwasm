# `zig build <run-step>` caches stderr → stale spec-runner diagnosis

**Date**: 2026-05-29
**Cycle**: 10.E-xmodule-tags cycle 111
**Citing**: `f5884d31` (cycle 111 chore commit)

## What happened

Diagnosing why exception-handling/try_table.1 fails, I ran
`zig build test-spec-wasm-3.0-assert > log 2>&1` repeatedly after adding
`std.debug.print` probes. The probes NEVER appeared, yet the summary
line (stdout, `stdout.print`) DID — and the GC `compile FAIL` prints
(same file, same `std.debug.print`) also appeared. Two full rebuilds:
byte-identical output. This *looked* like "my edits aren't compiled".

Root cause: zig's build-runner caches a `Run` step's captured
stdout/stderr keyed on the artifact hash, and **replays the cached
output** when it deems the step up-to-date — and, separately, when many
build sub-steps run in parallel, `std.debug.print` (stderr) lines get
dropped/interleaved while buffered `stdout` survives. So the captured
log was a MIX of stale-replay + lossy-stderr. It even served output
from an OLDER binary state in which try_table.1 had NOT been attempted
the same way — which is exactly what cycle 110 misread as "try_table.1
now INSTANTIATES".

## How to apply

When diagnosing a spec runner (or any `addRunArtifact` exe) via
`std.debug.print`, **do NOT trust `zig build <step> 2>&1`**. Instead:

1. Build into a throwaway cache to force a real recompile:
   `rm -rf /tmp/c && zig build <step> --cache-dir /tmp/c` — this proves
   the binary is current, but the run-step output may STILL be lossy.
2. **Run the freshly-built binary DIRECTLY**, splitting streams:
   ```sh
   BIN=$(/bin/ls -t /tmp/c/o/*/<exe-name> | head -1)
   "$BIN" <args> 2>/tmp/err.log 1>/tmp/out.log
   ```
   Direct invocation = no build-runner interleaving; stderr is complete
   and ordered. (Use `/bin/ls`, not aliased `ls -F`, to avoid the `*`
   classifier suffix breaking the path.)
3. Sanity-gate with an unconditional `[PROBE-ALIVE]` print at the top of
   the loop. Under `zig build` it fired for only 3/6 proposals (lossy);
   run directly it fired 6/6 — that delta is the tell that the build
   path was eating stderr.

## Why this matters beyond this bug

This is a narrative-claim-vs-landed-state failure
(`2026-05-16-narrative-claim-vs-landed-state.md`) with a NEW cause:
not handover drift, but a **caching/IO artifact masquerading as a code
change**. Any cycle that concludes "X now works" from `zig build`
stderr is suspect — re-verify by direct binary run before recording
the claim in handover/lessons/ADR.

## Related

- `.dev/lessons/2026-05-16-narrative-claim-vs-landed-state.md`
- `.dev/lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`
  (the EH blocker chain this trap corrupted — cycle 110 false
  "INSTANTIATE" claim).
