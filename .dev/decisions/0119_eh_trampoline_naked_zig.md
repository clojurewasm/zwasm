# 0119 — Use pure-Zig `callconv(.naked)` for the EH dispatcher trampoline

- **Status**: Accepted
- **Date**: 2026-05-27
- **Author**: zwasm-from-scratch loop
- **Tags**: phase-10, exception-handling, codegen, abi

## Context

Phase 10.E EH on JIT (per ADR-0114 D6) requires a per-arch
assembly trampoline that sits between every JIT-emitted `throw`
/ `throw_ref` site and `shared/zwasm_throw.dispatchThrow`:

1. Captures the throw-site FP (X29 on AArch64 / RBP on x86_64) +
   saved-LR (X30 / saved-RIP) into a `ThrowSite` record on the
   stack — this MUST observe the caller's state BEFORE any
   prologue corruption.
2. Loads the Runtime pointer (X19 / R15 per ADR-0017) into the
   dispatcher's first C-ABI argreg.
3. Calls `shared/zwasm_throw.dispatchThrow(table, code_map,
   throw_site, max_depth)`.
4. Branches on the `UnwindResult` tag: on `.handler`, MOV SP per
   `sp_restore.emitSpRestoreFull` + JMP to `landing_pad_pc`; on
   `.uncaught`, set `trap_flag=1` + return via the standard
   bounds-trap epilogue (mirrors the IT-3 trap-only path that
   `op_throw.emit` currently produces).

The `.dev/phase10_eh_integration_plan.md` §IT-6 "Open questions
for user collab" explicitly flags the choice between:

- **Pure-Zig naked function**: one `.zig` file per arch, body
  consists of `asm volatile (...)` blocks; `callconv(.naked)`
  suppresses Zig's standard prologue/epilogue.
- **Per-arch `.s` file**: one assembly source per arch,
  assembled+linked by build.zig.

The integration plan recommends starting with the naked-Zig path
and falling back to `.s` if naked-fn semantics don't hold. This
ADR codifies that recommendation as the project decision so the
remaining IT-6 impl cycle (per bundle `10.E-codegen-IT-6`) can
proceed without re-litigating the choice mid-stream.

Per ROADMAP §18.2, this is a §4-area deviation (Zone 2 per-arch
codegen) that requires an Accepted ADR before the impl row
flips.

## Decision

**Implement the EH dispatcher trampoline as a pure-Zig
`callconv(.naked)` function in per-arch files**:

- `src/engine/codegen/arm64/throw_trampoline.zig` — AArch64
  (Mac aarch64 + Linux aarch64 cross-compile).
- `src/engine/codegen/x86_64/throw_trampoline.zig` — SysV
  (Linux x86_64) + Win64 (Windows x86_64), comptime-dispatched
  on `builtin.target.os.tag` per the existing project pattern.

Each file exports a single naked fn:

```zig
pub fn zwasmThrowTrampoline() callconv(.naked) noreturn {
    asm volatile (
        // 1. Capture FP + LR into ThrowSite stack record
        // 2. Marshal Runtime + tag + payload into argregs
        // 3. CALL dispatchThrow
        // 4. Branch on UnwindResult; JMP landing_pad_pc OR
        //    fall through to trap-stub return shape
        \\ ...
        :
        :
        : "memory"
    );
}
```

The throw-site emit (`op_throw.emit` + `op_throw_ref.emit`)
replaces its IT-3 trap-branch with a CALL/BL to
`@intFromPtr(&zwasmThrowTrampoline)`. The address is embedded
into the per-function literal pool (arm64) or RIP-relative
MOVABS (x86_64) and called via BLR / CALL.

## Alternatives considered

### Alternative A — Per-arch `.s` file

- **Sketch**: One `throw_trampoline_aarch64.s` per arch,
  assembled via `build.zig`'s `addAssemblyFile` + linked into
  the test runner / zwasm exe. The trampoline symbol is exported
  C-linkable (`.global zwasm_throw_trampoline`) and referenced
  from the Zig side via `extern fn`.
- **Why rejected**:
  - **Build complexity**: `.s` files need separate handling per
    host toolchain — macOS Clang assembler, Linux GNU as, and
    Windows MinGW vs MSVC. The current project tooling assumes
    single-language Zig sources; adding `.s` triples the toolchain
    sensitivity surface for one isolated stub.
  - **Tooling fragmentation**: `zig fmt` / LSP integration don't
    apply to `.s`. Future modifications need a separate review
    flow.
  - **No real exact-byte-control gain**: the naked-fn body is
    100% inline `asm volatile`. The compiler still produces the
    same bytes; we lose nothing by housing them in a Zig file.
  - **Cross-compile harness**: Mac aarch64 → Linux x86_64 cross-
    builds via `zig build -Dtarget=` already work for `.zig` per
    `flake.nix` pinning. `.s` would need an extra cross-assembler
    invocation per target.
- **Reversal cost**: low — if the naked-fn path turns out to be
  unworkable on one arch, we can switch JUST that arch to `.s`
  by replacing the `.zig` file 1:1. The throw-site emit's
  `@intFromPtr(&zwasmThrowTrampoline)` symbol lookup is
  agnostic to source language.

### Alternative B — Standard Zig fn with frame-address builtins

