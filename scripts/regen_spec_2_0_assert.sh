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
#
# D-290 tool swap (wabt wast2json → `wasm-tools json-from-wast`)
# validated by: regenerate in place at the wg-2.0 upstream pin →
# `zig build test-spec-wasm-2.0-assert` green with baseline counts →
# revert data (the committed corpus is a snapshot; this is a
# script-only migration). Mirrors `regen_spec_1_0_assert.sh`.

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${WASM_SPEC_REPO:-$HOME/Documents/OSS/WebAssembly/spec}
DEST=test/spec/wasm-2.0-assert

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "[regen_spec_2_0_assert] wasm-tools not found (need it in PATH or dev shell)" >&2
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
  # d-51 batch enable: queued names that land cleanly under the
  # new harness wiring (active-elem/data consumed + cross-module-
  # imports filter + capacity bumps from d-49/d-50).
  # d-52 added `binary` + `unreached-valid` after closing D-127 +
  # D-130 (empty-fn-section bypass + br_table polymorphic-stack).
  # Validator-only corpora (assert_invalid / assert_malformed):
  binary
  binary-leb128
  unreached-valid
  names
  imports
  # `names` + `imports` re-deferred to D-129: distiller char-escape
  # fix (d-53) closes 8 of 12 names FAILs but `names: call
  # print32(i32 i32): Trap` + `imports: call print_i32(i32): Trap`
  # remain — both invoke export wrappers around spectest imports
  # which the d-35 hostImportTrapStub correctly traps; spec asserts
  # expect succeed (side-effect-only). Needs reachability analysis
  # to mark assert_returns transitively calling spectest imports as
  # skip-adr-spectest-import-call.
  comments
  custom
  inline-module
  obsolete-keywords
  token
  unreached-invalid
  # Module-system corpora (mostly cross-module-imports SKIP):
  exports
  linking
  table-sub
  skip-stack-guard-page
  # 2 corpora still deferred (D-128 / D-129):
  # - `names` 9 FAILs: distiller mishandles export names with
  #   special chars (backslash, quotes) producing malformed
  #   manifest lines (D-128); 1× spectest-import-trap.
  # - `imports` 1 FAIL: spectest-import call traps via stub but
  #   spec asserts "succeeds" (side-effect-only) — distiller
  #   needs to mark these skip-adr (D-129).
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

  # D-290: wasm-tools enables all proposals by default (no
  # --enable-* flags). The §9.9 / 9.9-l-1b-d093-d31 (ADR-0061)
  # no-Wasm-3.0-enables concern is moot at the baker level: the
  # curated NAMES below come from the wg-2.0 tag, so no 3.0 syntax
  # reaches the baker regardless of what it would accept.
  if ! ( cd "$TMP" && wasm-tools json-from-wast "$src" -o "$n.json" --wasm-dir . >/dev/null 2>&1 ); then
    echo "[regen_spec_2_0_assert] skip $n (wasm-tools json-from-wast rejected)" >&2
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
    # §9.9 / 9.9-l-1b-d093-d63: reftypes alias onto the i64 8-byte
    # gpr-class scalar path per ADR-0061 / d-33 codegen plumbing.
    # At the manifest/runner level we encode `externref N` and
    # `funcref N` as `i64:<host_extern_encoding(N)>`; `ref.null`
    # → `i64:0`. The JIT round-trips the u64 through host
    # invocation (param marshal at d-33 treats reftypes identically
    # to i64); host-supplied refs flow back unchanged because the
    # runtime stores raw u64 refs without re-encoding.
    #
    # **Externref value-zero collision** (ref_is_null.wast bug
    # surfaced post-d-63): the spec lets the host bind `ref.extern
    # 0` as a distinct non-null reference, but plain `i64:0`
    # collides with `ref.null extern` in our encoding (both decode
    # as 0 → `ref.is_null` returns 1). Encode `ref.extern N` as
    # `0x8000_0000_0000_0000 | (N+1)` so the resulting u64 is
    # never zero AND is distinguishable from FuncEntity pointers
    # (heap addresses on both Mac aarch64 / Linux x86_64 live in
    # the lower 48 bits; setting bit 63 puts host externrefs in
    # an address-space-disjoint band). funcref N as a host-supplied
    # value is rare (the wast harness usually constructs funcref
    # values via `ref.func $f` inside the module, not via host
    # args) — same encoding for symmetry.
    if v['type'] in ('externref', 'funcref'):
        if v['value'] == 'null':
            return 'i64:0'
        n = int(v['value'])
        host_ref = (1 << 63) | (n + 1)
        return f'i64:{host_ref}'
    # D-290 baker normalization (wabt wast2json → wasm-tools
    # json-from-wast): wabt emits i32/i64 values UNSIGNED
    # (4294967295); wasm-tools emits them SIGNED (-1), sometimes as a
    # JSON number rather than a string. The committed baseline + spec
    # runner manifest use unsigned decimals — fold any negative into
    # its unsigned width here, accepting both str and int inputs.
    # f32/f64 are bit-pattern decimals in both tools (identical), and
    # `nan:canonical` / `nan:arithmetic` tokens pass through unchanged.
    t = v['type']
    val = v['value']
    if t in ('i32', 'i64'):
        n = int(val)
        if n < 0:
            n += (1 << 32) if t == 'i32' else (1 << 64)
        val = str(n)
    return f"{t}:{val}"

