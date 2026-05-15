#!/usr/bin/env bash
# Regenerate Wasm 2.0 non-SIMD spec corpus with full assertion
# manifests (§9.9 / 9.9-l-1b per ADR-0057). Parallel to
# `regen_spec_1_0_assert.sh`; same distillation pipeline,
# targeting wasm-2.0-specific .wast files (sign-ext, sat-trunc,
# select-typed, local_init, etc.). Consumed by the new
# `spec_assert_runner_non_simd` (`zig build test-spec-wasm-2.0-assert`).
#
# The starter set is curated for shapes the runner already handles:
#   - scalar (i32 / i64 / f32 / f64) args + results, no v128
#   - n_args ∈ {0, 1, 2, 5} (5-arg covers the `(i64 f32 f64 i32 i32)`
#     multi-value family)
#   - single-result (multi-result is skip-impl at the manifest level
#     via the `len(results) > 1` filter below).
#
# Expansion (k-1 row in the autonomous queue) adds:
#   - table_get / table_set / table_size / table_init / table_copy
#     (the m-2 cluster JIT support is in place; these need scalar
#     refnull handling on the runner side, deferred).
#   - bulk-memory / memory_init / memory_copy / memory_fill /
#     data_drop / elem_drop.
#   - block / loop / call multi-value fixtures (need multi-result
#     return-value packing in the runner; deferred).
#   - ref_func / ref_null / ref_is_null (need reftype handling).

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${WASM_SPEC_REPO:-$HOME/Documents/OSS/WebAssembly/spec}
DEST=test/spec/wasm-2.0-assert

if ! command -v wast2json >/dev/null 2>&1; then
  echo "[regen_spec_2_0_assert] wast2json not found (need wabt in PATH or dev shell)" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[regen_spec_2_0_assert] python3 not found" >&2
  exit 1
fi
if [ ! -d "$UPSTREAM/test/core" ]; then
  echo "[regen_spec_2_0_assert] upstream not found at $UPSTREAM/test/core" >&2
  exit 1
fi

