---
name: gamma3d-dispatch-write-segv-bisect
description: γ-3.d bisect on imports/imports.1 SEGV — handover prediction (spectest table/memory/global binding gap) refuted; the actual gap is a dispatch-write-triggered SEGV that sigsetjmp arming around on_module_loaded fails to catch
metadata:
  type: lesson
---

# Gamma-3.d imports.1 SEGV bisect — handover prediction refuted

`Citing:` `<backfill>` — refresh after the next γ-3.d landing commit.

## What the handover predicted

Pre-session handover described γ-3.d as "spectest table/memory/
global binding gap — currently `hasUnbindableImports` trips on
`.table/.memory/.global => return true`". Implication: imports.1
fails because it has non-func imports that aren't yet backed.

## What live evidence showed

Running with a temporary `hasUnbindableImports` relaxation (allow
non-spectest func imports whose module is `registered`) reproduces
the SEGV deterministically at `imports/imports.1.wasm` per the
existing in-handler `[γ-4 DIAG]` trace.

`wasm-objdump -x imports.1.wasm` shows the actual shape:

- 18 imports, **all of `.func` kind** — 14 are `spectest.print_*`
  (handled by `hostImportTrapStub`), 1 is
  `test.func-i64->i64` (the registered alias from imports.0), 3
  more spectest funcs.
- 0 table/memory/global imports.

Therefore the "spectest table/memory/global binding gap" narrative
was the wrong hypothesis. imports.1's only non-spectest import is
the registered func, which γ-3.b/β-2b's bridge thunk path covers.

## Bisect inside `resolveCrossModuleImports`

Three probe configurations against the same source layout:

1. **Skip resolver entirely** → exit 1 (no SEGV). Many fixtures
   regress functionally (the relaxation propagates) but the SEGV
   is absent.
2. **Call `entry_ptr.ensureCompiledAndRt` for `test` only** → no
   SEGV (exit 1).
3. **ensure + `jit_mem.setWritable(arena)` + `emitThunk(slot, ...)`
   without dispatch write** → no SEGV (exit 1).
