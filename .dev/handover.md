# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `c8468551` — chore(p10): ADR-0122 D-193 ungate, Group A
  batch (entry_buffer_write ×7 + linker 689/789, 9 already-x86_64
  tests) (10.G cycle 45). Mac aarch64 `zig build test` exit 0 + lint
  clean. cycle 44 (`1b360b94`) verified green on Linux x86_64 (ubuntu
  `OK (HEAD=1b360b94)`). cycle 45 verification pending via ubuntu kick
  — Step 0.7 next cycle reads `/tmp/ubuntu.log`.
- **D-193 portable backlog CLEARED** (~23 → 3 over cycles 41/43/44/45).
  The 3 remaining are all category-(a) arm64-byte-pinned — real
  per-arch test work, not 3-min ungates.
- **ROADMAP §10 progress**: 7/13 DONE, 4 IN-PROGRESS, 2 Pending.
- **Active debt rows**: 18 — all `blocked-by:` with named structural
  barriers. Zero `now`-status rows.
- **No Active bundle** — D-193 ungate is per-cycle opportunistic
  triage (ADR-0122 D6), not a bundle.

## Active task — D-193 per-site ungate (ADR-0122 D6)

Discharging the Mac-aarch64-only test gates that hide Linux x86_64
coverage (D-180 hazard class). 3 category-(a) sites remain (see D-193
row). These are arm64-byte-pinned — ungating naively breaks x86_64
compile — so each needs an x86_64 sibling OR comptime byte-selection
+ SIBLING-AT comment per ADR-0122 D3 (real per-arch test code).

**NEXT chunk** — `jit_mem.zig` MOVZ-X0-#42 probe. The test allocs a
RWX page, writes `MOVZ X0,#42`+`RET` (arm64 machine code), execs, and
expects 42. The alloc+exec primitive (jit_mem) is portable; only the
4-byte instruction stream is arch-specific. Convert: comptime-select
the bytes — arm64 `{ MOVZ X0,#42; RET }` vs x86_64 `{ mov eax,42; ret }`
(`B8 2A 00 00 00 C3`) — keep the alloc/exec/result-check portable; add
a SIBLING-AT comment. Result delta: jit_mem exec primitive newly
covered on Linux x86_64. Verify byte encodings against ISA refs
(Arm IHI 0055 MOVZ + Intel SDM MOV imm32) before committing.

**Then** — `linker.zig` 610/650 (is_tail B/BL fixup patch). Needs a
Step 0 survey of `link()`'s per-arch fixup-patch dispatch (does it
patch x86_64 JMP/CALL rel32?) before writing x86_64 sibling tests.

After these 3, D-193 fully discharged → close the umbrella row.

## Larger §10 work (not started; bigger than per-cycle ungate)

- **10.TC JIT-side** — regalloc terminator-class extension
  (ADR-0113 §A) + `op_tail_call.zig` + `frame_teardown.zig` +
  `cross_module_tail_call.zig` + safepoint-free comptime assert.
  Interp trampoline already landed (D-187 `8f8a01ec`); JIT emit side
  is the remaining ROADMAP 10.TC scope. Bundle candidate.
- **10.G op_gc** — runtime substrate landed end-to-end (parse +
  side-tables + struct/array ops + β mark-sweep + root walker).
  Spec-corpus exercise is D-179-blocked (wabt 1.0.41+).
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (HEAD `96a17d5a`; unchanged by gate-only cycles)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(fail2) exception=4(fail4)
[function-references] invalid=12 (all pass)
```

EH 40 fails gated on the bigger 10.G/10.E work (D-192).

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.
- D-186 — `return_call_ref` blocked-by 10.R-3/4/5 (GC-gated).
- D-188 — 2 now (try_table.8 + try_table.10); blocked-by 10.E
  validator strictness (GC-gated via D-192).
- D-192 — EH runtime path blocked-by exnref ValType + cross-module
  register support (GC-gated).

## Key refs

- ADR-0122 (test skip categorization; D5 helper, D6 ungate review).
- ADR-0076 (D1 scope-adaptive gate, D2 single-push, D3 ubuntu kick).
- ADR-0113 §A/§B/§C (regalloc terminator/N-successor/stack-map axes).
- ROADMAP §10 rows 10.TC / 10.G; Phase log `.dev/phase_log/phase10.md`.
- Lessons: `.dev/lessons/INDEX.md` 2026-05-28 (x86_64-uses-runtime-ptr
  EH gap = D-180 root cause; the hazard class D-193 ungates verify).
