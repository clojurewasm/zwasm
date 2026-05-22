# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing discipline:
> [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Fresh-session start here

**Authoritative remaining-work source**:
[`.dev/phase9_close_master.md`](./phase9_close_master.md).

**Mandatory before any §9.x [x] flip**: run

```sh
bash scripts/check_phase9_close_invariants.sh --gate
```

(per `.claude/skills/continue/SKILL.md` Resume Step 5d +
ADR-0104 + `.claude/rules/phase9_close_invariants.md`).

**Current gate state**: **17/18 passed** (was 16/18 at
2026-05-23 session start; 2026-05-23 advanced via ADR-0106
cycle 3e Phase 2'a–2'l implementation chain). Sole remaining
FAIL: **I1b — D-163 SKIP-WIN64-CALL-INDIRECT-TRAP**.

## Bucket-3 stop — user touchpoint required

All autonomous prep walked; loop stops without re-arm.

**Gating user touchpoint(s)**:

- **D-163 Win64 JIT call_indirect trap path investigation**
  requires actual Win64 runtime inspection (lldb-attach via
  windowsmini OR a Win64 test machine). Autonomous probe via
  Mac cross-compile + llvm-objdump is feasible but the byte-
  sequence analysis can't distinguish the leading hypotheses
  (H1 ADD-RSP shadow-space mismatch vs H2 VEH unwinder
  confusion vs H3 R15↔entry_arg0_gpr mapping) without runtime
  probe data. After D-163 fix lands + windowsmini reconciliation
  green, gate flips 18/18 and §9.13-0 / §9.12-F / §9.12-I /
  §9.13 are eligible for `[x]` per ADR-0104.

**Autonomous prep walked this resume** (do not re-walk):

- **Reference-repo enrichment**: wasmtime (Cranelift x64 +
  Winch) + Wasmer singlepass surveyed 2026-05-23. Findings in
  `private/spikes/d-163-win64-call-indirect-trap/README.md`:
  mature engines emit Win64 `.pdata + .xdata` unwind info per
  JIT function (zwasm v2 does not); wasmtime uses VEH context-
  rewrite for traps (zwasm v2 uses trap-stub RET); wasm-1.0
  `unreachable` works on Win64 with same RET pattern (refutes
  "unwind absence" as sole cause).
- **Throwaway spike**: `private/spikes/d-163-win64-call-
  indirect-trap/` running. 5 numbered hypotheses + distinguishing
  probes; refined ranking H2 (core) → H1 (supported) → H3
  (plausible) → H4/H5 (low).
- **ADR Consequences refinement**: ADR-0078 SKIP taxonomy row
  already cites D-163 + lists codegen-bug spike as the close
  path. No further refinement needed.
- **WebFetch upstream**: not strictly walked; wasmtime
  reference-repo survey covered the relevant MSDN Win64 ABI
  considerations (UNWIND_INFO + VEH mechanics).

**To resume**: get the cycle started on a Win64 host (or
windowsmini) with the runner under lldb; capture PC + register
state at crash point; match against the 5 hypotheses; then
re-invoke /continue with the probe results in handover.md
"Active task". Alternative autonomous path:
write a synthetic Zig spike (`private/spikes/d-163-.../probe.zig`)
that emits the bounds-check + trap-stub bytes for the
`call_indirect` OOB fixture, cross-compile to
`x86_64-windows-gnu`, and inspect via `llvm-objdump -d`. The
spike doc enumerates which hypotheses each probe distinguishes.

## Work landed this session (2026-05-23)

ADR-0106 cycle 3e Phase 2'a → 2'l (full implementation chain:
per-arch wrapper emit SysV+arm64+Win64 × 2-int+3-int shapes,
linker hookup, compileWasm wiring, entry helpers Win64-routing,
body-side cycle 2c MEMORY-class Win64 extension, SKIP arm
removal). D-094 + D-164 closed. 2 latent wrapper bugs caught
via e2e tests (arm64 X30 + x86_64 RBX). Lesson:
`2026-05-23-wrapper-thunk-stack-save-not-callee-saved.md`.
D-163 survey + spike + debt refinement (`3b456290`).

## Active `now` debts: none.

## See

- [`phase9_close_master.md`](./phase9_close_master.md) (§5.1
  D-163 only remaining; §6 exit predicate).
- ADR-0104 / 0105 / 0106 / 0078.
- `private/spikes/d-163-win64-call-indirect-trap/` (gitignored).