# Curated l-1b starter set. Wasm 2.0 features each name exercises:
#   conversions   — sign-extension (i32.extend8_s, i64.extend32_s, …)
#                   + non-trapping float-to-int (i32.trunc_sat_f32_s,
#                   i64.trunc_sat_f64_u, …).
#   local_init    — Wasm 2.0 local-init invariant
#                   (locals zero-initialised before any read).
# `select` is queued for the next chunk: the Wasm 2.0 typed-select
# corpus (select.wast) carries reftype-bearing assertions whose
# `module` directives compileWasm rejects with `BadValType` until
# reftype runtime support lands. Pulling it now would make the
# corpus FAIL non-stop on every cycle.
# Expansion candidates listed in the file header (table_*, ref_*,
# bulk-memory) need runner extensions or refnull handling that are
# out of l-1b scope (k-1 row in the autonomous queue).
# f32 / f64 re-enabled at D-092 close (§9.9 / 9.9-l-1b-d092-close):
# the x86_64 `emitFpMinMax` path rejected the regalloc-issued
# `dst == rhs and dst != lhs` case where `emitFpBinary` handled
# it (commutative-swap). Fix: min/max are commutative across all
# three branches (UCOMI / MINSS-MAXSS / ORPS-ANDPS / ADDSS), so
# swap lhs/rhs when dst aliases rhs. Three-host gate bit-identical.
NAMES=(
  conversions
  i32
  i64
  f32
  f64
  f32_cmp
  f64_cmp
  int_exprs
  int_literals
  float_literals
  unreachable
  local_get
  local_set
  return
  nop
  block
  loop
  local_tee
  if
  # d-19 NAMES expansion (six names mechanically covered by
  # the already-implemented ops). `select` deferred: select.0.wasm
  # exports `(select externref)` + `(select funcref)` per Wasm
  # spec §3.3.4.2 — our validator rejects reftype params with
  # BadValType (reftype runtime is Phase 10+). `align` rejected
  # by `wast2json` (regen script logs skip + moves on).
  address
  const
  load
  store
  traps
  # d-20 batch: FP-bitwise + memory_size + structural surfaces.
  # `fac` deferred: `fac-ssa` uses `loop (param i64 i64)
  # (result i64)` — Wasm 2.0 multi-value loop params surface a
  # latent codegen bug (returns 24 instead of 25! = i64-fold-
  # of-loop-iteration). Tracked as D-099. `br_table` deferred:
  # br_table.0.wasm carries `meet-externref` / `meet-funcref-N`
  # exports — reftype, Phase 10+. d-20 also lands the runner's
  # module-aware `memory.size` + `memory.grow` max-pages reset
  # (`base.extractMemoryLimits` → `current_mem_max_pages`).
  f32_bitwise
  f64_bitwise
  memory_size
  switch
  type
  # d-21: bisect identified seven names that each need their own
  # follow-up chunk; none cleanly land in this batch. d-21 ships
  # the runner capacity bump (`GROWABLE_MEMORY_CAPACITY` 64 →
  # 1024 pages) so when memory_grow's discharge chunk arrives the
  # pool can carry the corpus's grow(800)+grow(1) cumulative
  # sequence. Per-name diagnosis:
  # - call (D-101): call.0.wasm UnsupportedOp at compile.
  # - data (D-102): data-init UnsupportedEntrySignature (bulk
  #   data segments).
  # - elem (D-103): SEGV in nonSimdRunAssertTrap (element-segment
  #   trap asserts crash inside the JIT-called function, so the
  #   trap stub doesn't fire).
  # - global (D-104): global.{0,50}.wasm BadValType (reftype
  #   globals; Phase 10+ scope per D-075).
  # - memory_grow (D-105): 2 residual fails on cross-module memory
  #   imports (= D-079 (i)/(ii) sub-case).
  # - start (D-106): start fn not auto-invoked at instantiation.
  # - unwind (D-107): x86_64 unwind.0.wasm UnsupportedOp; Mac
  #   passes. arm64 / x86_64 emit divergence in br_table /
  #   br-with-value path likely.
  # d-22: tried start (D-106 discharge attempt) — runner now
  # invokes module start fn via `base.extractStartFunc` +
  # `entry.callVoidNoArgs`, but start.3.wasm's $main (calls $inc
  # three times) crashes the JIT body with SEGV at 0xaa...aa
  # (undefined-memory pattern). Likely a regalloc/spill interaction
  # with the bare runtime view, OR func_offsets not yet populated
  # at the on_module_loaded hook point. Runner code stays (no-op
  # for non-start modules); NAMES revert keeps the gate green.
  # `start` deferred (D-106 still open, narrowed: the on_module_
  # loaded ordering bug is the new root cause).
  # Bundle bisect (call_indirect/func/func_ptrs/memory/table) all
  # surfaced UnsupportedOp / validate / trap-assert / wast2json-
  # rejected — covered by D-108..D-110.
  unwind
  fac
  # d-25 probe: D-101 call.0.wasm UnsupportedOp.
  call
  # d-27 lands structural-type matching at call_indirect (D-111):
  # canonicalize typeidx at codegen + applyTableInit so bytewise
  # compare implements Wasm spec §3.4.6 / §4.4.10.1 structural
  # equivalence. Unblocks both `func` (signature-explicit-duplicate
  # uses call_indirect through a duplicate type def) and
  # `call_indirect` (12 dispatch-structural-{i32,i64,f32,f64} fails).
  call_indirect
  func
  # d-27 probe: D-110 func_ptrs.wast callt/callu 7 trap-asserts —
  # hypothesised as cascade from D-111.
  func_ptrs
  # d-28: `data` deferred. Probe found 19 module-load failures
  # are all import-dependent: 15× `applyActiveDataSegments`
  # rejects (memory imported → `current_mem_bytes=0`; or
  # offset_expr uses `global.get $imp` which our 3-byte LEB
  # const-expr decoder rejects) + 4× `InvalidFunctype` at the
  # imports decoder. D-102 reclassified blocked-by D-105 (cross-
  # module memory/global imports; Phase 10+ scope). The
  # corpus's 47 import-free modules contribute 0 incremental
  # PASS (they're all assert_trap and the dispatch ladder
  # already filters out the runtime shapes) — enabling `data`
  # would land 19 FAIL + 0 useful coverage. Defer.
  # d-38 batch probe (in-flight bisect).
  br
  br_if
  endianness
  forward
  labels
  left-to-right
  stack
  ref_null
  ref_func
  memory
  memory_redundancy
  float_misc
  float_memory
  # d-42b enable: `select` — D-112 fully discharged. d-42 landed
  # the JIT multi-table call_indirect dispatch (per-table
  # `TableJitCallInfo` array); d-42b wires the spec_assert
  # harness's `setupMultiTableScratch` from
  # `spec_assert_runner_base.makeJitRuntime` callers. The 4
  # `as-call_indirect-{first,mid}` FAILs were sig-mismatch traps
  # from the JIT loading table 0's funcptr_base for a
  # `call_indirect $t1`-class assertion; per-table dispatch fixes
  # this end-to-end.
  select
  ref_is_null
  # d-45: br_table enabled. D-118 closed via per-case CMP dispatch
  # in both arch emitBrTable (CMP imm12 vs MOVZ+MOVK+CMP-reg on
  # arm64; CMP imm8/imm32 + Jcc rel8/rel32 on x86_64) + reftype
  # block-type acceptance in validator readBlockType + lower
  # readBlockArity (Wasm 2.0 §5.3.5 -16/-17 = funcref/externref).
  # br_table.wast's `large` func declares 16149 targets, well past
  # the prior 4096 (arm64) / 127 (x86_64) caps.
  br_table
  # d-44 batch: green-bisected names. `bulk` (SEGV),
  # `memory_init` (value-mismatch + missing-trap) deferred per
  # d-44 bisect (= D-119, D-120).
  # The d-37 cross-module-imports pre-filter handles `data` /
  # `global`-class modules whose imports the runner can't bind.
  data
  global
  memory_copy
  memory_fill
  memory_grow
  # d-46 batch: green-bisected table_* family. 3 of 8 candidates
  # land cleanly. Deferred per-corpus to debt:
  # - `table_get` 1 FAIL (externref OOB get not trapping) — D-121.
  # - `table_size` 1 FAIL (UnsupportedOp at compile) — D-122.
  # - `table_init` SEGV mid-corpus — D-123.
  # - `table_copy` 8 FAIL (assert_trap not trapping; bounds-check
  #   gap?) — D-124.
  # - `table_grow` 6 FAIL (UnsupportedOp at compile) — D-125.
  table
  table_set
  table_fill
  # d-47 close: D-121 table_get externref-OOB discharged via
  # fix-makeJitRuntime-clobber of scratch_tables_descriptor[0]
  # (the harness's pre-d-47 makeJitRuntime reset .len = 32 on
  # every assert, clobbering the setupMultiTableScratch's
  # module-derived len). D-124 table_copy + D-123 table_init
  # remain — table_copy.19 (no-import 2-table module) trips
  # populate-side UnsupportedEntrySignature; table_init still
  # SEGVs. Both deferred.
  table_get
  # d-48 enable: `table_size` + `table_grow`. D-122/D-125 closed
  # via `table_grow_fn` runtime callout (parallel to ADR-0059
  # `memory_grow_fn`). Both arches gain `table.grow` emit dispatch
  # + `op_table.emitTableGrow` indirect-call shape; the spec
  # runner harness wires `growableTableGrowFn` which extends
  # `scratch_tables_descriptor[k].len` in place against a fixed
  # `SCRATCH_EXTRA_TABLE_CAPACITY` arena. table_size.0.wasm
  # compiles end-to-end (its rejection at d-46 was actually the
  # table.grow emit gap embedded in the same module's grow-tN
  # exports, not a table.size-specific issue).
  table_size
  table_grow
  table_copy
  table_init
  # d-50 enable: `memory_init`. D-119/D-120 closed via
  # data-segment scratch wiring (mirror of d-49's elem-segment
  # fix): new `scratch_data_segments` / `scratch_data_arena` /
  # `scratch_data_dropped` globals + `populateDataSegments`
  # called from `setupMultiTableScratch`. Active data segments
  # are marked dropped at instantiation per Wasm 2.0 §4.5.5.
  # `bulk` SEGV root cause is also fixed by this chunk, but
  # the corpus surfaces a new architectural gap (D-126):
  # `table.copy` / `table.init` write to `tables_ptr[k].refs`
  # but the legacy table-0 fast path's `funcptr_base` /
  # `typeidx_base` stay stale → call_indirect through table[k]
  # post-mutation reads stale entries. Defer `bulk` until that
  # gap closes.
  memory_init
  # d-41 enable: `memory_trap` — D-114 discharged. The 4× load
  # FAILs were not load-bounds-check bugs; they were caused by a
  # skipped `(assert_return (invoke "i64.store" 0xfff8 0))`
  # zero-store + missing `(i32, i64)` / `(i32, f32)` / `(i32, f64)`
  # assert_trap store shapes. Distiller's trap_supported /
  # supported sets + the runner's dispatchVoidResult /
  # nonSimdRunAssertTrap / invokeActionShape ladders all plumbed
  # the three shapes end-to-end at d-41.
  memory_trap
  # d-40 enable: `float_exprs` — D-116 discharged. The distiller's
  # `action_supported` shape set + the runner's `dispatchVoidResult`
  # / `invokeActionShape` ladders previously omitted `(i32, f32)` /
  # `(i32, f64)` / `(i32, i32, i32)`. Bare `(invoke "init" 0 15.1)`
  # etc. were therefore distilled as `skip-impl action-shape-gap`
  # and never executed; the follow-up `(assert_return (invoke
  # "check" ...))` then read 0 from never-initialised memory.
  # d-40 plumbs the missing shapes end-to-end (entry.zig new
  # helpers + runner ladder + distiller set), and float_exprs lands.
  float_exprs
  # d-37 enable: `elem`. Reftype parse + codegen plumbing (d-32,
  # d-33) covered the BadValType class; cross-module + spectest-
  # host-state imports (12 fails at the d-34 probe baseline) are
  # now caught by the d-37 `hasUnbindableImports` pre-filter that
  # SKIPs modules whose imports the spec runner cannot bind. The
  # `(invoke $module1 ...)` cross-module action assertions are
  # skipped at distillation time via the `action.module` check.
  elem
  # d-36 enable: `start`. SEGV resolved at d-35 (host-import
  # trap stub) + invoke-action plumbing landed at d-36 (`(invoke
  # FN ARGS)` actions in start.wast modules now run and
  # increment memory). With both fixes plus the spec-correct
  # treatment of bare-action traps as PASS (host imports that
  # trap = side-effect "happened", no assertion violated),
  # `start` lands cleanly.
  start
  # d-35 historical (deferred-narrative): `start`. SEGV at host_dispatch_base
  # deref (`undefined` pre-d-35) is FIXED by the d-35 trap-stub
  # wiring in `spec_assert_runner_base.makeJitRuntime`. Residual
  # FAILs blocking NAMES enablement: (a) 4× post-`(invoke "inc")`
  # value-mismatch — the regen-script's manifest distillation
  # classifies `(invoke ACT)` without `expected` as
  # `skip-impl directive-action` (a SKIP), but the spec semantics
  # require the action be executed for its side-effects (the
  # subsequent `(invoke "get")` reads `memory[0]` which the
  # SKIPped `(invoke "inc")` should have incremented). Discharge
  # = teach the distiller to emit `invoke-action FN ARGS` lines
  # and add the runner-side directive to invoke + ignore-result.
  # (b) 1× compile StackTypeMismatch on a start module — a
  # validator-shape mismatch on a sub-fixture. (c) 1× start-init
  # Trap on a module whose start fn calls an unbound import (the
  # trap stub correctly fires + propagates Error.Trap; spec
  # semantics here require the import to be bound). Each is a
  # separate sub-task; `start` stays out of NAMES until they
  # resolve. The d-35 trap-stub fix IS load-bearing — without
  # it, any future probe of `start` (or any corpus that imports
  # functions and has a start fn) would SEGV.
  # d-34: `elem` re-probe deferred. Post-d-32+d-33 (reftype parse
  # + codegen plumbing) the corpus state at the wg-2.0 pin is
  # 14405 PASS / 12 FAIL / 435 SKIP (= +6 PASS, +12 FAIL vs the
  # pre-d-34 14399/0/385 baseline). Residual 12 FAILs decompose
  # as: 3 table-init UnsupportedEntrySignature (D-079 family),
  # 2 compile InvalidFunctype / InvalidFuncIndex (D-079 family),
  # 1 table-init InvalidFunctype, 1 globals-init
  # UnsupportedEntrySignature, 6 findExport(call-N) ExportNotFound
  # (cross-module imports, D-079). All Phase 10+ scope. Enabling
  # `elem` violates the spec gate's 0-FAIL invariant; defer until
  # D-079 (cross-module imports + per-module skip-adr mechanism)
  # discharges. d-34 ships only the wg-2.0 pin alignment of the
  # existing NAMES (regen at the pinned tag flushes residual 3.0
  # syntax from func/local_tee/loop/address manifests; spec gate
  # numbers shift to honest Wasm 2.0-only counts).
)

