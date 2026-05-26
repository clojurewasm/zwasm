# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `36a53773` — 10.E-payload-prop Cycles 1+2 shipped
  (Runtime.eh_payload_buf @ `d27c6857`; JitRuntime.eh_payload_buf
  + offset constants @ `36a53773`). Mac local green; ubuntu @
  `327082b5` green; cycle 2 ubuntu verify pending next Step 0.7.
- **10.D = CLOSED 2026-05-25**, **10.M (incl D-181 ungate),
  10.R 1..5, 10.TC-1, 10.G-i31-ops/2/3, 10.E (IT-1..IT-6 codegen
  foundation + interp catch_/catch_all dispatch + tag-equality)**:
  SHIPPED.
- **D-181 = CLOSED `f37977df`** — memory64 i64-idx runner test
  ungated for x86_64 SysV; ubuntu verified @ HEAD `228d2d79`.
- **D-180 structural defenses SHIPPED** (`2808bc81` + `a98c7b1f`):
  x86_64 `usesRuntimePtr` whitelist drift detector +
  `test_discipline.md` §4 (host-only gates pair with debt row OR
  spec-pinned rationale) + lesson
  `2026-05-28-x86_64-uses-runtime-ptr-eh-gap.md`.

## Active bundle

- **Bundle-ID**: 10.E-payload-prop
- **Cycles-remaining**: ~3 (Cycles 1+2 shipped: `d27c6857`, `36a53773`)
- **Continuity-memo**: payload propagation through
  `Runtime.eh_payload_buf: [16]u64` + `EmitCtx.tag_param_counts:
  []const u32 = &.{}` threading per ADR-0120. Throw emits
  pop-N+store-to-buf; try_table.emit synthesizes landing-pad
  load-from-buf+push. v128/exnref tag params deferred to v0.2.
- **Exit-condition**: `runI32Export: throw + catch_ with i32
  payload returns 88` test passes on Mac aarch64 + Linux x86_64
  SysV (currently silent-drops, returns 0; probe verified this
  cycle).

## ROADMAP §10 progress

- DONE (8/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D /
  10.E (foundation; bundle 10.E-payload-prop completes scope).
- IN-PROGRESS (3): 10.M (D-181 closed; realworld toolchain-blocked) /
  10.R (5/5; gated on 10.G) / 10.TC.
- Pending (2): 10.G / 10.P (close gate).

## Active task — Cycle 3 of 10.E-payload-prop bundle

Cycle 1 (`d27c6857`): Runtime fields. Cycle 2 (`36a53773`):
JitRuntime fields + `eh_payload_buf_off` / `eh_payload_len_off`
constants + offset/size tests.

**NEXT (Cycle 3)** — EmitCtx threading + throw.emit writes:
- Add `tag_param_counts: []const u32 = &.{}` to per-arch EmitCtx
  (arm64 + x86_64 ctx.zig) + InitArgs (x86_64) with default.
- Thread through emit.compile + shared/compile.zig::compileOne +
  engine/compile.zig (existing tag_param_counts var). Update
  ~20 emit.compile test sites with `&.{}` default at new position.
- throw.emit on both arches: read N = `ctx.tag_param_counts[tag_idx]`
  at emit time; emit byte sequence that pops N vregs from
  `pushed_vregs` and stores each at `[runtime_ptr +
  eh_payload_buf_off + i*8]`; write N to `[runtime_ptr +
  eh_payload_len_off]`. Existing tag_idx marshal into W0/RDI
  preserved. NB: payload-buf base offset exceeds u12 imm12
  budget — emit will need a 2-instr address synthesis (MOVZ +
  ADD or LEA-equivalent) per arch.
- Same-cycle observable test: existing `throw $e1 → catch $e1
  returns 77` still green (N=0 tags pay zero extra cost beyond
  the eh_payload_len = 0 store).

## Next candidates (after bundle close)

- **10.TC codegen** — return_call / return_call_indirect /
  return_call_ref JIT emit + frame_teardown helper. ADR-0112 +
  ADR-0113 §A foundations already shipped.
- **10.TC interp end-to-end runner test** — 10.TC-1 + 10.TC-1b
  shipped; e2e runI32Export-shape test would catch regressions
  before JIT codegen lands.
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted. Loop
  proceeds with the Proposed design; user can intervene at any
  cycle boundary.
- 10.G-4 (struct ops) — blocked-by GC heap impl.
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0114 D1/D6 (EH design + zwasm_throw trampoline),
  ADR-0119 (naked-Zig trampoline), ADR-0120 (Proposed; this
  bundle's design).
- Integration plan `.dev/phase10_eh_integration_plan.md` §IT-3
  (now superseded by ADR-0120 for marshalling shape).
- ROADMAP §10, Phase log `.dev/phase_log/phase10.md`.
- Lessons (Phase 10 EH cycle):
  - `2026-05-26-eh-codegen-foundation-atom-rhythm.md` (`e62db476`)
  - `2026-05-28-eh-test-wrapper-host-fp-walk-segv.md`
  - `2026-05-28-x86_64-uses-runtime-ptr-eh-gap.md`
