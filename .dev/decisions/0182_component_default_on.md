# ADR-0182 — Component support default-ON; `-Dcomponent=false` is the real lean opt-out

> **Doc-state**: ACTIVE
> Status: Accepted (2026-06-13)

## Context

D-321: the `-Dcomponent` gate had ROTTED for the CLI — `cli/main.zig`
routed component-layer binaries to the component host without a comptime
gate, so a DEFAULT build shipped (and ran) the whole CM/WASI-P2 subsystem
while build.zig claimed "default false so the production CLI/lib emit
zero component code". Restoring the gate and measuring (perf-measure-first):

| Build (ReleaseFast, aarch64-macos) | Bytes     |
|------------------------------------|-----------|
| gated default (no component)       | 1,775,096 |
| with `-Dcomponent`                 | 1,935,128 |

The full Component Model + WASI Preview 2 subsystem costs **160,032 B
(~156 KB, +8.3%)**.

## Decision

**Flip the `component` build option default to `true`.**

- The CLI runs components out of the box — matching wasmtime (the
  industry-standard behaviour ADR-0181's floor measures against) and the
  user ideal (full-featured + easy to use; a default CLI refusing a valid
  `.wasm` is a usability footgun disproportionate to 156 KB on a 1.9 MB
  binary).
- `-Dcomponent=false` becomes a REAL lean opt-out: the restored comptime
  gate in `cli/main.zig` makes the refusal explicit ("component support
  not compiled in (rebuild with -Dcomponent)") and genuinely strips the
  subsystem (verified by the size delta above).
- `bench/results/size_history.yaml` tracks both variants (`base` = the
  new default with components; `lean` = `-Dcomponent=false`) so the
  lightweight axis stays observed (D-320).

## Alternatives rejected

- **Restore opt-in (ADR-0170's original posture)** — saves 156 KB by
  default but breaks "a runtime that runs standard wasm artifacts out of
  the box"; every CM consumer would hit the refusal first. ADR-0170's
  opt-in was decided before CM was promoted into the §1.2 floor
  (ADR-0181); the floor promotion supersedes it.
- **Keep the rotted always-on without a working gate** — leaves the lean
  build a lie and the build.zig comment false (no_workaround).

## Consequences

- build.zig: `component` option default `true`; comment rewritten to the
  truth. ADR-0170's "opt-in `-Dcomponent`" wording is superseded on this
  point (Revision note added there).
- Docs (README / CLI ref / migration guide) say components run by
  default; `-Dcomponent=false` documented as the lean build.
- D-321 discharged by this ADR + the measurement row.