- **Sketch**: Use a regular Zig fn that reads FP/RBP via
  `@frameAddress(0)` and writes the `ThrowSite` record before
  calling dispatchThrow. No `naked`.
- **Why rejected**: the Zig-emitted prologue (`STP X29, X30,
  [SP, #-16]!; MOV X29, SP` on AArch64; `PUSH RBP; MOV RBP,
  RSP` on x86_64) MOVES FP to the trampoline's own frame
  before the body runs. `@frameAddress(0)` then returns the
  trampoline's FP, not the throw-site's. `@frameAddress(1)`
  could work but its semantics are documented for debug
  introspection, not load-bearing unwind machinery; relying on
  it for production EH is fragile.

### Alternative C — Inline `asm` blocks at the entry of a regular Zig fn

- **Sketch**: A `fn` (not `naked`) where the first statement is
  `asm volatile` overriding the prologue's effect.
- **Why rejected**: the Zig compiler reserves the right to emit
  prologue/epilogue around the asm even when the whole body is
  asm. `naked` is the documented escape hatch for "I'm writing
  the entire frame discipline myself"; sneaking past Zig's
  prologue via `asm` is undefined behavior territory.

## Consequences

- **Positive**:
  - Single Zig source per arch, no `.s` toolchain dependency.
  - `zig fmt` + LSP cover the trampoline.
  - Comptime arch dispatch within one project pattern (`src/
    engine/codegen/{arm64,x86_64}/`), aligned with ADR-0017 +
    ADR-0023 directory shape.
  - Future port to a new arch (e.g. RISC-V) follows the same
    per-arch directory convention.
  - The throw-site emit's CALL target is just `&trampoline`'s
    address — the same `CallFixup` mechanism that handles
    intra-module Wasm calls can be reused (with the linker
    extended to recognize the trampoline symbol). Alternatively
    the address is loaded from `Runtime.throw_trampoline_ptr`
    set at instance init time.
- **Negative**:
  - `callconv(.naked)` semantics in Zig 0.16 are documented but
    less battle-tested than `.s` files. A future Zig version
    could change the codegen path — Removal condition (below)
    names this.
  - Inline `asm` lacks the "intermediate symbol" granularity
    `.s` files give (labels, sub-routines); the trampoline must
    be one flat asm block.
- **Neutral / follow-ups**:
  - The throw-site emit (`op_throw.emit`) must learn to embed
    `&zwasmThrowTrampoline` — either via a new CallFixup variant
    targeting non-Wasm symbols, or via a Runtime-field load.
    That mechanism choice is independent of this ADR and tracked
    in the IT-6 impl cycle.
  - `sp_restore.emitSpRestoreFull` integration on the `.handler`
    return path: the trampoline reads `landing_pad_pc` (now
    function-local per the IT-6 prep landing_pad_pc fixup,
    commit `18b2a077`) + `frame_bytes` (per IT-6 prep
    frame_bytes thread, commit `9ac268f1`) from the
    `UnwindResult` + `CodeMap.Entry`.

## Removal condition

ADR-0119 is superseded if either:

1. A Zig version change breaks `callconv(.naked)` semantics on
   any of the three supported hosts (Mac aarch64 / Linux x86_64
   / Windows x86_64), AND no workaround within the `naked`
   machinery is viable. Then a `.s`-file fallback ADR amendment
   lands, with per-arch `.s` files replacing the `.zig` ones 1:1.
2. The throw-site calling convention is restructured such that
   no special stack-frame discipline is needed at the
   trampoline boundary (e.g., a future redesign threads
   `ThrowSite` construction into the throw-site emit itself,
   bypassing the trampoline). This would obsolete the
   trampoline entirely, not just this ADR.

## References

- ROADMAP §10.E (EH implementation)
- ADR-0114 — Exception Handling design (D6 specifies the
  trampoline shape)
- ADR-0017 — X19/R15 pinned callee-saved invariant (the
  trampoline MUST honor these across the dispatcher CALL)
- ADR-0066 — Cross-module bridge thunk (different problem but
  similar stack-frame discipline pattern; cited for the
  "callee preserves caller's pinned-invariant regs" rationale)
- `.dev/phase10_eh_integration_plan.md` §IT-6 "Open questions
  for user collab" — the integration-plan flag that motivated
  this ADR
- `.dev/lessons/2026-05-26-eh-codegen-foundation-atom-rhythm.md`
  (`e62db476`) — the lesson that bundle mode now defends
  against; ADR-0118 D6 mandates load-bearing decisions be
  recorded before atom-rhythm work begins
- Zig 0.16 stdlib: `std.builtin.CallingConvention.naked`
- **Spike** `private/spikes/p10-it6-naked-trampoline/` —
  empirical validation of §Removal condition #1. All 3
  hosts (aarch64-macos / x86_64-linux-gnu / x86_64-windows-gnu)
  produce zero prologue + zero epilogue for a `callconv(.naked)`
  fn whose body is `asm volatile`. Spike Status:
  `merged-into-prod`; see README for per-host disassembly.

## Revision history

| Date       | SHA          | Note                                                          |
|------------|--------------|---------------------------------------------------------------|
| 2026-05-27 | `e725bce7`   | Initial Proposed.                                             |
| 2026-05-27 | `213df2f2` | Flipped to Accepted; spike validation added to References §. |
