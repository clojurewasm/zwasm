# D-163 cycle 12: Win64 caller-side bounds-check trap — JIT layout statically correct

> **Citing**: commit `<backfill>` (this commit). Spike:
> `private/spikes/d-163-win64-call-indirect-trap/`.

## What happened

Cycle 11 re-enabled per-function JIT hex dump (`[d-163-jit]`) and
cycle 12 ran the runner against `test/private/d-163/iso/call/`
(copy of `wasm-2.0-assert/call/`) on windowsmini. 78 funcs
dumped. 3 functions contain `JAE rel32` (0f 83) — the
caller-side bounds-check pattern: func54/55/56 (matching the
3 `as-call_indirect-{first,mid,last}` exports).

Decoded func56 (~223 bytes) via `ndisasm -b 64`:

- **Prologue**: `PUSH RBP; PUSH R15; MOV RBP,RSP; MOV R15,RCX
  (Win64); CMP RSP,[R15+0xE0]; JBE rel32→0xBC; MOV
  [R15+0x50],1; SUB RSP, 0x58` (88-byte frame).
- **Body** (offsets 0x25..0x88): marshalling, intra-call,
  bounds check (`MOV EAX,[R15+0x18]; CMP r10d,EAX; JAE
  rel32→0xA7`), sig check (`JNZ rel32→0xA7`), funcptr load.
- **Bounds-check trap stub at 0xA7**: `MOV [R15+0x28],1`
  (trap_flag); `XOR EAX,EAX`; **`ADD RSP, 0x58`**; `POP R15`;
  `POP RBP`; `RET`.
- **Stack-probe trap stub at 0xBC**: `INC [R15+0xE8]` (counter);
  `MOV [R15+0x28],1; MOV [R15+0x2C],4` (kind=4); no `ADD RSP`
  (probe fires before frame alloc per ADR-0105 D3); pop /
  ret.

## Static-layout hypothesis tests

- **H1 (ADD-RSP shadow-space mismatch)**: REJECTED — Prologue
  `SUB RSP, 0x58` exactly matches bounds-trap-stub `ADD RSP,
  0x58`. Win64 shadow space included in `frame_unaligned`
  (per emit.zig:241 `outgoing_max_bytes` term). No drift.
- **H3 (R15 ↔ entry_arg0_gpr pre-trap)**: REJECTED for
  static layout — R15 is set in prologue via `MOV R15,RCX`
  and never overwritten in the body. Bounds check fires
  with R15 still holding `*JitRuntime`. Trap stub's `MOV
  [R15+0x28],1` is safe.
- **H4 (alignment)**: REJECTED — frame_bytes 0x58 satisfies
  Win64 16-byte alignment invariant: entry RSP at mod-16 = 8,
  PUSH RBP → 0, PUSH R15 → 8, SUB RSP 0x58 → 0. ABI compliant.

## What this means

The crash (exit 1, ~5 sec on windowsmini when SKIP arm removed)
is **not in the JIT byte layout**. The static shape is byte-
identical to what would land for the same prologue + bounds
check on SysV (where the same shape PASSes). The bug is
elsewhere:

1. **Runtime invocation path** — the entry helper
   (`src/engine/codegen/shared/entry.zig`) calls the JIT body
   via inline-asm/extern. Could mis-handle the trap-stub
   return path on Win64.
2. **Trap recovery / VEH** — Win64 may dispatch the
   trap-flag write through Vectored Exception Handler
   differently than POSIX siglongjmp. Wasmtime's pattern
   (`UNWIND_INFO` + VEH context-rewrite) is the canonical
   Win64 trap recovery; zwasm v2 uses POSIX-shaped RET
   trap stubs without `.pdata`/`.xdata` — works on Win64
   callee-side traps but caller-side may interact differently
   with the Win64 exception unwinder when the trap stub
   "returns" to the entry helper.
3. **Some test artifact** — the 5-sec exit-1 framing suggests
   either a hang (5-sec timeout) or a process-level failure
   that takes time to surface. Could be an
   `EXCEPTION_STACK_OVERFLOW` raised between PUSH-R15 and
   SUB-RSP that crashes via the W4 retry-2 VEH filter path
   (`09ee5bb9` fixed one such case for D-162).

## Next probe (cycle 13)

Run the runner against the isolation directory WITHOUT the SKIP
arm — temporarily bypass the `call_indirect` check in
`spec_assert_runner_base.zig:3085`. Capture stderr + exit
code + timing. Compare with cycle-9 "exit 1, ~5 sec" report
to narrow runtime vs JIT root cause.

Companion: 2 NEW Win64 FAILs in same corpus
(`type-all-i32-i32`, `as-call-all-operands` returning garbage
i32 — pattern matches D-094/D-164 territory) need separate
triage; both return a 2-result tuple where the 1st i32 is
garbage 32-bit (0xB37D8FB7 / 0xB37D90DE-ish) while 2nd is
correct.

## Refs

- D-163 in `.dev/debt.md`.
- `private/spikes/d-163-win64-call-indirect-trap/README.md`
  H1-H5 hypothesis list — H1/H4 now strikethrough.
- `src/engine/codegen/x86_64/op_call.zig::emitCallIndirect`
  (caller side bounds check + trap stub fixup).
- `src/engine/codegen/x86_64/op_control.zig::emitEndInter`
  (trap stub emission, lines 1274-1325).
- `src/engine/codegen/shared/entry.zig` (Win64 entry helper
  paths — next probe target).
