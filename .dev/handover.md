# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` — read the **Phase Status** widget at the top
   of §9 to find the IN-PROGRESS phase, then its expanded `§9.<N>`
   task list; pick up the first `[ ]` task.
3. The most recent `.dev/decisions/NNNN_*.md` ADR (if any) — to
   recover load-bearing deviations in flight.

## Current state

- **Phase**: **Phase 7 IN-PROGRESS** (JIT v1 ARM64 baseline).
- **Last commit**: `a6bf0e7` — §9.7 / 7.1 land: greedy-local
  regalloc + verify post-condition. 7 tests cover empty / 3-deep
  / 2-deep binop / 4-deep stack / verify rejects (overlap forced
  share, slot index too high, length mismatch). Strict `<` use-
  edge overlap; LSRA convention.
- **Next task**: §9.7 / 7.2 — `src/jit_arm64/{inst,abi}.zig`
  (ARM64 instruction encoder + AAPCS64 calling convention layout).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.7 / 7.2 (jit_arm64 inst + abi)

Per ROADMAP §9.7 exit criterion: `src/jit_arm64/{emit,inst,abi}.zig`
produce AAPCS64-correct function bodies. 7.2 splits off the
encoder / ABI layer; 7.3 wires the emit pass to consume them.

Phase-7 / 7.2 scope:

- `src/jit_arm64/inst.zig` — minimum ARM64 instruction encoder
  covering the ops the §9.7 / 7.3 emit will need: register
  arithmetic (ADD/SUB/MUL), comparison (CMP/CSET), branches
  (B/BL/BR/RET), loads/stores (LDR/STR), MOV imm, MOV reg→reg.
  Each emitter returns a `u32` (ARM64 fixed-width insn).
- `src/jit_arm64/abi.zig` — AAPCS64 register inventory: which
  X-registers are caller-saved vs callee-saved, which X-regs
  carry args 0..7, which is the platform reg / link reg / SP /
  FP. Maps regalloc slot ids → ARM64 Xn (consumed by 7.3).

Plan:

1. Survey AAPCS64 (Arm-supplied PDF) + cranelift's
   `cranelift/codegen/src/isa/aarch64/inst/emit.rs` for the
   encoder shape — mandatory per `textbook_survey.md` Guard 4
   (regalloc / per-arch emit). Output to
   `private/notes/p7-7.2-survey.md`.
2. `inst.zig` — per-mnemonic `pub fn enc<MNEMONIC>(rd, rn, rm,
   imm) u32` with bit-pattern unit tests verifying each emit
   matches the AAPCS64 encoding spec (and llvm-objdump -d's
   disassembly when feasible).
3. `abi.zig` — declarative tables: `caller_saved_gprs`,
   `callee_saved_gprs`, `arg_gprs[0..8]`, `link_register`,
   `frame_pointer`, `stack_pointer`. Plus a
   `pub fn slotToReg(class, slot_id) Xn` mapper that the 7.3
   emit pass consumes.
4. Tests: bit-pattern for at least one of each instruction
   family; ABI table covers every register in the AAPCS64 spec.
5. Three-host `zig build test-all`.

Note: ARM64 instructions are little-endian fixed-width 32-bit;
encoder tests validate each `u32` value against either the AAPCS
spec or a known-good llvm-mc output. Mac aarch64 is the natural
host for cross-checking via `llvm-mc -triple=aarch64 -show-encoding`.

Phase-7 outstanding (post 7.2): 7.3 emit / 7.4 spec test JIT /
7.5 40+ realworld JIT / 7.6 `interp == jit_arm64` differential /
7.7 wasmtime stdout (ADR-0010) / 7.8 ClojureWasm (ADR-0010) /
7.9 boundary audit / 7.10 phase tracker.

Carry-overs queued:
- §9.5: `no_hidden_allocations` zlinter (ADR-0009); validator.zig
  per-feature split (with §9.1 / 1.7); liveness control-flow +
  memory-op coverage; const-prop per-block (Phase-15);
  `sections.zig` (1073) soft-cap split.
- §9.6: `br-table-fuzzbug` multi-param `loop`; 10 SKIP-VALIDATOR
  realworld; 39 trap-mid-exec fixtures.

## Outstanding spec gaps (queued for Phase 6 — v1 conformance)

These were surfaced during Phases 2–4 and deferred from their own
phase. Phase 6 (ADR-0008) absorbs them as part of the v1
conformance baseline; do NOT re-pick during Phase 5.

- **multivalue blocks (multi-param)**: `BlockType` needs to carry
  both params + results; `pushFrame` must consume params (Phase 2
  chunk 3b carry-over).
- **element-section forms 2 / 4-7**: explicit-tableidx and
  expression-list variants (Phase 2 chunk 5d-3).
- **ref.func declaration-scope**: §5.4.1.4 strict declaration-
  scope check (Phase 2 chunk 5e).
- **Wasm-2.0 corpus expansion**: 47 of 97 upstream `.wast` files
  deferred (block / loop / if 1-5, global 24, data 20, ref_*,
  return_call*) — each surfaces a specific validator gap.

## Open questions / blockers

(none — push to `origin/zwasm-from-scratch` is autonomous inside
the `/continue` loop per the skill's "Push policy"; no user
approval required.)
