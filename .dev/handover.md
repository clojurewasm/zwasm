# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active bundle

- **Bundle-ID**: D-292-A-codegen-widening (A1..A3)
- **Cycles-remaining**: ~1 (A3 oob_memory)
- **Continuity-memo**: per-kind JIT trap codes — 5=unreachable (A1 ✅), 7=div_by_zero + 8=int_overflow
  (A2 ✅), 6=oob_memory (A3 ←). Mechanism: dedicated per-kind trap stub writing a distinct `trap_kind`,
  fed by a per-kind fixup channel. arm64 = `EmitCindStub` (opcode-aware: patches B or B.cond) called per
  channel in emit.zig; x86_64 = `emitTrapExitStub(ctx, kind)` helper + a per-channel block in `emitEndInter`.
  A3 must DEMUX `bounds_fixups` (now oob-only on x86_64; oob+throw on arm64) — every scalar+SIMD load/store
  appends it (`op_mem*`, all `op_simd*` load/store). Give oob its own channel → stub code 6; LEAVE arm64
  `throw` in the generic bounds stub (it's an EH concept, workstream C, not a memory trap). Extend `jitTrapCode(6)`.
- **Exit-condition**: `jitTrapCode(6)` → oob_memory + an execution test asserts an oob load/store records
  code 6 on the real JIT path (mirror the A1/A2 `runVoidExportWasi` tests), both arches green.

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
  - ✅ **A1 DONE (`6fcbabbd`): `unreachable` → code 5** on BOTH arches (was arch-divergent generic 1/0).
  - ✅ **A2 DONE (`687d1a73`): div-by-zero → 7, div_s overflow → 8.** Demuxed `bounds_fixups` → divzero/
    overflow channels (both arches). Also fixed a latent x86_64 misreport (div_s overflow had ridden the
    div-by-zero channel → would have surfaced div_by_zero; now int_overflow). CLI prints precise kinds.
  - **← LEAD (A3): `oob_memory`(6).** The last common kind. Demux the load/store bounds-check sites out of
    `bounds_fixups` into an oob channel → stub code 6. Sites: `x86_64/op_mem*` + all `op_simd*` load/store
    (many — they pass `&bounds_fixups` positionally) and arm64 equivalents; keep arm64 `throw` generic.
    Step 0 survey the load/store bounds-check append sites on both arches first.
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
  Mac green through A2 `687d1a73` (this turn: A1+A2). ubuntu/windows kicks fire at turn-end push.

## Step 0.7 (next resume) — verify remote logs

- **ubuntu**: `tail -3 /tmp/ubuntu.log` — expect GREEN on the A1+ commits. RED on a codegen-real failure →
  auto-revert (D3); prior cycle's `unreachable` arch-divergence (x86_64 0 vs arm64 1) is the exact bug A1
  fixes by unifying to 5, so a trap-kind RED would be a real regression to investigate, not a flake.
- **windows**: RED with the sha256-shootout non-deterministic signature = the standing **D-279** Win64
  heisenbug (NOT trap work) — `track_heisenbug.sh win64-testall segv`, KEEP commits (D7), non-blocking.
  Real new Win64 bug (reproduces on re-run, codegen/ABI touch) → debt row + fix. See D-279 for the lineage.

## Key refs

- **ADR-0164** (this program: `.dev/decisions/0164_trap_crash_exception_diagnostics_ux.md`). **D-292** (program
  debt row) + **D-291** (ed25519 motivating case) + **D-165** (JIT trap-code infra). ADR-0156 (no autonomous
  release). ADR-0016 (trap stderr / diagnostic phases).
- Surfaces: `src/cli/run.zig` (`surfaceTrap` interp / `surfaceJitTrap` jit+aot / `runWasmJit` / `runCwasmWasi`),
  `src/api/trap_surface.zig` (`jitTrapCode` / `trapMessageFor` / `TrapKind`), `src/cli/main.zig` (`renderFallback`
  trap path), `src/runtime/trap.zig` (Trap set), `src/engine/codegen/shared/entry.zig` (`[d-165]` print),
  `src/engine/codegen/{arm64/emit.zig,x86_64/op_control.zig}` (trap-code write sites), `src/platform/stack_limit.zig`
  (`[stack_probe]` diag). v1 per-kind msgs: `~/Documents/MyProducts/zwasm/src/cli.zig`.
