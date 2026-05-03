# 0014 — Redesign + refactoring sweep before Phase 7

- **Status**: Accepted
- **Date**: 2026-05-03
- **Author**: continue loop iter 5–11 + interactive dialogue
- **Tags**: phase-6, redesign, refactor, value-semantics,
  cross-module, ownership, debt-cleanup, phase-7-precondition
- **Replaces**: the placeholder content originally filed under this
  same ADR slot ("Wire a refactor & consolidation phase between
  Phase 6 and the JIT phase"). The placeholder proposed a Phase 7 =
  refactor + Phase 8 = JIT renumber and a forthcoming ADR-0015
  charter. This ADR supersedes that wiring entirely (see
  Alternatives §3).

## 1. Context

zwasm v2 is **pre-release** — zero downstream users, no API
compatibility constraints. ROADMAP §P10 ("re-derive from v1, do
not copy") and §P3 ("cold-start single-pass") give the project
permission to choose the **right** shape, not the cheapest patch.
Phase 6 reopen iterations 5–11 (per ADR-0011 + ADR-0012) drove
the wasmtime misc-runtime gate from 78 fails to 28, but in the
process surfaced eight items that share a single root: the v1
carry-over of "single-instance-implicit" semantics in `Value`,
`Runtime`, and the c\_api ownership graph.

Each is documented inline in `.dev/handover.md` "Workaround / debt
inventory":

1. `c_api/instance.zig` returns `error.UnsupportedCrossModule*`
   for every non-memory cross-module import. Direct cause of
   27 of the 28 remaining misc-runtime failures.
2. `Value.ref` (interp/mod.zig) packs only a 32-bit funcidx — no
   instance identity. Single-instance assumption leaks through
   `call_indirect` / `table.*` / `ref.func` / element-segment
   population.
3. `Runtime ↔ Instance ↔ allocator` ownership is ad-hoc:
   `rt.alloc` is parent\_alloc, `inst.arena` is per-instance,
   table refs straddle both, `rt.memory` got a `memory_borrowed`
   bool to avoid double-free, table/elem slices leak. Every new
   resource (globals, FuncEntity) would re-invent the same
   pattern badly.
4. `Runtime` has no Instance back-pointer. Cross-instance dispatch
   would have to invent ad-hoc routing per call site.
5. `decodeElement` (frontend/sections.zig) only handles forms
   0/1/3/4 — forms 5/7 (passive/declarative reftype-expr vec)
   return `Error.InvalidFunctype`. Two reftypes fixtures fail
   because of this.
6. `Label` (interp/mod.zig) used a single `arity` field for both
   `end`-time results and `br`-time params. iter 11 split it into
   `arity` + `branch_arity` to fix `loop (result T)`. The split
   needs ADR-level formalisation and `.claude/rules/`-level
   anti-pattern guidance ("single slot serving two distinct
   meanings is a §14-class smell") so the next slot doesn't
   regress.
7. `wast_runtime_runner.buildImports` silently null-slots
   unresolved imports; the failure surfaces two layers deep as
   `UnknownImportModule`. The runner's diagnostic chain is
   fragile and grew this way only because cross-module imports
   are still being built out.
8. `partial-init-table-segment/indirect-call result[0] mismatch`
   (1 fixture) is uninvestigated; certainly downstream of (1) /
   (2) — re-measure after they land, do not patch in isolation.

The user's directive (2026-05-03 dialogue): **"設計としてあるべき
論をとるべきで、コストを考えるべきではない。世の中にまだ出ていな
い。残タスクを Phase 7 以降に残すべきでない。"** No outstanding
unimplemented ADRs, no debt rolling forward into the JIT phase.

A subagent survey of `Value.ref` impact (2026-05-03) found 4
producer + 2 consumer + 18 table-mover + 4 null-check + 70+
test sites; worst-hit file is `interp/ext_2_0/table_ops.zig`
(35+ touch sites). v1 uses Store-centric tables with a `shared`
flag; wasmtime uses `*VMFuncRef` pointers; zware/wasm3 do not
support cross-module. Aligning v2 with the wasmtime-style
pointer representation is the only path that satisfies "あるべ
き論": funcref carries its own instance identity, cross-module
dispatch becomes a pointer dereference, and the design extends
cleanly to externref / continuation-ref for Wasm 3.0.

## 2. Decision

Insert a new work-item block §9.6 / 6.K **inside Phase 6, before
6.J close**. Six work items address all eight inventory entries.
Phase 6 closes only when all 6.K items land + the existing 6.E /
6.F / 6.G / 6.H / 6.I / 6.J criteria.

No follow-up ADR. No Phase 7 = refactor renumber. JIT remains
§9.7. Once Phase 6 closes, Phase 7 starts atop a clean
substrate.

### 2.1 Work-item DAG (6.K)

```
6.K.1 (Value funcref → *FuncEntity)
   ├─→ 6.K.2 (ownership model + Instance back-ref)
   │      └─→ 6.K.3 (cross-module imports: table / global / func)
   │             └─→ 6.K.6 (re-measure partial-init-table fixture)
   ├─→ 6.K.4 (decodeElement forms 5 / 7)  [parallel]
   └─→ 6.K.5 (Label arity formalisation + §14 anti-pattern entry)  [parallel]
```

#### 6.K.1 — Value funcref carries instance identity

**What**: Replace bare-funcidx encoding of `Value.ref` with a
pointer to a per-instance `FuncEntity`. Each Instance allocates
a `FuncEntity` array at instantiation time (one per defined
function). Element-segment population, `ref.func`, `table.fill`,
`table.grow`, and `table.set` write `@intFromPtr(*FuncEntity)`
into `Value.ref`. `call_indirect`, `ref.is_null`, `wasm_func_call`,
`wasm_extern_as_func` reverse the cast. The null sentinel
becomes literal `0` (no funcref ever has the address 0;
allocation guarantees it).

**Why this shape**: aligns with wasmtime's `*VMFuncRef`
(textbook §Q3); avoids v1's Store-centric `shared` flag (§P10
divergence cited); single-instance modules pay one extra
indirection per `call_indirect` (acceptable per §P3 — the
allocation is once-per-instantiation, not per-call); cross-
module modules need no separate routing table because the
pointer already carries source identity.

**Externref**: this ADR scopes only the funcref change.
Externref keeps its current opaque-host-handle representation
(low 64 bits = host pointer); ADR-0014 does not block externref
work.

**Test cost**: ~70+ test sites in `interp/ext_2_0/table_ops.zig`
+ `interp/trap_audit.zig` use bare-funcidx construction
(`.{ .ref = 7 }`). They migrate to a small helper
`Value.fromFuncRef(*FuncEntity)` or to using a stub FuncEntity
pool. Mechanical but bulky.

**Files touched**: `src/interp/mod.zig`, `src/interp/mvp.zig`,
`src/interp/ext_2_0/{ref_types,table_ops}.zig`, `src/c_api/instance.zig`,
plus the test sites above.

**Acceptance**: existing tests green + a new unit test exercising
"two instances share a table; each writes its own FuncEntity;
call\_indirect dispatches into the correct source instance".

#### 6.K.2 — Ownership model: Instance back-ref, allocator discipline

**What**: Three sub-changes:

1. `Runtime` gains `instance: ?*anyopaque = null` (Zone 2 cannot
   import Zone 3 directly; the c\_api binding stores a `*Instance`
   here at construction). Used by 6.K.3 only — not consulted on
   the hot path.
2. Single allocator policy. `rt.alloc` becomes the
   per-instance arena. All runtime resources (memory, globals,
   tables.refs, elems, FuncEntity pool, host\_calls, dropped
   flags) allocate from this arena. `Runtime.deinit` becomes a
   no-op for individually-tracked resources; arena-free at
   instance teardown reclaims everything in one shot.
3. Drop `Runtime.memory_borrowed` and the parallel hand-rolled
   borrowed-flag pattern. Cross-instance memory imports work by
   making the importer's `rt.memory` slice header reference the
   source's bytes; no free path needs to know which is which
   (the source's arena owns the storage).

**Why this shape**: every introduced resource (globals,
FuncEntity, future continuation-ref) inherits arena ownership
without re-inventing flags; `table.grow`'s realloc against
arena allocator works when the arena's underlying allocator is
the c\_allocator (which it is in c\_api today). Removes the iter-7
`memory_borrowed` workaround. Removes the iter-5 "tables refs
allocated from parent\_alloc but headers from arena" leak.

**Files touched**: `src/interp/mod.zig` (Runtime fields +
deinit), `src/c_api/instance.zig` (instantiateRuntime allocator
choice unified), `src/interp/ext_2_0/table_ops.zig`
(`table.grow`'s realloc target).

**Acceptance**: full test-all green on three hosts; no leak
warnings under DebugAllocator (where available); the
`memory_borrowed` field is deleted.

#### 6.K.3 — Cross-module imports for table / global / func

**What**: Drop `error.UnsupportedCrossModuleTableImport` /
`…GlobalImport` / `…FuncImport` from c\_api. Wire each:

- **Table import**: 6.K.1 makes the funcref encoding instance-
  agnostic, so sharing the source's `TableInstance` (refs slice +
  metadata) Just Works. The importer's `rt.tables[idx]` holds a
  copy of the source's `TableInstance` struct value (refs slice
  is shared; mutations from either side propagate).
- **Global import**: similar — `rt.globals[idx]` aliases the
  source's slot. Globals are by-value Wasm types (no references);
  shared-storage = shared-state. Need to be careful about
  mutability: a mutable global mutated by the importer must reach
  the source; the same slice-aliasing handles this.
- **Func import**: the importer's funcidx 0..imp\_func\_count map
  to source instance functions. Build the importer's
  `host_calls[i]` to a thunk that pops args off the importer's
  operand stack, pushes them onto the source's, runs source's
  dispatch with source's runtime context, and copies results
  back. (Cross-instance dispatch helper.)

**Why this shape**: 6.K.1's pointer-based funcref makes table
sharing trivial (the source's funcrefs already point at the
source's FuncEntities; the importer reads them and dispatches
correctly). Globals are simple slice-aliasing. Func imports
need an explicit thunk because operand stacks are per-Runtime;
this is the same shape WASI thunks already use.

**Files touched**: `src/c_api/instance.zig`
(`instantiateRuntime` import-resolution branch),
`test/runners/wast_runtime_runner.zig` (`buildImports` no longer
silently null-slots — surfaces named errors for unresolved
imports per 6.K's "diagnostic chain" goal).

**Acceptance**: 27 of the 28 misc-runtime fails recovered (the
28th is the 6.K.6 one). Cross-module unit test added per 6.K.1
exercises the shared-table path end-to-end.

#### 6.K.4 — decodeElement element-section forms 5 / 7

**What**: Extend `decodeElement` (`src/frontend/sections.zig`) to
handle:

- form 5: passive, reftype, vec(expr) — null-init or ref.func
  exprs
- form 7: declarative, reftype, vec(expr) — same expr shape

Reuse iter-5's `readFuncrefInitExpr` helper (rename to
`readReftypeInitExpr` and accept a reftype tag). Form 6
(active, tableidx, expr, reftype, vec(expr)) is symmetrical;
include it in the same change for completeness.

**Why this shape**: completes the §9.2 / 5d-3 carry-over inside
the same iter that needs externref support for table-import
parity (the externref-segment fixture and elem-ref-null fixture
both exercise these forms). Closes a Phase 2 carry-over inside
Phase 6.

**Files touched**: `src/frontend/sections.zig`,
`src/c_api/instance.zig` (element-segment population: handle
externref + null per-cell).

**Acceptance**: 2 reftypes fixtures (externref-segment.0,
elem-ref-null.0) move from FAIL to PASS.

#### 6.K.5 — Label arity formalisation + §14 anti-pattern

**What**:

1. Add a `.claude/rules/single_slot_dual_meaning.md` documenting
   the iter-11 bug ("one field serving two distinct semantic
   purposes is a smell; split into named fields per purpose
   from day 1"). Cite the `Label.arity` example. Reference from
   ROADMAP §14.
2. ROADMAP §14 (forbidden patterns) gains a one-line bullet:
   "single slot pulling double duty across distinct semantic
   axes — must be split per axis from day 1".
3. Optional: a small Zig-level guard test that asserts
   `Label.arity` and `Label.branch_arity` exist as separate
   fields (catches an accidental future merge).

**Why this shape**: iter 11 fixed the bug but the design lesson
needs a durable anchor; otherwise the same pattern reappears at
the next "looks like it can share a field" decision (operand
arity vs result arity in some future opcode, etc.).

**Files touched**: `.claude/rules/single_slot_dual_meaning.md`
(new), `.dev/ROADMAP.md` §14.

**Acceptance**: the rule auto-loads when editing
`src/interp/*.zig` (per `.claude/settings.json` rule glob);
ROADMAP §14 entry visible.

#### 6.K.6 — Re-measure partial-init-table-segment

**What**: After 6.K.1–6.K.3 land, re-run
`test-wasmtime-misc-runtime` and check whether
`partial-init-table-segment/indirect-call result[0] mismatch`
self-resolves. If yes: PASS, document in commit message. If no:
investigate as a standalone interp behaviour bug.

**Why this shape**: avoids speculatively patching something that
was almost certainly downstream of (1) / (2). Per
`.claude/rules/no_workaround.md`: fix root causes, not symptoms.

**Acceptance**: 28th failure resolved OR documented as a
distinct bug with its own work item.

### 2.2 Phase 6 close criterion (unchanged in spirit)

§9.6 / 6.J's text remains "100% PASS, no soft-skip, no tolerated
nonzero". 6.K is added as a precondition for 6.J ("6.J cannot
fire until all 6.K items are [x]").

### 2.3 Phase Status widget

No renumber. Phase 7 stays "JIT v1 ARM64 baseline". The
widget's only update at 6.J close is `6 = DONE, 7 = IN-PROGRESS`,
matching the standard `continue` skill flow.

### 2.4 No follow-up ADR

Everything decided here. No ADR-0015 placeholder. No
"forthcoming charter". If 6.K work surfaces a sub-decision that
needs ADR-grade documentation (e.g. choosing between two
FuncEntity layouts), that ADR is filed at the moment of
decision, not pre-allocated.

## 3. Alternatives considered

### α — Defer to Phase 7 / Phase 11 (subagent's option 2)

Keep bare-funcidx encoding for v0.1.0; address cross-module in a
later phase with its own ADR. Rejected: the user's "あるべき論"
directive prohibits this. Pre-release with zero users means
there is no compatibility cost to choosing the right shape now;
deferring just rolls the same work + accumulated retrofitting
cost forward.

### β — Phase 7 = refactor phase (the original ADR-0014
placeholder)

Insert a refactor phase between Phase 6 and JIT. Rejected: the
"refactor phase" framing implied workaround-first then cleanup-
later; Phase 7 dedicated to JIT can't open atop unfixed
cross-module gaps anyway. Splitting the cleanup into a separate
phase introduces a phase boundary (close-criterion ceremony,
handover update, ADR-0015 forthcoming) that adds zero design
value. Doing it inside Phase 6 keeps the work concentrated on
correctness, which is Phase 6's charter (per ADR-0008).

### γ — Packed (instance\_id, funcidx) registry

Encode `Value.ref` as `(instance_id << 32) | funcidx`; maintain
a global `instance_id → *Instance` registry. Rejected: requires
a process-wide registry (introduces global mutable state, against
§P3); the registry needs lifecycle management (free instance\_id
on instance delete); JIT phase will want a direct pointer
dereference for `call_indirect` performance, not a registry
lookup. The pointer-based approach (6.K.1) is what JIT will
adopt anyway, so doing it now avoids a second migration.

### δ — Skip cross-module fixtures via per-fixture ADR

Document each of the 27 fixtures in `.dev/decisions/skip_*.md`
per ROADMAP §9.6 / 6.J's exception clause. Rejected: that
clause is for "v1-era design-dependent fixtures v2 deliberately
rejects on spec-fidelity grounds (§P1)". Cross-module imports
are a v2-supported feature per the wasmtime corpus we vendored;
skipping would be dishonest closure.

## 4. Consequences

### Positive

- Phase 6 closes with **strict 100% PASS** (modulo the
  legitimate v1-era-rejection clause for fixtures that don't
  apply).
- Phase 7 (JIT) opens atop a clean substrate: instance-agnostic
  funcref, single-allocator Runtime, no cross-module gaps,
  no `memory_borrowed`-class flags, formalised Label arity.
- No outstanding unimplemented ADRs roll into Phase 7+.
- The Value-funcref pointer representation is what JIT v1 will
  need anyway for `call_indirect` codegen; doing it now in the
  interp pays JIT's design cost up front.
- 6.K.4 closes a Phase 2 carry-over (element forms 5/6/7),
  shrinking the "outstanding spec gaps" handover list.
- 6.K.5 turns a one-off bug-fix lesson into durable scaffolding.

### Negative

- Phase 6 takes longer to close. The 6.K block is on the order
  of 6 source iterations (one per work item); maybe more if
  6.K.1's test-site migration uncovers subtleties. This is the
  cost the user explicitly accepted ("コストを考えるべきでは
  ない").
- 6.K.1 churns 70+ test sites mechanically. Risk of merge pain
  if other work touches those tests in parallel; mitigated by
  Phase 6 being the only active line of development.
- The pointer-based funcref encoding makes funcrefs allocated
  (one FuncEntity per defined function per instance). For
  small modules this is cheap; for an embedded use-case with
  many tiny modules, a follow-up could pool. Out of scope for
  v0.1.0.

### Neutral / follow-ups

- ROADMAP §9.6 gains 6.K rows. §9.6 / 6.J row text loses the
  "Phase Status widget flip per ADR-0014 (new §9.7 = refactor &
  consolidation; ...)" annotation — that wording referred to
  the placeholder content this ADR replaces.
- ROADMAP §9.7 (JIT v1 ARM64 baseline) stays at §9.7. No
  renumber. No §9.<N+1> shifts.
- ADR-0008 (Phase 6 charter — correctness) is unaffected; 6.K
  fits its charter because every item is a correctness gap
  surfaced by the misc-runtime gate.
- ADR-0011 (Phase 6 reopen) is unaffected; its renumber-rejection
  rule continues to protect numbering through Phase 6 close.
- ADR-0012 (Phase 6 reopen scope, 6.A〜6.J DAG) gains 6.K rows
  by §18 amendment; the existing 6.A〜6.J semantics are preserved.
- ADR-0013 (runtime-asserting WAST runner design) is unaffected.
- `.dev/handover.md`'s "Phase 6 close → automatic refactor-phase
  ADR drafting" + "ADR-0015 draft brief" + "Carry-over reminders
  for ADR-0015 drafting" sections are removed (they referenced
  the placeholder this ADR replaces). They are replaced by a
  "Phase 6 / 6.K work item table" pointing at this ADR.

## 5. Observations on what made this necessary

Documented for future-self and for the §6.K.5 anti-pattern rule.

The eight inventory items came from one common root: **v1's
single-instance-implicit assumptions were carried into v2 without
re-derivation**. The validator/lowerer survived because they're
per-module pure functions with no instance state. The interp
runtime + c\_api binding inherited the assumption silently:
- `Value.ref = funcidx` — single-instance.
- `Runtime` no Instance back-ref — single-instance.
- table.refs as raw funcidxs — single-instance.
- `memory_borrowed` flag introduced ad-hoc when cross-module
  finally arrived — local-fix instead of model-fix.

Per `.claude/rules/no_copy_from_v1.md`, v2 should have re-derived
"how do funcrefs cross instance boundaries" up front. The
re-derivation didn't happen because Phase 1–5 only exercised
single-instance test fixtures (spec testsuite + smoke + WASI
realworld). The misc-runtime corpus vendored in §9.6 / 6.B
introduced cross-module test cases for the first time, and the
gap surfaced under 6.E. ADR-0014's §6.K.1 / 6.K.2 redoes that
re-derivation.

The lesson, queued for `.claude/rules/no_copy_from_v1.md` as a
follow-up: when introducing v2 substrate types (`Value`,
`Runtime`, `Instance`), explicitly enumerate the "what does this
mean across instances" axis even if the immediate test corpus
doesn't exercise it. This protects against the same surface
returning silently in continuation-ref / shared-memory /
multi-thread land.

## 6. References

- ROADMAP §9.6 (Phase 6 — gains 6.K work-item block per §2.1
  above), §9.7 (JIT v1 ARM64 — unchanged), §P1 / §P3 / §P6 /
  §P10 / §A12, §14 (gains anti-pattern entry per 6.K.5)
- ADR-0008 (Phase 6 charter — correctness; 6.K fits)
- ADR-0011 (Phase 6 reopen rules; renumber-rejection still
  protects current Phase 6 numbering)
- ADR-0012 (Phase 6 reopen scope, 6.A〜6.J DAG — gains 6.K
  by §18 amendment)
- ADR-0013 (runtime-asserting WAST runner — independent)
- `.dev/handover.md` "Workaround / debt inventory" (the eight
  items 6.K addresses)
- `.claude/rules/no_copy_from_v1.md` (the rule that should have
  flagged the v1 carry-over earlier; follow-up §5 above)
- `.claude/rules/no_workaround.md` (the rule 6.K.6's "no
  speculative patch" stance derives from)
- iter-5 / iter-7 / iter-11 commit messages
  (`bdef556` / `7cc6715` / `7b26760`) — the substrate work that
  surfaced the inventory
