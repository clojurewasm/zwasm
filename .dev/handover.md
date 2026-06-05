# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## CLEAN-SESSION ENTRY (prepared 2026-06-06; loop deliberately NOT re-armed)

User stopped to switch accounts (rate limit). The current chunk (ADR-0164 **workstream A**, CLI surface)
reached a clean committed checkpoint **MID-PROGRAM** — A's codegen half + workstreams B/C/D still remain.
A fresh `/continue` resumes on the **lead** below, then runs the per-task TDD loop. Each item's full
mechanism + fix plan lives in its **debt row** (source of truth); this is just the routing.

## Active program — ADR-0164: trap / crash / exception diagnostics & UX (D-292)

JIT/AOT printed a bare `Trap` (no kind) where v1 + v2-interp give per-kind messages — a v1-parity
regression (surfaced by D-291). Audit-first, spans engines; four workstreams **A→B→C→D**, then D-291:

- **A — surface the trap KIND + message on ALL engines.**
  - ✅ **CLI surface DONE this checkpoint (`b6da8604`).** Wired `JitRuntime.trap_kind` through the JIT
    (`runVoidExportWasi`) + AOT (`runEntryWasi`) run paths → new `trap_surface.jitTrapCode` map → CLI prints
    a per-kind message. Precise codes (2 oob_table / 3 indirect_call_mismatch / 4 stack_overflow) print the
    interp-parity kind+msg; the generic bucket (0/1) honestly says "kind not yet distinguished". **Also fixed a
    double-message bug**: a genuine trap now maps to **exit 1 (a code, NOT a re-raised `error.Trap`)** on JIT/AOT,
    matching interp — previously it surfaced the kind AND re-raised, so `main.zig`'s `renderFallback` printed a
    SECOND `Trap` line. `renderFallback` is now reserved for non-trap errors (compile/validate/load). Verified:
    `zwasm run --engine jit|interp` + AOT `.cwasm` each print exactly ONE `zwasm:` line, exit 1.
  - **← LEAD (A remaining): codegen trap-code WIDENING.** JIT codegen records only generic 0/1 for
    `unreachable` / `oob_memory` / `div_by_zero` / `int_overflow`, so JIT still prints "kind not yet
    distinguished" for the COMMON traps (NOT full interp-parity yet — only call_indirect+stack are precise).
    The generic bucket is also arch-INCONSISTENT (`unreachable` → trap_kind 1 on arm64, 0 on x86_64 — found via
    ubuntu test-all RED at 4d58b315, test made arch-robust at 99b56f1c). Split the generic bucket into per-kind
    codes at the trap SITES so JIT/AOT reach full interp-parity AND unify the codes across arm64+x86_64: trap-code
    write sites are `arm64/emit.zig` (+ `shared/entry.zig` `[d-165]` print) and `x86_64/op_control.zig`. Extend
    `trap_surface.jitTrapCode` to map the new codes. Add per-kind fixtures. Step 0 survey the D-165 trap-code
    infra first (which codes exist, where written).
- **B — crash-vs-trap distinction.** Internal SIGSEGV/@panic = INTERNAL ERROR, not `Trap`; ideal zero
  host-crash; **restrict the `[stack_probe]` diag to genuine stack-overflow** (it currently prints on EVERY
  JIT trap as stub context — the noise seen on `unreachable`).
- **C — exception(EH)-vs-trap distinction.**
- **D — audit vs wasmtime / wasmer / WasmEdge / v1** (messages, backtrace, exit codes) → gap list.
- **then D-291** (ed25519 JIT trap) — once A's widening surfaces the KIND, debug_jit_auto PC→op + shrink to a
  minimal repro. The trap is a clean controlled wasm trap (characterized `256433`/`cf63377b`), not a SIGSEGV.

DISCHARGE (D-292): all engines emit clear per-kind trap messages + crash/trap/exception cleanly distinguished +
audit-gap list closed-or-deferred.

## Queue after the active program (time-consuming first, per user directive)

3. **D-288** (interp frame-stack inline+overflow redesign; ackermann 1021-deep traps at the 256 cap; ADR-likely).
4. **D-287** (validator control-stack cap 1024 rejects valid deep nesting — raise + ADR; product-envelope call).
5. Moderate: **D-284** (interp/jit/aot entry-resolution unify) · **D-290** (wabt→wasm-tools, user-directed hygiene).
6. Defer (low-signal / measure-first): **D-289 FP/param/stack large arms** · **D-286** (fill/init byte-loop).
   **D-285** (JIT byte-loop/bulk-memory codegen, ADR-0153 rework candidate — scheduled after this program).

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** v0.1.0-scope program is
  thoroughly complete + 3-host green (`deb97903`); ADR-0163 bench+docs program ALL DONE. Tag/publish/cutover are
  manual, user-only — there is no release gate.
- Debt ledger: 0 `now`. Last full 3-host green = `635bd734` (Mac + ubuntu `701cbe60` + windows `OK`).

## Step 0.7 (next resume) — verify remote logs

- **ubuntu: ✅ GREEN at `99b56f1c`** (verified this turn; `0e6a555d` on top is docs-only = no src delta).
  The first kick caught a real arch bug (x86_64 `unreachable` → trap_kind 0, not arm64's 1) → test made
  arch-robust at `99b56f1c`, re-kick GREEN.
- **windows: ⏳ kicked this turn (6-commit cadence), RUNNING at last check.** Verify `tail -3 /tmp/win.log`
  at next resume: `[run_remote_windows] OK` → `bash scripts/should_gate_windows.sh --record`. The arch-robust
  test is win64-skipped, so the win run at `4d58b315` is representative of `99b56f1c`. windows RED → re-run
  once: reproduces = real Win64 bug (debt+fix), flake = `track_heisenbug.sh`. Then proceed to the LEAD above.

## Key refs

- **ADR-0164** (this program: `.dev/decisions/0164_trap_crash_exception_diagnostics_ux.md`). **D-292** (program
  debt row) + **D-291** (ed25519 motivating case) + **D-165** (JIT trap-code infra). ADR-0156 (no autonomous
  release). ADR-0016 (trap stderr / diagnostic phases).
- Surfaces: `src/cli/run.zig` (`surfaceTrap` interp / `surfaceJitTrap` jit+aot / `runWasmJit` / `runCwasmWasi`),
  `src/api/trap_surface.zig` (`jitTrapCode` / `trapMessageFor` / `TrapKind`), `src/cli/main.zig` (`renderFallback`
  trap path), `src/runtime/trap.zig` (Trap set), `src/engine/codegen/shared/entry.zig` (`[d-165]` print),
  `src/engine/codegen/{arm64/emit.zig,x86_64/op_control.zig}` (trap-code write sites), `src/platform/stack_limit.zig`
  (`[stack_probe]` diag). v1 per-kind msgs: `~/Documents/MyProducts/zwasm/src/cli.zig`.
