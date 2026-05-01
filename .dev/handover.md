# Session handover

> Read this at session start. Update at session end (1–2 lines).
> Mutable, current-state only. Authoritative plan is `.dev/ROADMAP.md`.
> Future-Claude reads this in a fresh context window and must
> understand the state in < 30 seconds.

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` — read the **Phase Status** widget at the top
   of §9 to find the IN-PROGRESS phase, then its expanded `§9.<N>`
   task list; pick up the first `[ ]` task.
3. The most recent `.dev/decisions/NNNN_*.md` ADR (if any) — to
   recover load-bearing deviations in flight.

## Current state

- **Phase**: **Phase 2 IN-PROGRESS.** Phases 0 + 1 are `DONE`.
  §9.2 / 2.0 (`243d9ba`), 2.1 (`f292ae7`), 2.2 (`575fbec`) are
  `[x]`. The full MVP interp handler set is wired across
  `src/interp/mvp.zig` + `src/interp/memory_ops.zig`. **§9.2 /
  2.3 IN-PROGRESS** — chunks 1 (sign-ext @ `32f09dc`), 2
  (sat-trunc @ `f21c972`), 3 (multivalue multi-result blocks @
  `c230237`), 4 (bulk memory copy/fill @ `98ea730`), 4b (data
  section + memory.init / data.drop @ `8727fdf`), and 5
  (ref.null / ref.is_null / ref.func @ `caef4e9`), 5b
  (select_typed @ `48b3ce2`), 5c (table.get/set/size @
  `47a1905`), 5c-2 (table.grow/fill @ `fb22f72`), 5d-1
  (table.copy @ `c4397e7`), and 5d-2 (element section +
  table.init / elem.drop @ `4cd91af`) are landed. **§9.2 / 2.3
  is now [x]** and **§9.2 / 2.4 (trap semantics) closed at
  `589a478`** — call_indirect now routes through the runtime
  table model with proper UninitializedElement /
  IndirectCallTypeMismatch traps + sig-equality check; trap
  audit tests in new `src/interp/trap_audit.zig`. Runtime gains
  `module_types: []const FuncType` slot. **§9.2 / 2.5 (leak-check
  clean) closed at `e438b3c`** — Zig's `b.addTest` injects
  `std.testing.allocator` (GPA leak-detector) by default; the
  332-test suite reports zero leaks on all three hosts. **§9.2 /
  2.6 (realworld smoke) closed at `1246d60`** — 7 toolchain
  fixtures (C/C++/Rust/TinyGo) parse cleanly through the
  frontend; new `test-realworld` build step + wired into
  `test-all`. **§9.2 / 2.7 (wast directive runner + initial
  Wasm 2.0 corpus) closed at `6d87ee5`** — new
  `test/spec/wast_runner.zig` consumes per-corpus
  `manifest.txt` files (valid / invalid / malformed); initial
  `test/spec/wasm-2.0/const/` fixture green; corpus expansion
  is queued for §9.2 / 2.8. **§9.2 / 2.8 IN-PROGRESS** —
  chunk 1 (`49e6e48`) added decodeTables; chunk 2 (`6553a03`)
  added `regen_test_data_2_0.sh` and curated 13 .wast files
  into the wasm-2.0 corpus; chunk 3 (`aac8bca`) added 8 more
  (address, endianness, int_exprs, comments, type, store,
  load, names) — **663 modules across 21 corpora, fail=0**
  across all three hosts. Deferred corpora (block / loop /
  if / global / i32 / i64 / f32 / f64 / memory / data / elem /
  table / ref_*) surface validator gaps to be closed in
  subsequent chunks.
  validateFunction takes `tables: []const zir.TableEntry`;
  Runtime carries `tables: []TableInstance` (mutable, so grow
  can swap refs slice headers).
  `validateFunction` signature now takes `data_count: u32`;
  `Runtime` carries `datas` + `data_dropped`; `Value` carries
  `ref: u64` + `null_ref` sentinel.
- **Branch**: `zwasm-from-scratch` (long-lived; v1 charter-derived,
  pushed to `origin/zwasm-from-scratch`).
- **ADRs filed**: none. Founding decisions live in ROADMAP §1–§14.
  ADRs come into existence only when a deviation from ROADMAP is
  discovered during development (per §18).
- **Build status**: `zig build` and `zig build test` are green on
  Mac aarch64 native, OrbStack Ubuntu x86_64 (`my-ubuntu-amd64`),
  and `windowsmini` SSH. Three-host gate is live; Phase 1 has no
  🔒 boundary gate (interpreter not yet wired) — see §9 / Phase 1.
- **`windowsmini` layout**: cloned at
  `~/Documents/MyProducts/zwasm_from_scratch` (mirrors v1).
  `origin` = `git@github.com:clojurewasm/zwasm.git`, branch
  `zwasm-from-scratch`. `scripts/run_remote_windows.sh` syncs via
  `git fetch + reset --hard origin/zwasm-from-scratch` (rsync was
  the original draft; Windows mini PC has no rsync, so v2 reuses
  v1's git-pull discipline).

## Active task — §9.2 / 2.3 (Wasm 2.0 features)

§9.2 / 2.2 closed at `575fbec`. The full MVP interp handler set
spans `src/interp/mvp.zig` (1883 lines) + `src/interp/memory_ops.zig`
(347 lines). All Wasm 1.0 opcodes the validator + lowerer cover
are now executable through `dispatch.run`. Recursive `call`
works; `call_indirect` indexes `rt.funcs` (proper element-section
table population is a follow-up — see chunk-7 commit notes).

§9.2 / 2.3 progress (Wasm 2.0 features, multi-chunk):
- chunk 1 (sign-ext 0xC0..0xC4) — landed at `32f09dc`. New
  `src/interp/ext_2_0/sign_ext.zig` (Zone 2) wires the five
  `iN.extend{8,16,32}_s` interp handlers; validator + lowerer
  extended with 0xC0..0xC4 cases.
- chunk 2 (sat-trunc 0xFC 0..7) — landed at `f21c972`. New
  `src/interp/ext_2_0/sat_trunc.zig` wires the eight
  `iN.trunc_sat_fM_{s,u}` handlers via shared
  satTruncSigned/Unsigned helpers (NaN→0, ±inf→MAX/MIN,
  truncate-toward-zero otherwise). Validator + lowerer now
  decode the 0xFC prefix uleb32 sub-opcode; unknown sub-ops
  return NotImplemented (reserved for chunks 4+).
- chunk 3 (multivalue multi-result blocks) — landed at
  `c230237`. Validator + lowerer's `readBlockType` /
  `readBlockArity` now decode s33 typeidx; multi-param blocks
  return BadBlockType (deferred). Block instr `extra` switched
  from raw blocktype byte → arity (#results). Interp
  `restoreToLabel` and `returnOp` now handle arity > 1 via a
  16-slot stack-local buffer.
- chunk 4 (bulk memory: memory.copy / memory.fill) — landed at
  `98ea730`. New `src/interp/ext_2_0/bulk_memory.zig` wires the
  two handlers; memory.copy implements memmove (forward /
  backward picked by overlap direction). Validator + lowerer's
  0xFC sub 10/11 dispatch checks reserved bytes are 0x00.
- chunk 4b (data section + memory.init / data.drop) — landed at
  `8727fdf`. sections.zig gains DataKind/DataSegment/decodeData
  (active forms 0+2, passive form 1). Runtime carries
  `datas: []const []const u8` + `data_dropped: []bool` slots.
  validateFunction takes a new `data_count: u32` parameter so
  0xFC 8/9 can bounds-check dataidx; lowerer emits dataidx as
  payload. Interp memoryInit handles dropped semantics
  (segment treated as empty after drop, n=0 still succeeds).
- chunk 5 (ref.null / ref.is_null / ref.func) — landed at
  `caef4e9`. Foundational ref-type opcodes; `Value.ref` view +
  `null_ref` sentinel. Validator gains BadValType + popAny for
  polymorphic ref.is_null typing. ref.func validates funcidx in
  `func_types` but not the §5.4.1.4 declaration-scope check
  (deferred to chunk 5d).
- chunk 5b (select_typed) — landed at `48b3ce2`. 0x1C count
  valtype*; count restricted to 1 (multi-result form deferred).
  Runtime semantics share the existing selectOp handler; only
  the validator+lowerer parsing surface changes.
- chunk 5c (table.get / table.set / table.size) — landed at
  `47a1905`. New zir.TableEntry + interp.TableInstance; tables
  borrowed by Runtime (runner owns the refs slices).
- chunk 5c-2 (table.grow / table.fill) — landed at `fb22f72`.
  Runtime.tables switched to mutable so grow can update each
  TableInstance's refs slice header via realloc. table.grow
  pushes prev_size or -1 on max-cap / alloc failure; fill
  traps OutOfBoundsTableAccess on dst+n > len.
- chunk 5d-1 (table.copy) — landed at `c4397e7`. memmove
  semantics on self-overlap; validator enforces matching
  elem_type between dst and src tables. Encoding stores
  dst-tableidx in payload, src-tableidx in extra.
- chunk 5d-2 (element section + table.init / elem.drop) —
  landed at `4cd91af`. New ElementKind/ElementSegment +
  decodeElement (forms 0/1/3 funcref-via-funcidx-list). Runtime
  carries `elems: []const []const Value` + `elem_dropped`
  parallel array. validateFunction takes `elem_count: u32`.

§9.2 / 2.3 is now [x]. Deferred follow-ups (queued, not
blockers):
- chunk 3b — multi-param multivalue blocks. Needs BlockType to
  track params + results separately and pushFrame to consume
  params from operand stack.
- chunk 5d-3 — element-section forms 2/4-7 (explicit-tableidx
  and expression-list variants). Required when spec corpus
  modules use them.
- chunk 5e — ref.func §5.4.1.4 strict declaration-scope check
  (allowed only if x is exported, in a global, or appears in a
  declarative element segment).
- chunk 3b (deferred) — multi-param multivalue blocks. Needs
  BlockType to track params + results separately and pushFrame
  to consume params from operand stack.

§9.2 / 2.3 lands the **Wasm 2.0 feature additions** that the
upstream spec corpus exercises:

- Sign extension (`i32.extend8_s` / `i32.extend16_s` / 
  `i64.extend{8,16,32}_s`) — opcodes 0xC0..0xC4. Each pops the
  source ValType, sign-extends from the lower N bits, pushes
  back the same ValType.
- Saturating truncation (`i*.trunc_sat_*`) — prefix opcode 0xFC
  followed by a sub-opcode. Spec semantics: clamp NaN → 0,
  out-of-range → INT_MAX or INT_MIN. NO trap (vs the regular
  trunc_*).
- Multivalue blocks (block-type as s33 typeidx in
  `readBlockType`). Validator extension: read s33; if positive,
  resolve via `module_types`. Interp + lowerer extensions
  follow.
- Bulk memory (`memory.copy`, `memory.fill`, `memory.init`,
  `data.drop`, `table.copy`, `table.init`, `elem.drop`) —
  prefix 0xFC sub-opcodes. Element / data section decoders also
  needed.
- Reference types (`ref.null`, `ref.is_null`, `ref.func`,
  `table.get`, `table.set`, `table.size`, `table.grow`,
  `table.fill`, `select_typed`).

These are best landed per feature module under
`src/interp/ext_2_0/<feature>.zig` (Zone 2 — same engine-side
split as chunk 5 memory_ops). Each feature module exposes its
own `register(*DispatchTable)` and registers handlers for its
opcodes only. The aggregator in `mvp.zig` (or a new
`src/interp/all_ops.zig`) calls each feature's register.

Step 0 (Survey) for 2.3: zwasm v1's `feature/ext_2_0/` if it
exists; wasm-tools `wasmparser`'s sat-trunc and reftype
handlers; spec docs for §3.3 (Wasm 2.0 typing) + §6.2.5
(numeric extras). Cite ROADMAP §4.5 (per-feature module split)
+ §A12 (no pervasive `if` for feature gating).

§9.2 / 2.2 lands across multiple chunks. Progress so far on top
of `f292ae7` (2.1 close):

1. `ead0fe3` — chunk-1: i32 numeric (15 binops + 10 relops + 3
   unops + eqz) + consts (4) + drop + locals + globals.
2. `0558114` — chunk-2: i64 numeric (mirror of i32; 15+10+3+1).
3. `3ddb61c` — chunk-3: f32 / f64 numeric (6 relops + 7 unops +
   7 binops per width). NaN propagation explicit on min/max;
   strict canonical-NaN deferred to 2.4.
4. `bda2cae3` — chunk-4: numeric conversions (wrap, extend,
   trunc with InvalidConversionToInt / IntOverflow traps,
   convert, demote, promote, reinterpret).
5. `6caf492` — lowerer extension to mirror validator's full
   Wasm-1.0 coverage (br_if, br_table with branch_targets
   side-table, call, call_indirect, select, globals,
   loads/stores with memarg payload encoding, memory.size /
   grow, full numeric, full conversions).
6. `24fd6fc` — chunk-5: load / store / memory.size / memory.grow
   interp handlers. Effective addr = base + memarg.offset; OOB
   trips Trap.OutOfBoundsLoad / Store. Wasm page = 64 KiB.
7. `16cb839` — chunk-5b: unreachable / nop / select handlers
   (the trio that doesn't need pc mutation).
8. `af9c77c` — refactor: extract memory ops (loads/stores/
   memory.size/grow + tests) into `src/interp/memory_ops.zig`.
   mvp.zig: 1832 → 1533 lines.
9. `5ff820f` — chunk 6a: `dispatch.run` now tracks pc on
   `rt.currentFrame().pc` (handlers can mutate). New `Label`
   struct + per-Frame `label_buf` (max 128) for the control-
   label stack chunk 6b will populate. No observable behaviour
   change yet; tests that call `run` without a frame go through
   an ephemeral-frame path.
10. `8f7bf11` — chunk 6b: full Wasm-1.0 control flow
    (block/loop/if/else/end/br/br_if/br_table/return). Frame
    gains `func: ?*const ZirFunc` + `done: bool`; BlockInfo
    gains `else_inst: ?u32`; lowerer's emitElse records it.
    Tests cover block+end, br escape, if/else selection,
    mid-body return.

Chunk 6b — control-flow handlers — is the large remaining
piece. Plan:

- Add `func: ?*const zir.ZirFunc = null` to `Frame` so
  control-flow handlers can read `BlockInfo` (start_inst /
  end_inst) for the active function.
- Add `else_inst: ?u32 = null` to `BlockInfo` (`src/ir/zir.zig`)
  so the interp can route `if cond=0` to the matching `else` or,
  if none, the `end+1`. Field-add only — per the zir.zig comment
  ("Adding fields later is OK") no ADR needed; the lowerer's
  `emitElse` records it.
- Implement handlers in `src/interp/mvp.zig`:
  - `block`: pushLabel(.{ height, arity, target_pc = block.end_inst + 1 })
  - `loop`: pushLabel(.{ height, arity = 0, target_pc = block.start_inst + 1 })
  - `if`: pop i32; if 0, set frame.pc = (else_inst or end_inst + 1);
    push label as for block.
  - `else`: skip to matching end (frame.pc = block.end_inst).
  - `end` (block-level): popLabel; restore operand height; push
    result(s). Distinguish from fn-level end by label_len == 0.
  - `end` (fn-level): set frame.pc = instrs.len to terminate run.
  - `br N` / `br_if N`: popLabel down to N+1 levels (not really
    pop — the interp keeps the active label and discards inner
    ones); pop arity values into a buffer; restore operand
    height; push values back; set frame.pc = label.target_pc.
  - `br_table`: same as br but selector picks the depth.
  - `return`: br to the function-level "implicit" label
    (operand_base + sig.results.len).
- After chunk 6b, the spec runner can drive validate + lower +
  interp through the curated MVP corpus end-to-end (subject to
  call / call_indirect arriving in chunk 7).

`src/interp/mvp.zig` is now 1771 / 2000 lines. **File-split
refactor required before chunk 6** (control flow) + chunk 7
(call) push past the hard cap. Likely shape:
- `src/interp/int_ops.zig` (i32 + i64) — ~700 lines
- `src/interp/float_ops.zig` (f32 + f64) — ~400 lines
- `src/interp/conversions.zig` — ~250 lines
- `src/interp/memory_ops.zig` — ~250 lines
- `src/interp/mvp.zig` (aggregator + control + call + select +
  consts + drop + locals + globals) — ~400 lines

Remaining chunks for 2.2:
- chunk 6 control flow (block / loop / if / else / end / br /
  br_if / br_table / return) — needs dispatch loop refactor to
  read pc from `rt.currentFrame().pc` instead of a local.
- chunk 7 call / call_indirect — pushes a Frame with the callee's
  locals (params from operand stack + zero-init declared locals).
- `select` is already wired in chunk-1 dispatch via the validator's
  pattern, but the interp handler still needs to be added.

**Zone placement note**: `src/interp/mvp.zig` is Zone 2, not
Zone 1, because it imports `src/interp/mod.zig` for Runtime +
Value + Trap. ROADMAP §4.5's "feature modules" concept splits
per-engine: parser-side handlers stay in `src/feature/mvp/mod.zig`
(Zone 1), engine-side handlers live with their engine.

Remaining 2.2 chunks:

- **chunk 2 (i64 numeric)** — same shape as i32: 15 binops + 10
  relops + 3 unops + eqz.
- **chunk 3 (f32 / f64 numeric)** — 6 relops + 7 unops + 7 binops
  per width. NaN canonicalisation deferred to 2.4.
- **chunk 4 (conversions)** — wrap, extend, trunc (with
  InvalidConversionToInt traps), convert, demote / promote,
  reinterpret.
- **chunk 5 (loads / stores + memory.size / memory.grow)** —
  effective-address = `i32 base + memarg.offset`; `OutOfBoundsLoad`
  / `OutOfBoundsStore` against `rt.memory`.
- **chunk 6 (control flow)** — block / loop / if / else / end /
  br / br_if / br_table / return. These mutate the current
  frame's `pc` (the dispatch loop's outer `while` already advances
  pc by 1 per step; control flow handlers will need to subtract
  to keep the increment happy, OR the loop refactors to a
  `read pc → step → handler-set-pc` shape). Needs a small
  redesign of `dispatch.zig`'s `run` to consult `frame.pc`
  instead of a local.
- **chunk 7 (call / call_indirect)** — pushes a new Frame onto
  the runtime's frame stack with the callee's locals (params
  popped from operand stack + zeros for declared locals).
- **chunk 8 (select)** — pop i32 cond + 2 values, push the
  matching one.

Scope discipline: one chunk per turn (chunks are 2-5 commits each).

§9.2 / 2.2 wires the **MVP interp handlers** into
`DispatchTable.interp` via a new `src/feature/mvp/interp.zig`
(or by extending the existing `src/feature/mvp/mod.zig`). Scope:

- one handler per Wasm-1.0 numeric/control/memory opcode
  matching the validator's coverage (i32/i64/f32/f64
  binops/relops/unops/testops, control flow, locals/globals,
  load/store, const, drop, select, call, call_indirect).
- spec-conformant trap behaviour where the operation can fail
  (DivByZero on `div_*`/`rem_*`, IntOverflow on `*.div_s`
  INT_MIN/-1, InvalidConversionToInt on truncation, OOB on
  load/store).
- registration helper `register(*DispatchTable)` populating
  `interp` slots (the existing `parsers`-slot registration in
  `mod.zig` from §9.1 / 1.7 stays; both can co-exist).

Tests: drive `run` over each handler via a tiny ZIR stream
producing the expected operand-stack residue or trap. At least
one round-trip test per opcode group (integer arith / float
arith / load-store / control-flow / locals).

Step 0 (Survey) for 2.2: zwasm v1's per-opcode interp handlers
(probably under `src/interp/handlers/`); wasm3 source for
floating-point edge-case handling (NaN canonicalisation, signed
zero); ROADMAP §4.3 (engine pipeline shared with JIT/AOT) and
§4.8 (Float and SIMD strategy — float invariants Phase 2 must
honour).

## Historical (§9.1 / 1.9) — IN-PROGRESS prior to close


§9.1 / 1.9 is large and lands across multiple commits. Progress
so far on top of `8ab5b55` (1.8 close):

1. `9e1440a` — `src/frontend/sections.zig` decodeTypes.
2. `29a4d3d` — decodeFunctions ([]u32 typeidx) + decodeCodes.
3. `4e82121` — runner drives validator per function.
4. `bb6a3a2` — validator extended to full Wasm 1.0 numeric +
   control + memory coverage; call (with func_types).
5. `354e4c6` — globals: decodeGlobals + global.get / global.set
   with `globals: []const GlobalEntry` parameter.
6. `62d2991` — call_indirect (0x11) + new `module_types`
   parameter (the type-section table separate from per-function
   func_types).

Probed against wast2json-baked upstream samples:
- ✅ PASS: const.0.wasm, nop.0.wasm (full call/call_indirect/
  globals/select/etc. exercised).
- ❌ FAIL with NotImplemented: i32.0.wasm / i64.0.wasm
  (i32.extend8_s / i64.extend8_s — Wasm 2.0 sign-extension);
  conversions.0.wasm (i32.trunc_sat_* — Wasm 2.0 saturating
  truncation, prefix opcode 0xFC).

Remaining for 1.9 close (in priority order):

- **Imports decoder**: `import` section. Function imports
  prepend the func_idx space, so without it any module that
  imports anything misindexes. Add to `sections.zig` and
  thread the resulting `func_types` (imports + defined) through
  the runner.
- **Corpus selection** for the Phase-1 gate: the upstream
  `~/Documents/OSS/WebAssembly/spec/test/core/` corpus tests
  Wasm 1.0 + 2.0 + 3.0 features in a single tree. For the
  Wasm-1.0 (MVP) gate we either (a) hand-curate a list of
  `.wast` files known to be MVP-only, OR (b) keep the post-MVP
  opcodes returning `NotImplemented` and treat MVP-pure files
  as the gate (the "skip=0" portion of the gate will need an
  ADR if option (b) is chosen).
- **`.wast` directive handling**: the script files contain
  `(assert_invalid ...)` / `(assert_malformed ...)` marking
  modules **expected to fail**. The runner needs to read the
  wast2json metadata (the `commands[]` array with `module_type`
  / `assertion` directives) and invert pass/fail expectation
  per module. Without this, `assert_invalid` files
  legitimately fail-to-validate but the runner reports them
  as failures.
- **Vendor scaffolding**: `scripts/regen_test_data.sh`
  invoking `wast2json`, output gitignored at `test/spec/json/`,
  upstream commit pinned in `test/spec/README.md`.
- **Three-host gate**: Mac aarch64 + OrbStack Ubuntu x86_64 +
  windowsmini SSH all return EXIT=0 on the chosen corpus.

Step 0 (Survey) for next chunk: zware's imports decoder
(`module.zig`); wasm-tools `wast2json` metadata JSON shape
(the `commands[]` array and `module_type` field); ROADMAP §11 /
§A10 (vendor policy + skip=0 release gate).

**Retrievable identifiers**:

- ROADMAP §1 — mission, v0.1.0 = v1 parity + wasm-c-api
- ROADMAP §2 — P1-P14 (inviolable principles), A1-A12 (verifiable rules)
- ROADMAP §4 — architecture (Zone 0-3, ZIR, dispatch tables, AOT/JIT pipeline)
- ROADMAP §4.2 — full ZirOp catalogue (~600 ops, day-1 reserved)
- ROADMAP §9.0 — Phase 0 task list (DONE)
- ROADMAP §9.1 — Phase 1 task list (IN-PROGRESS)
- ROADMAP §11 — test strategy + test data policy
- ROADMAP §11.5 — three-OS gate (Mac / OrbStack / windowsmini)
- ROADMAP §13 — commit discipline + work loop
- ROADMAP §14 — forbidden actions
- ROADMAP §18 — amendment policy

## Open questions / blockers

(none — push to `origin/zwasm-from-scratch` is autonomous inside
the `/continue` loop per the skill's "Push policy"; no user
approval required. The next loop iteration will push outstanding
local commits before running the windowsmini gate.)

## Notes for the next session

- Skill `continue` (`.claude/skills/continue/SKILL.md`) handles
  "続けて" / "/continue" / "resume". It auto-triggers on those phrases
  and drives the per-task TDD loop autonomously. Stops only when the
  user intervenes or a problem cannot be solved (no other stop
  conditions).
- Skill `audit_scaffolding` runs at adaptive cadence (after large
  refactors, after scaffolding accretes, when something feels off).
  Not strictly per-phase or per-N-commits, but Phase 0 / 0.6 calls
  for one explicitly.
- Rule `.claude/rules/textbook_survey.md` — auto-loaded on
  `src/**/*.zig`; defines the Step 0 brief and the no-pull guardrails.
- Rule `.claude/rules/no_copy_from_v1.md` — explicit ban on
  copy-paste from zwasm v1.
- Rule `.claude/rules/no_workaround.md` — root-cause fixes only;
  abandoned-experiment ADRs preferred over ad-hoc patches.
- The 🔒 marker on Phases 0 / 2 / 4 / 7 / 9 / 12 / 15 means a fresh
  three-host gate is due at that phase boundary:
  Mac aarch64 native + OrbStack Ubuntu native + windowsmini SSH.
- CI workflows (`.github/workflows/*.yml`) are deliberately absent
  in Phase 0 — they appear in Phase 13 per ROADMAP §9. Local Mac +
  OrbStack + windowsmini covers all three platforms until then.
- **Windows transport limitation (Phase 14 follow-up)**:
  `scripts/run_remote_windows.sh` syncs via `git fetch + reset
  --hard origin/zwasm-from-scratch` — it tests **what is on origin**,
  not unpushed local commits. Phase 14 should add a `git bundle`
  path so pre-push gates also exercise in-flight commits before
  they land on the remote.
- **Stray-artifact commit hygiene**: when an unrelated file
  (`flake.lock`, `.direnv`, …) appears in `git status` mid-task,
  commit it under its own scope (`chore: pin <thing>`), don't
  bundle it into unrelated work. Helps `git log -- <file>` stay
  readable.