mkdir -p "$DEST"

for n in "${NAMES[@]}"; do
  src="$UPSTREAM/test/core/$n.wast"
  if [ ! -f "$src" ]; then
    echo "[regen_spec_2_0_assert] missing $src" >&2
    exit 1
  fi
  TMP=$(mktemp -d)
  trap "rm -rf '$TMP'" EXIT

  # §9.9 / 9.9-l-1b-d093-d31 (per ADR-0061): no Wasm 3.0 enables.
  # wabt's default-on set (sign-extension, saturating-float-to-int,
  # bulk-memory-opt, reference-types, multi-value, SIMD) is the
  # Wasm 2.0 baseline. Previously this command passed
  # `--enable-function-references / --enable-tail-call /
  # --enable-extended-const / --enable-multi-memory`, all four of
  # which are Wasm 3.0 proposals. The script's name (`2_0`)
  # demands the parse layer NOT accept 3.0 syntax — those flags
  # were a scope leak. Removing them is M-1 hygiene per the
  # Wasm-2.0 completion plan (`private/wasm2-completion-plan/`).
  if ! ( cd "$TMP" && wast2json "$src" -o "$n.json" >/dev/null 2>&1 ); then
    echo "[regen_spec_2_0_assert] skip $n (wast2json rejected)" >&2
    rm -rf "$TMP"
    trap - EXIT
    continue
  fi

  out_dir="$DEST/$n"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  python3 - "$TMP/$n.json" "$out_dir/manifest.txt" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