def kind_alias(t):
    """ADR-0061: reftype param/result classes alias onto the i64
    GPR-class scalar path. Maps arg/result type for arg_kinds /
    result_kind tuple-based dispatch lookup."""
    return 'i64' if t in ('externref', 'funcref') else t
def norm_wasm(fn):
    # wasm-tools emits some valid TEXT modules as `.wat` where wabt
    # compiled `.wasm`; the copy loop converts via `wasm-tools parse`,
    # so normalize the manifest name to its `.wasm` form here.
    return fn[:-4] + '.wasm' if fn.endswith('.wat') else fn
# §9.9 / 9.9-l-1b-d093-d53 (D-128): export names that contain
# control chars / whitespace / quotes / colon are emitted as
# `:hex:<utf8-hex>` so the manifest parser (whitespace-split)
# stays single-line + token-aligned. The runner's `decodeFnName`
# reverses this before passing to `findExportFunc`.
def quote_field(name):
    if not name:
        return ':hex:'
    safe = all(0x21 <= ord(c) <= 0x7E and c not in ("'", ':') for c in name)
    if safe:
        return name
    return ':hex:' + name.encode('utf-8').hex()
lines = []
# §9.9 / 9.9-l-1b-d093-d43 (D-113): module-scoped "state diverged"
# flag. Set when a bare-action `invoke` is skipped because of a
# non-scalar arg (i.e. host-supplied externref/funcref); cleared
# by the next module load OR by a successful (non-skipped)
# `invoke-action`. While set, subsequent `assert_return` lines
# within the same module-state segment skip cleanly as
# `skip-adr-skip_host_state_diverged` — their expected results depend
# on the skipped action's side effects, so the JIT-observed
# values would be a function of the divergent state (e.g.
# `ref_is_null.wast`'s `externref-elem(1) -> 0` requires `init`
# to have written a non-null externref into table 1[1]).
module_state_diverged = False
for c in d['commands']:
    t = c.get('type')
    if t == 'module':
        module_state_diverged = False
        lines.append('module ' + norm_wasm(c['filename']))
    elif t == 'assert_return':
        a = c['action']
        # §9.9 / 9.9-l-1b-d093-d43: divergent module state ⇒ skip.
        if module_state_diverged:
            lines.append(f'skip-adr-skip_host_state_diverged assert_return on field={a.get("field","?")!s}')
            continue
        # d-37: cross-module action (`(invoke $mod "fn" ...)`)
        # targets a registered module the spec runner does not
        # model (Track-D scope). Skip cleanly.
        if 'module' in a:
            lines.append(f'skip-adr-skip_cross_module_action assert_return on module={a["module"]!s} field={a.get("field","?")!s}')
            continue
        if a.get('type') == 'get':
            # §9.12-E / B137: same-module `(get "field")` action.
            # Emit `get-action <field> <type> <value>` so the runner's
            # handle_get_action callback can look up the global by
            # export name + compare its current value vs expected.
            # `c.get("expected")` is a singleton list for `get`.
            expected = c.get('expected', [])
            if len(expected) == 1 and expected[0].get('type') in ('i32', 'i64', 'f32', 'f64'):
                etype = expected[0]['type']
                eval_ = expected[0].get('value', '0')
                lines.append(f'get-action {a["field"]} {etype} {eval_}')
                continue
            # Other get-action shapes (v128, externref result, missing
            # value) still skip-impl until the relevant callback shape
            # lands. Conservative; matches the prior behaviour.
            lines.append('skip-impl non-invoke-action')
            continue
        if a.get('type') != 'invoke':
            lines.append('skip-impl non-invoke-action')
            continue
        args = a.get('args', [])
        results = c.get('expected', [])
        # §9.9 / 9.9-l-1b-d093-d63: `externref` / `funcref` accepted
        # as scalar-equivalent (aliased onto i64 GPR-class path per
        # ADR-0061 / d-33). The prior `module_state_diverged` set
        # here (d-48's D-122/D-125 workaround) is now unreachable
        # for the rebound reftype args — kept conservative for any
        # genuinely-unsupported future type that still trips this
        # arm (e.g. v128 args, which the non-SIMD runner explicitly
        # rejects).
        allowed_scalar = lambda x: x['type'] in ('i32', 'i64', 'f32', 'f64', 'externref', 'funcref')
        if not all(allowed_scalar(x) for x in args):
            lines.append(f'skip-impl non-scalar-arg {a["field"]}')
            module_state_diverged = True
            continue
        # Multi-result handling (Phase 9 Cat II per ADR-0065). The
        # `supported_multi` set names every `(arg-kinds, result-kinds)`
        # tuple the runner's `dispatchMultiResult` ladder currently
        # accepts; un-listed shapes still emit `skip-impl multi-result`
        # and surface in subsequent Cat II chunks.
        if len(results) > 1:
            if not all(allowed_scalar(x) for x in results):
                lines.append(f'skip-impl non-scalar-result {a["field"]}')
                continue
            arg_kinds = tuple(kind_alias(x['type']) for x in args)
            result_kinds = tuple(kind_alias(x['type']) for x in results)
            supported_multi = {
                # Phase 9 Cat II chunk (b)-1 — add64_u_with_carry family.
                (('i64', 'i64', 'i32'), ('i64', 'i32')),
                # Phase 9 Cat II chunk (b)-2 — 2-result mixed-width shapes
                # where each FuncRet_* field is naturally >= 8 bytes via
                # C-ABI alignment, forcing X0+X1 / RAX+RDX register-pair
                # return.
                ((), ('i32', 'i64')),
                ((), ('i64', 'i32')),
                # Phase 9 Cat II chunk (b)-3 — same-width 2× int shapes
                # via u64-padded FuncRet_* layout (see entry.zig
                # `FuncRet_i32i32` doc-comment). Mixed int+float still
                # D-137 residual.
                ((), ('i32', 'i32')),
                (('i32',), ('i32', 'i32')),
                # Phase 9 Cat II chunk (b)-4 — break-br_if-num-num,
                # break-br_table-num-num.
                (('i32',), ('i32', 'i64')),
                # Phase 9 Cat II chunk (b)-5 — HFA<f64,f64> return:
                # type-f64-f64-value (f64.wast `(result f64 f64)`).
                ((), ('f64', 'f64')),
                # Phase 9 Cat II chunk (b)-d-1 — Class B mixed
                # int+float per ADR-0069. `(i32, f64)` + `(f64,
                # i32)` shapes. arm64 inline-asm thunk; x86_64
                # SysV native per-eightbyte ABI; Win64 deferred.
                ((), ('i32', 'f64')),
                ((), ('f64', 'i32')),
                # Phase 9 Cat II chunk (b)-d-3 — `(f64, f32)`
                # heterogeneous-FP (D-146 close). x86_64 SysV
                # uses an inline-asm thunk to capture XMM0 +
                # XMM1 directly (Zig 0.16 `splitType` TODO for
                # mixed-eightbyte SSE struct return). arm64
                # inline-asm thunk via FMOV D0/D1.
                ((), ('f64', 'f32')),
                # Phase 9 Cat II chunk (b)-e-4 — Class C MEMORY-
                # class 3-int-result shapes. ADR-0069 §Phase 2.
                # arm64: X8 hidden-result-ptr (AAPCS64 §6.8.2);
                # x86_64 SysV: R11 zwasm-internal hidden-result-ptr
                # (ADR-0026 2026-05-18 amend; entry helpers thunk
                # Zig's RDI/RSI convention into RDI/R11). Spec
                # fixtures: value-i32-i32-i32 / return-i32-i32-i32
                # / break-i32-i32-i32 (func.wast) + 4×
                # break-multi-value (block/loop/if×2). The if.wast
                # `(i32) → (i32,i32,i64)` was gated behind D-147
                # (parallel-move cycle in multi-value if-merge);
                # closed at the parallel-move resolver chunk.
                ((), ('i32', 'i32', 'i32')),
                ((), ('i32', 'i32', 'i64')),
                (('i32',), ('i32', 'i32', 'i64')),
                # ADR-0069 §Phase 3 D-140 / D-148 (closed at
                # 435bebf3 via the LLVM-backend workaround for
                # Codeberg ziglang/zig#35343): large-sig 17-param
                # 16-result Class C (func.wast `large-sig`). The
                # close commit hand-flipped the committed manifest
                # but left this set stale; D-290 regen-validation
                # surfaced the gap — tuple added so regen reproduces
                # the committed corpus.
                (('i32', 'i64', 'f32', 'f32', 'i32', 'f64', 'f32',
                  'i32', 'i32', 'i32', 'f32', 'f64', 'f64', 'f64',
                  'i32', 'i32', 'f32'),
                 ('f64', 'f32', 'i32', 'i32', 'i32', 'i64', 'f32',
                  'i32', 'i32', 'f32', 'f64', 'f64', 'i32', 'f32',
                  'i32', 'f64')),
            }
            if (arg_kinds, result_kinds) not in supported_multi:
                lines.append(f'skip-impl multi-result {a["field"]}')
                continue
            args_s = ' '.join(fmt(x) for x in args) if args else '()'
            results_s = ' '.join(fmt(x) for x in results)
            lines.append(f'assert_return {quote_field(a["field"])} {args_s} -> {results_s}')
            continue
        if results and not allowed_scalar(results[0]):
            lines.append(f'skip-impl non-scalar-result {a["field"]}')
            continue
        # Filter against the runner's dispatch ladder (current
        # `spec_assert_runner_non_simd` shape; see
        # `dispatchScalarResult` + `dispatchVoidResult`).
        # Extending the ladder = a separate chunk that adds the
        # missing `entry.callXX_yy` helpers + the dispatch arms.
        arg_kinds = tuple(kind_alias(x['type']) for x in args)
        result_kind = kind_alias(results[0]['type']) if results else 'void'
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
            # §9.9 / 9.9-l-1b-d093-d55: 3-/4-arg + mixed FP/i32 shapes
            # to drain the `runner-shape-gap` skip-impl backlog.
            (('i32', 'i32', 'i32'), 'i32'),
            (('i32', 'i64'), 'i64'),
            (('i64', 'i64', 'i32'), 'i64'),
            (('f32', 'f32', 'f32'), 'f32'),
            (('f32', 'f32', 'f32', 'f32'), 'f32'),
            (('f32', 'f32', 'i32'), 'f32'),
            (('f32', 'f64'), 'f32'),
            (('f64', 'f32'), 'f32'),
            (('f64', 'f64', 'f64'), 'f64'),
            (('f64', 'f64', 'f64', 'f64'), 'f64'),
            (('f64', 'f64', 'i32'), 'f64'),
            # d-41 (D-114): memory_trap.wast assert_return on
            # `(invoke "i64.store" 0xfff8 0)` zero-store between
            # the trap asserts and follow-up loads.
            (('i32', 'i64'), 'void'),
            (('i64', 'f32', 'f64', 'i32', 'i32'), 'void'),
            # §9.9 / 9.9-l-1b-d093-d61: residual runner-shape-gap
            # drain (FP-result 2-arg-i32 + i32-result 3-arg-FP +
            # mixed-arg shapes surfaced after d-55).
            (('i32', 'i32'), 'f32'),
            (('i32', 'i32'), 'f64'),
            (('f32', 'f32', 'f32'), 'i32'),
            (('f64', 'f64', 'f64'), 'i32'),
            (('i32', 'f64', 'i32'), 'i32'),
            (('f64', 'f64', 'f64', 'f64', 'f64', 'f64', 'f64', 'f64'), 'f64'),
            (('f32', 'i32', 'i64', 'i32', 'f64', 'i32'), 'f64'),
            # §9.9 / 9.9-l-1b-d093-d63: reftype-aliased table_grow /
            # table_fill / check-table-null shapes. reftype args
            # arrive aliased as i64 (per kind_alias); shapes here
            # are post-alias forms.
            (('i32', 'i64'), 'i32'),
            (('i32', 'i32'), 'i64'),
            (('i32', 'i64', 'i32'), 'void'),
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
        lines.append(f'assert_return {quote_field(a["field"])} {args_s} -> {results_s}')
    elif t == 'assert_trap':
        a = c['action']
        if 'module' in a:
            lines.append(f'skip-adr-skip_cross_module_action assert_trap on module={a["module"]!s} field={a.get("field","?")!s}')
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
        # d-56: `(i32, i32, i32)` covers memory_copy / memory_fill /
        # memory_init / call.wast 3-arg trap shapes (mirror of d-55
        # runner-shape-gap fix on the trap path).
        trap_supported = {
            (), ('i32',), ('i64',), ('f32',), ('f64',),
            ('i32', 'i32'),
            ('i64', 'i64'),
            ('i32', 'i64'), ('i32', 'f32'), ('i32', 'f64'),
            ('i32', 'i32', 'i32'),
            # §9.9 / 9.9-l-1b-d093-d63: reftype-aliased table_fill
            # OOB-trap asserts after kind_alias.
            ('i32', 'i64', 'i32'),
        }
        # §9.9 / 9.9-l-1b-d093-d63: alias externref/funcref onto
        # i64 for the shape-tuple lookup (per ADR-0061).
        arg_kinds = tuple(kind_alias(x['type']) for x in args)
        if any(x['type'] not in ('i32', 'i64', 'f32', 'f64', 'externref', 'funcref') for x in args):
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
        lines.append(f'assert_trap {quote_field(a["field"])} {args_s}')
    elif t == 'assert_exhaustion':
        # §9.9 / 9.9-l-1b-d093-d62: spec assertion that the module
        # traps due to call-stack exhaustion (runaway recursion).
        # In our JIT, recursion accumulates native AAPCS64/SysV
        # stack frames until the kernel's stack guard page is hit;
        # the resulting SIGSEGV is converted to `Error.Trap` by the
        # d-29 sigsetjmp/siglongjmp handler installed in
        # `spec_assert_runner_base.installSigsegvHandler`. From the
        # runner's perspective, the PASS criterion ("invocation
        # trapped") is identical to assert_trap; the directive name
        # is preserved here for manifest auditability + traceability
        # to the originating .wast directive. Arg-shape filter
        # mirrors the assert_trap arm — keep the two in lockstep.
        a = c['action']
        if 'module' in a:
            lines.append(f'skip-adr-skip_cross_module_action assert_exhaustion on module={a["module"]!s} field={a.get("field","?")!s}')
            continue
        if a.get('type') != 'invoke':
            lines.append('skip-impl exhaustion-non-invoke')
            continue
        args = a.get('args', [])
        if any(x['type'] not in ('i32', 'i64', 'f32', 'f64', 'externref', 'funcref') for x in args):
            lines.append(f'skip-impl exhaustion-non-scalar-arg {a["field"]}')
            continue
        exhaustion_supported = {
            (), ('i32',), ('i64',), ('f32',), ('f64',),
            ('i32', 'i32'),
            ('i64', 'i64'),
            ('i32', 'i64'), ('i32', 'f32'), ('i32', 'f64'),
            ('i32', 'i32', 'i32'),
        }
        # §9.9 / 9.9-l-1b-d093-d63: alias reftypes onto i64 per
        # ADR-0061; assert_exhaustion shapes converge on i64.
        arg_kinds = tuple(kind_alias(x['type']) for x in args)
        if arg_kinds not in exhaustion_supported:
            lines.append(
                f'skip-impl exhaustion-shape-gap '
                f'({" ".join(arg_kinds) or "()"}) {a["field"]}'
            )
            continue
        args_s = ' '.join(fmt(x) for x in args) if args else '()'
        lines.append(f'assert_exhaustion {quote_field(a["field"])} {args_s}')
    elif t == 'assert_invalid':
        lines.append(f'assert_invalid {c["filename"]}')
    elif t == 'assert_uninstantiable':
        # §9.9 / 9.9-l-1b-d093-d57: module is valid (compiles) but
        # instantiation fails — typically OOB active data/elem
        # segment, or start fn traps. Runner attempts the same
        # init path as `module` directive and PASSes if any step
        # fails, FAILs if instantiation succeeds.
        if c.get('module_type') != 'binary' or 'filename' not in c:
            lines.append('skip-impl directive-assert_uninstantiable-non-binary')
            continue
        lines.append(f'assert_uninstantiable {c["filename"]}')
    elif t == 'assert_unlinkable':
        # §9.9 / 9.9-l-1b-d093-d58: module fails to link due to
        # `unknown import` or `incompatible import type`. Runner
        # PASSes if either compileWasm rejects the module OR
        # hasUnbindableImports filter trips (any non-spectest
        # module name OR any non-function spectest import — both
        # structurally unlinkable in our spec scaffold).
        if c.get('module_type') != 'binary' or 'filename' not in c:
            lines.append('skip-impl directive-assert_unlinkable-non-binary')
            continue
        lines.append(f'assert_unlinkable {c["filename"]}')
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
            lines.append(f'skip-adr-skip_cross_module_action action on module={a["module"]!s} field={a.get("field","?")!s}')
            continue
        if a.get('type') != 'invoke':
            lines.append(f'skip-impl action-non-invoke {a.get("type", "?")}')
            continue
        args = a.get('args', [])
        if any(x['type'] not in ('i32', 'i64', 'f32', 'f64', 'externref', 'funcref') for x in args):
            # §9.9 / 9.9-l-1b-d093-d43 (D-113): host-supplied non-
            # scalar arg (typically externref / funcref) means the
            # bare-action `invoke` cannot execute; subsequent
            # assert_returns in the same module that depend on this
            # action's side effects skip cleanly via
            # `module_state_diverged`.
            # §9.9 / 9.9-l-1b-d093-d63: reftypes now accepted as
            # i64-aliased scalars; this skip arm now catches only
            # genuinely-unsupported types (v128 etc.).
            lines.append(f'skip-impl action-non-scalar-arg {a["field"]}')
            module_state_diverged = True
            continue
        arg_kinds = tuple(kind_alias(x['type']) for x in args)
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
            # §9.9 / 9.9-l-1b-d093-d63: reftype-aliased table_fill /
            # table.init invoke-action shapes (e.g. ref_is_null's
            # `init` populating the externref table before observation
            # asserts run).
            ('i64',),
            ('i32', 'i64'),
            ('i32', 'i64', 'i32'),
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
        lines.append(f'invoke-action {quote_field(a["field"])} {args_s}')
    elif t == 'register':
        # §9.9 / 9.9-l-1b-d093-d59 (Phase 9 §9.9-III chunk (c)-1c,
        # ADR-0065): `(register "alias" $M)` binds the named module
        # under a host-import key for subsequent `(invoke $alias
        # "fn" ...)` from a later module. The runner's session-
        # local registry (`runCorpus.registered`) populates on this
        # directive; consumer is chunk (c)-2's cross-module import
        # linker. Pre-(c)-1c this was emitted as
        # `skip-adr-skip_cross_module_register` (now superseded —
        # the directive is no longer a no-op classification).
        as_name = c.get('as', '?')
        lines.append(f'register {as_name!s}')
    else:
        lines.append(f'skip-impl directive-{t}')
