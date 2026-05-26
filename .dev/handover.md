# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)
- **10.D = CLOSED 2026-05-25**.
- **10.M sub-chunks 1..fixture-2 = SHIPPED**.
- **10.R sub-chunks 1..5 = SHIPPED**.
- **10.TC-1 = SHIPPED** (`a83e095f`).
- **10.G-i31-ops / 10.G-2 / 10.G-3 = SHIPPED**.
- **10.E interp side = COMPLETE**.
- **10.E codegen IT-1..IT-5 = SHIPPED** (`c3424788`, `2d938570`,
  `466674b7`, `5b75bee5`, `14fafdc6`).
- **10.E IT-6 prep SHIPPED**: frame_bytes thread (`9ac268f1`),
  landing_pad_pc forward fixup (`18b2a077`), ADR-0119 draft
  (`e725bce7`), spike-validated flip to Accepted (`213df2f2`).
- **10.E IT-6 cycle 3a SHIPPED** (`14b32f74` + `0d099a41`
  fix-forward): trampoline scaffolding under
  `shared/throw_trampoline.zig` (naked fn, trap-only body).
- **10.E IT-6 cycle 3b SHIPPED** (`7c7169ad`): `op_throw` /
  `op_throw_ref` retargeted (both archs) — JIT bytes now load
  the trampoline address and BLR/CALL into it before the
  trap-stub fallback B/JMP.
- **10.E IT-6 cycle 3c-i SHIPPED** (`73c163d4`): JitRuntime
  gains `eh_table_entries` + `eh_table_count` + `eh_code_map_entries`
  + `eh_code_map_count` (defaults null/0); setupRuntime wires
  from CompiledWasm.exception_table + module.code_map_entries.

## ROADMAP §10 progress

- DONE (7/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D
- IN-PROGRESS (4): 10.M (7/8) / 10.R (5/5; gated on 10.G) /
  10.TC (codegen + cross-module + spec corpus 残) /
  10.E (codegen IT-6 trampoline impl 残)
- Pending (3): 10.G / 10.P (close gate)

## Active bundle

- **Bundle-ID**: `10.E-codegen-IT-6`
- **Cycles-remaining**: `~2` (cycle 3c-ii blocked-by issues
  surfaced below + cycle 3c-iii final handler dispatch)
- **Continuity-memo**: 3c-i (JitRuntime fields + setup wire)
  shipped. Trampoline + retargeted throw sites + per-Instance
  EH data are all in place. **Cycle 3c-ii attempted 2026-05-28;
  WIP stashed** (`stash@{0}`: `wip-cycle-3c-ii-trampoline-body-
  asm-errors-and-zwasm-throw-test-failures`) pending resolution
  of two blockers:

  1. **ARM64 inline-asm operand syntax** — LLVM 21 inline-asm
     parser rejects `// foo` mid-line comments (works for
     x86_64 SysV but not aarch64). The trampoline-core split
     architecture (a `callconv(.c)` Zig fn called from a tiny
     naked stub via BLR/CALL) is sound; the issue is purely
     in the asm body's syntax. Resolution: strip ALL mid-line
     `//` from arm64 asm templates; comments live outside.
     The stash has partial cleanup; needs final fix-up.

  2. **Pre-existing `zwasm_throw.zig` test failures** — adding
     `@import("zwasm_throw.zig")` from `throw_trampoline.zig`
     brought 4 zwasm_throw tests into the test graph for the
     first time. Two of them fail:
     - `dispatchThrow: handler in caller frame after one
       unwind step` → expects `.handler`, gets `.uncaught`
     - `dispatchThrow: throw-site outside any JIT function
       → walks via sentinel` → same shape
     These are **latent bugs in the foundation chain** (the
     synthetic frame-chain walk doesn't yield the expected
     handler match). Resolution requires investigating the
     `unwind.walk` implementation against the test fixtures
     — may be a test-fixture issue OR a real unwinder bug.
     Bucket-2 territory; needs Step-0-survey of unwind.zig.
- **Exit-condition**: end-to-end `throw 0 / catch_all 0` fixture
  compiles + runs + lands at the catch block (per integration
  plan §IT-6 acceptance).

Next /continue resume picks up **cycle 3c — dispatchThrow
integration in trampoline body** per ADR-0114 D6:

1. Capture caller FP (X29 / RBP) + saved-LR/RIP into a
   `ThrowSite` record on the trampoline's stack.
2. Marshal arg(s) for `shared/zwasm_throw.dispatchThrow(table,
   code_map, throw_site, max_depth)`. `table` + `code_map` are
   per-Instance — read from `Runtime.exception_table` +
   `Runtime.code_map` (new JitRuntime fields; cycle 3c also
   plumbs them via instantiate).
3. CALL dispatchThrow (Zig fn, C ABI). UnwindResult is likely
   indirect-result (X8 / RDI hidden arg) due to size > 16 bytes.
4. Branch on result.tag:
   - `.handler`: `sp_restore.emitSpRestoreFull` (uses
     CodeMap.Entry.frame_bytes from IT-6 prep) + BR/JMP to
     `landing_pad_pc` (resolved by IT-6 prep landing_pad fixup,
     module-relative via IT-5 collection).
   - `.uncaught`: keep current trap_flag=1 path; RET to caller
     (which still B/JMPs to its trap stub via the cycle-3b
     fallback).

Open question for cycle 3c: tag_idx marshalling. The throw site
needs to pass `ins.payload` (tag_idx) to the trampoline. Cycle
3b doesn't yet marshal it; the trampoline's signature must
accept it via a fixed argreg (X0 on arm64 / RDI on x86_64, per
the dispatcher entry convention). op_throw.emit at cycle 3c
prepends a tag_idx load to the address-load + BLR/CALL.

## Open questions / blockers

- 10.G-4 (struct ops) — blocked-by GC heap impl
- 10.M-realworld — toolchain-blocked (clang_wasm64 fixture)
- 10.P close gate — user touchpoint by construction

## Key refs

- **ADR-0119 Accepted** (`213df2f2`,
  `.dev/decisions/0119_eh_trampoline_naked_zig.md`)
- **Spike** `private/spikes/p10-it6-naked-trampoline/` —
  Status: merged-into-prod (zero-prologue empirical evidence,
  per-host disasm in README)
- **Integration plan** (`.dev/phase10_eh_integration_plan.md`)
- **ADR-0114** (EH design — D6 specifies the trampoline shape)
- **ROADMAP §10**
- **Phase log** (`.dev/phase_log/phase10.md`)
- **Lesson** `2026-05-26-eh-codegen-foundation-atom-rhythm.md`
  (`e62db476`)