4. **Add `new_dispatch[10] = @intFromPtr(slot.ptr)`** → SEGV
   reproduces (exit 142, "[γ-4 DIAG] SEGV after .module
   imports/imports.1.wasm").

The single offending operation is the heap write of the bridge
thunk address into the dispatch slot. The dispatch slice was
allocated as `gpa.alloc(usize, 18)`; the write at index 10 is in
bounds and to writable heap memory. Yet the next instruction
(`callbacks.on_module_loaded(gpa, wasm_bytes, &compiled, stdout,
name)`) does not enter the function body — the very first
statement (a raw `write(2, msg, len)` via `extern "c" fn write`)
does not produce output before the signal handler fires.

The vtable's function pointer load was verified at the call site
(`callbacks.on_module_loaded` printed `0x1048ef3b0`, a plausible
.text address). Bracketing the call with a per-iteration
`sigsetjmp` arm + `sigsegv_armed.store(true)` did **NOT** catch
the SEGV — the sigsegvHandler took the unarmed branch and ran
`_exit(142)`. This last fact is the load-bearing surprise: the
existing arming pattern (mirrored from
`spec_assert_runner_non_simd.zig::nonSimdOnModuleLoaded`'s start-
fn block, lines 265–276) is supposed to be the recovery
mechanism, and it failed on this specific call site.

## Hypotheses to pursue next

1. ~~**Mac aarch64 Pointer Authentication (PAC)**~~ — **REJECTED
   2026-05-17 commit `11bb5d76`** via `otool -tv` on the Debug
   binary: zero `blraa`/`blrab`/`blra ` instructions emitted.
   PAC is not active for the indirect call site that's SEGVing.
2. ~~**siglongjmp restore-to-fork / re-entry race**~~ —
   **REJECTED 2026-05-17** by the handler-entry counter probe.
   Permanent infra added (`sigsegv_handler_entry_count`,
   `sigsegv_last_armed_entry`, `formatU32Decimal` helper); the
   unarmed trace now formats `(handler-entry=N last-armed=M)`.
   Empirical run shows armed entries #7-13 ALL occurred in
   `skip-stack-guard-page/skip-stack-guard-page.0.wasm` (the
   stack-overflow recovery fixture); between #13 and #14
   (the imports.1 unarmed entry) MANY corpus directives ran
   without firing the handler at all (assert_traps caught via
   JIT-detected `Error.Trap`, no SIGSEGV needed). The unarmed
   imports.1 SEGV is a **fresh, unrecovered fault** — handler
   entered with sigsegv_armed=false (correctly cleared by all
   prior recoveries), siglongjmp re-entry is not the cause.
3. ~~**Altstack interaction / stack-guard hit**~~ —
   **REJECTED 2026-05-17** by SA_SIGINFO upgrade. The fault
   address captured via `siginfo.addr` is `0xaaaaaaaaaaaaaab2`
   — Zig's `0xAA` poison pattern for uninitialised memory.
   Not a stack-guard hit (would be in the SP-vs-guard range)
   and not a MAP_JIT range (those are at 0x10x... in our
   observations).
4. ~~**Layout-coincidence**~~ — implicitly **REJECTED**: the
   fault address pattern rules out the dispatch-heap or
   `callbacks` stack overlap explanation.
5. ~~**BLR target near MAP_JIT flip**~~ — **REJECTED**: same
   reasoning — fault address is poison, not text/MAP_JIT.

**ROOT CAUSE IDENTIFIED (2026-05-17 cycle 6)**: the cross-
module bridge thunk corrupts X19 (= `runtime_ptr_save_gpr`)
across the call boundary. Two interacting bugs:

1. **Callee prologue overwrites X19 without saving**. v2's
   arm64 prologue (per `arm64/prologue.zig` "Word 7: ORR X19,
   XZR, X0") unconditionally writes `MOV X19, X0` without
   first saving the caller's X19 value. AAPCS64 §6.4.1
   designates X19 as **callee-saved** — the callee MUST
   preserve it. For SAME-module calls this is invisible
   because both caller and callee use the same `rt` value in
   X19. For cross-module calls the callee_rt ≠ caller_rt
   and X19 ends up holding the wrong rt after the call
   returns.
2. **`RegisteredExporter.ensureCompiledAndRt` initialises
   the callee's rt with `host_dispatch_base = undefined`**
   (literally `.host_dispatch_base = undefined,` in the
   struct init). Zig fills `undefined` with `0xAA` bytes in
   Debug — so the callee_rt's host_dispatch_base = `0xAA...AA`.

The combined failure mode: when print64 (in imports.1) does
`call 10 <test.func-i64->i64>` via the bridge thunk, the
callee swaps X0 → callee_rt and runs its prologue which
overwrites X19 = callee_rt = imports.0's rt. The callee
returns; the importer's next `call N` (e.g. `call 1
<spectest.print_i64>`) emits `LDR X16, [X19, #host_dispatch_
base_off]` → loads imports.0's `host_dispatch_base = 0xAA`
poison. Then `LDR X16, [X16, #(1*8)]` faults at `0xAA + 8 =
0xB2` — **exactly the captured fault address**.

Diagnostic chain that proved this:
- SA_SIGINFO fault-address: `0xaaaaaaaaaaaaaab2` = `0xAA × 7 + 0xB2`.
- Byte-dump probe at call site: all `callbacks` (40 bytes) +
  `gpa` + `wasm_bytes` + `compiled` + `name` values valid;
  no `0xAA` in args.
- Body probes in `nonSimdOnModuleLoaded`: function returns
  cleanly through all 6 steps (memory limits + data init +
  globals init + table init + multi-table + patch table
  import funcptrs + extractStartFunc=null).
- Body probes in runCorpus loop: `.assert_return print32`
  passed; `.assert_return print64` entered → SEGV inside
  `handle_assert_return` (JIT execution of print64).
- Thunk-byte probe at resolver: thunk bytes correct (ADR/
  LDR/LDR/BR + 2 literals); callee_rt = `0x111a61d00`
  valid; callee_entry = `0x108df8164` valid; callee_rt's
  first 64 bytes show vm_base/mem_limit/funcptr_base all
  valid heap pointers — but `host_dispatch_base` (at offset
  beyond the 64 bytes dumped) is the `undefined` field.

## Fix design (next session)

The fix needs to be coordinated across two layers:

- **Bridge thunk** (`arm64/thunk.zig`): change from
  tail-jump (BR X16) to call-and-return: save caller's X19
  on stack, BL callee, restore X19, RET. Doubles the thunk
  size from 32 to ~48 bytes. ADR-0066 amendment required.
- **`ensureCompiledAndRt`**: stop using `undefined` for
  `host_dispatch_base` (and any other `undefined` field —
  audit the full struct init). Either point at a one-entry
  stub array containing `hostImportTrapStub`, or `@ptrCast`
  a stable zero/null sentinel.

Both fixes are independently structurally correct. The
bridge-thunk fix is load-bearing for ABI correctness; the
`ensureCompiledAndRt` fix removes the poison that surfaced
the bug + is good hygiene regardless.

## Steps the next investigator should take

1. ~~Run **on ubuntunote (Linux x86_64)** with the same probe
   patch.~~ **DONE 2026-05-17**: ubuntunote runs the same
   source cleanly to **25196 passed / 112 failed / 705
   skipped** (exit 1, no SEGV). The 112 FAILs are functional
   cross-module-callee-state gaps (table_copy 65 / table_init
   39 / ref_func 6), exactly the γ-1/γ-2/γ-3 per-exporter
   backing scope. **The SEGV is Mac-aarch64 specific** (filed
   as D-142). The bridge thunk mechanism + dispatch wiring
   are structurally sound on Linux x86_64.
2. Run **with `lldb`** to capture the actual fault address +
   PC at the SEGV (requires SIP workaround on Mac; or
   alternatively use `LLDB_FREE_ROOT_CONFIG` / `csrutil`).
3. Add a `printf` of the dispatch SLICE before AND after the
   write (read it back), and the on_module_loaded function-
   pointer slot's bytes, to verify nothing else mutated.
4. **Operational consequence** (drives the loop's next picks):
   γ-1/γ-2/γ-3 (per-exporter globals/memory/table backing)
   are independently landable as behavior-neutral preparation
   (no fixture exercises them until γ-4's permanent
   `hasUnbindableImports` relaxation, which itself is gated
   on D-142 closure). The autonomous loop should proceed with
   γ-1 while D-142 stays open.

## Why this lesson matters

This case is a worked example of why
[`no_handover_predictions.md`](../../.claude/rules/no_handover_predictions.md)
exists: the prior handover stated a confident-sounding hypothesis
that DID NOT match `wasm-objdump`'s actual imports.1 shape, and
the autonomous loop nearly committed work matching that wrong
hypothesis. Live measurement (wasm-objdump + DIAG probes) was
required to discover the actual gap.

It is also a worked example of why **sigsetjmp arming is not a
universal recovery primitive on Mac aarch64**: the existing
spec-assert-runner pattern fails to catch this particular SEGV.
Future γ work that depends on SEGV-recoverable cross-module
state-touching cannot assume sigsetjmp + armed handler will save
the runner.