def fmt(v):
    return f"{v['type']}:{v['value']}"
lines = []
# §9.9 / 9.9-l-1b-d093-d43 (D-113): module-scoped "state diverged"
# flag. Set when a bare-action `invoke` is skipped because of a
# non-scalar arg (i.e. host-supplied externref/funcref); cleared
# by the next module load OR by a successful (non-skipped)
# `invoke-action`. While set, subsequent `assert_return` lines
# within the same module-state segment skip cleanly as
# `skip-adr-host-state-diverged` — their expected results depend
# on the skipped action's side effects, so the JIT-observed
# values would be a function of the divergent state (e.g.
# `ref_is_null.wast`'s `externref-elem(1) -> 0` requires `init`
# to have written a non-null externref into table 1[1]).
module_state_diverged = False
for c in d['commands']:
    t = c.get('type')
    if t == 'module':
        module_state_diverged = False
        lines.append('module ' + c['filename'])
    elif t == 'assert_return':
        a = c['action']
        # §9.9 / 9.9-l-1b-d093-d43: divergent module state ⇒ skip.
        if module_state_diverged:
            lines.append(f'skip-adr-host-state-diverged assert_return on field={a.get("field","?")!s}')
            continue
        # d-37: cross-module action (`(invoke $mod "fn" ...)`)
        # targets a registered module the spec runner does not
        # model (Track-D scope). Skip cleanly.
        if 'module' in a:
            lines.append(f'skip-adr-cross-module-action assert_return on module={a["module"]!s} field={a.get("field","?")!s}')
            continue
        if a.get('type') != 'invoke':
            lines.append('skip-impl non-invoke-action')
            continue
        args = a.get('args', [])
        results = c.get('expected', [])
        allowed_scalar = lambda x: x['type'] in ('i32', 'i64', 'f32', 'f64')
        if not all(allowed_scalar(x) for x in args):
            lines.append(f'skip-impl non-scalar-arg {a["field"]}')
            # §9.9 / 9.9-l-1b-d093-d48 (D-122/D-125): assert_return
            # actions whose args carry reftype values (e.g.
            # `(invoke "grow" (i32.const 1) (ref.null extern))`)
            # are skipped because the runner ladder lacks the
            # reftype-arg dispatch shape. The follow-up size /
            # observation asserts then read state that depends on
            # the skipped grow's side effect — mark the module's
            # state as diverged so they skip cleanly instead of
            # reporting spurious FAILs against post-grow expected
            # values.
            module_state_diverged = True
            continue
        if len(results) > 1:
            lines.append(f'skip-impl multi-result {a["field"]}')
            continue
        if results and not allowed_scalar(results[0]):
            lines.append(f'skip-impl non-scalar-result {a["field"]}')
            continue
        # Filter against the runner's dispatch ladder (current
        # `spec_assert_runner_non_simd` shape; see
        # `dispatchScalarResult` + `dispatchVoidResult`).
        # Extending the ladder = a separate chunk that adds the
        # missing `entry.callXX_yy` helpers + the dispatch arms.
        arg_kinds = tuple(x['type'] for x in args)
        result_kind = results[0]['type'] if results else 'void'
        supported = {
            ((), 'i32'), ((), 'i64'), ((), 'f32'), ((), 'f64'),
            (('i32',), 'i32'), (('i32',), 'i64'),
            (('i64',), 'i64'), (('i64',), 'i32'),
            (('f32',), 'f32'),
            (('f64',), 'f64'),
            (('i32', 'i32'), 'i32'),
            # 9.9-l-1b-binop: i64 / f32 / f64 2-arg shapes
            # (binop + cmp families).
            (('i64', 'i64'), 'i64'),
            (('i64', 'i64'), 'i32'),
            (('f32', 'f32'), 'f32'),
            (('f32', 'f32'), 'i32'),
            (('f64', 'f64'), 'f64'),
            (('f64', 'f64'), 'i32'),
            (('i64', 'f32', 'f64', 'i32', 'i32'), 'i64'),
            (('i64', 'f32', 'f64', 'i32', 'i32'), 'f64'),
            # 9.9-l-1b-widen: cross-type scalar shapes (conversions.wast).
            (('f32',), 'i32'), (('f64',), 'i32'),
            (('f32',), 'i64'), (('f64',), 'i64'),
            (('i32',), 'f32'), (('i64',), 'f32'),
            (('i32',), 'f64'), (('i64',), 'f64'),
            (('f64',), 'f32'), (('f32',), 'f64'),
            # Void-result shapes:
            ((), 'void'),
            (('i32',), 'void'), (('i64',), 'void'),
            (('f32',), 'void'), (('f64',), 'void'),
            (('i32', 'i32'), 'void'),
            # D-116: float_exprs.wast assert_returns on void-returning
            # actions (`(assert_return (invoke "f<32,64>.simple_x4_sum"
            # 0 16 32))`) that have no expected value.
            (('i32', 'f32'), 'void'), (('i32', 'f64'), 'void'),
            (('i32', 'i32', 'i32'), 'void'),
            # d-41 (D-114): memory_trap.wast assert_return on
            # `(invoke "i64.store" 0xfff8 0)` zero-store between
            # the trap asserts and follow-up loads.
            (('i32', 'i64'), 'void'),
            (('i64', 'f32', 'f64', 'i32', 'i32'), 'void'),
        }
        if (arg_kinds, result_kind) not in supported:
            lines.append(
                f'skip-impl runner-shape-gap '
                f'({" ".join(arg_kinds) or "()"}, {result_kind}) {a["field"]}'
            )
            continue
        # 9.9-l-1b-nan: NaN-pattern result tokens
        # (`nan:canonical` / `nan:arithmetic`) flow through via
        # `base.parseScalarFpExpected` + `matchScalarF32/F64`. No
        # filter needed — the runner compares per the Wasm spec §A.2
        # NaN classes.
        # Trapping-trunc family flows through unfiltered. D-091
        # (§9.9 / 9.9-l-1b-d091-close) fixed the only x86_64
        # boundary-precision miscompile (`i32.trunc_f64_s`); the
        # other 3 signed variants' FP-precision step is coarser
        # than the half-step gap so the original `-2^N` / `JB`
        # bound is spec-conformant.
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        results_s = ' '.join(fmt(x) for x in results) if results else '()'
        lines.append(f'assert_return {a["field"]} {args_s} -> {results_s}')
    elif t == 'assert_trap':
        a = c['action']
        if 'module' in a:
            lines.append(f'skip-adr-cross-module-action assert_trap on module={a["module"]!s} field={a.get("field","?")!s}')
            continue
        if a.get('type') != 'invoke':
            lines.append('skip-impl trap-non-invoke')
            continue
        args = a.get('args', [])
        # 9.9-l-1b-trap-widen: assert_trap dispatch covers
        # 0-arg + (i32) + (i64) + (i32,i32) + (f32) + (f64) shapes.
        # 2+-arg FP shapes still skip-impl until they surface in
        # a corpus that needs them.
        # d-41 (D-114): extend with the `(i32, <T>)` store shapes
        # memory_trap.wast traps at OOB addresses.
        trap_supported = {
            (), ('i32',), ('i64',), ('f32',), ('f64',),
            ('i32', 'i32'),
            ('i64', 'i64'),
            ('i32', 'i64'), ('i32', 'f32'), ('i32', 'f64'),
        }
        arg_kinds = tuple(x['type'] for x in args)
        if any(x['type'] not in ('i32', 'i64', 'f32', 'f64') for x in args):
            lines.append(f'skip-impl trap-non-scalar-arg {a["field"]}')
            continue
        if arg_kinds not in trap_supported:
            lines.append(
                f'skip-impl trap-shape-gap '
                f'({" ".join(arg_kinds) or "()"}) {a["field"]}'
            )
            continue
        # D-091 closed: trap-mode skip-adr removed in lockstep
        # with the assert_return arm above.
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        lines.append(f'assert_trap {a["field"]} {args_s}')
    elif t == 'assert_invalid':
        lines.append(f'assert_invalid {c["filename"]}')
    elif t == 'assert_malformed':
        if c.get('module_type') != 'binary' or 'filename' not in c:
            lines.append('skip-adr-skip_text_format_parser directive-assert_malformed-text')
            continue
        lines.append(f'assert_malformed {c["filename"]}')
    elif t == 'action':
        # d-36: action-without-expected = side-effect-only invoke
        # (e.g. start.wast's `(invoke "inc")` between two
        # `(invoke "get")` asserts). Emit a directive the runner
        # invokes for side-effects + ignores result; traps
        # propagate to FAIL. Same arg/shape constraints as
        # assert_return (the runner's dispatch ladder is shared).
        a = c['action']
        if 'module' in a:
            lines.append(f'skip-adr-cross-module-action action on module={a["module"]!s} field={a.get("field","?")!s}')
            continue
        if a.get('type') != 'invoke':
            lines.append(f'skip-impl action-non-invoke {a.get("type", "?")}')
            continue
        args = a.get('args', [])
        if any(x['type'] not in ('i32', 'i64', 'f32', 'f64') for x in args):
            # §9.9 / 9.9-l-1b-d093-d43 (D-113): host-supplied non-
            # scalar arg (typically externref / funcref) means the
            # bare-action `invoke` cannot execute; subsequent
            # assert_returns in the same module that depend on this
            # action's side effects skip cleanly via
            # `module_state_diverged`.
            lines.append(f'skip-impl action-non-scalar-arg {a["field"]}')
            module_state_diverged = True
            continue
        arg_kinds = tuple(x['type'] for x in args)
        # Reuse the trap_supported shapes — the runner's
        # invoke-action dispatch routes through the same void-
        # result path as assert_trap, just without the
        # expect-a-trap assertion.
        # D-116: extend to cover float_exprs.wast's `init` (i32, f<32,64>)
        # and `f<32,64>.simple_x4_sum` (i32, i32, i32). Both are
        # bare-invoke actions that populate memory for subsequent
        # `(assert_return (invoke "check"/"f*.load" ...))` reads.
        action_supported = {
            (), ('i32',), ('i64',), ('f32',), ('f64',),
            ('i32', 'i32'), ('i32', 'f32'), ('i32', 'f64'),
            ('i32', 'i32', 'i32'),
        }
        if arg_kinds not in action_supported:
            lines.append(
                f'skip-impl action-shape-gap '
                f'({" ".join(arg_kinds) or "()"}) {a["field"]}'
            )
            continue
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        # §9.9 / 9.9-l-1b-d093-d43: a successful (non-skipped)
        # invoke-action resets `module_state_diverged` — its side
        # effects redefine the module's externref/funcref state
        # cleanly relative to the previous skipped action, so
        # subsequent assert_returns can proceed.
        module_state_diverged = False
        lines.append(f'invoke-action {a["field"]} {args_s}')
    else:
        lines.append(f'skip-impl directive-{t}')
with open(dst, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PY

  # Copy referenced .wasm files (module, assert_invalid, assert_malformed).
  while read -r line; do
    set -- $line
    if [ "$1" = "module" ] || [ "$1" = "assert_invalid" ] || [ "$1" = "assert_malformed" ]; then
      if [ -f "$TMP/$2" ]; then
        cp "$TMP/$2" "$out_dir/"
      fi
    fi
  done < "$out_dir/manifest.txt"

  rm -rf "$TMP"
  trap - EXIT
done

echo "[regen_spec_2_0_assert] re-baked: ${NAMES[*]} → $DEST/"