with open(dst, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PY

  # Materialize referenced .wasm files (D-290 tool-difference rules):
  #   - `module` (valid): strip wasm-tools' name section; if emitted as
  #     a `.wat` text module, parse it to .wasm first.
  #   - `assert_uninstantiable` / `assert_unlinkable`: valid binaries
  #     (they fail at instantiation / link, not decode) — strip too.
  #     The distiller's `module_type == 'binary'` filter guarantees a
  #     `.wasm` filename for these.
  #   - `assert_invalid` / `assert_malformed`: intentionally
  #     type-invalid / malformed — copy RAW (never re-encode/strip).
  while read -r d1 file _; do
    case "$d1" in
      module)
        base="${file%.wasm}"
        if [ -f "$TMP/$file" ]; then
          wasm-tools strip --all "$TMP/$file" -o "$out_dir/$file"
        else
          wasm-tools parse "$TMP/$base.wat" -o "$TMP/$base.fromwat.wasm"
          wasm-tools strip --all "$TMP/$base.fromwat.wasm" -o "$out_dir/$file"
        fi
        ;;
      assert_uninstantiable|assert_unlinkable)
        wasm-tools strip --all "$TMP/$file" -o "$out_dir/$file"
        ;;
      assert_invalid|assert_malformed)
        if [ -f "$TMP/$file" ]; then
          cp "$TMP/$file" "$out_dir/"
        fi
        ;;
    esac
  done < "$out_dir/manifest.txt"

  rm -rf "$TMP"
  trap - EXIT
done

# §9.9 / 9.9-l-1b-d093-d64 (D-132): targeted skip removed. The
# d-63 funcref-table.set/get roundtrip bug was root-caused at
# d-64 to arm64 `op_table.zig` hardcoding X10/X11/X12 as scratch
# while those registers were in `allocatable_caller_saved_scratch_gprs`
# (= a regalloc-pool / emit-internal-scratch contract mismatch
# that clobbered any vreg landed on X10/X11/X12 whose live range
# crossed a table.get / table.set). Fix in
# `src/engine/codegen/arm64/abi.zig`: shrink the allocatable
# pool to `[9, 13]` (removed 10, 11, 12). Regression test:
# `test/edge_cases/p9/table_ops/funcref_roundtrip.{wat,wasm,expect}`.

echo "[regen_spec_2_0_assert] re-baked: ${NAMES[*]} → $DEST/"
