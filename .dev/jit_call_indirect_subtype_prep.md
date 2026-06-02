# JIT `call_indirect` subtype-matching — execution prep (D-235)

> **Doc-state**: ARCHIVED-IN-PLACE (D-235 RESOLVED 2026-06-03 `2b48dfdc`).
> The bug ANALYSIS (the two real bugs, reference chain) stands; the proposed
> MECHANISM is SUPERSEDED — the shipped fix uses a `jitCallIndirectResolve`
> trampoline called BEFORE marshalling + operand force-spill (regalloc
> inclusive crossing) + gti-materialisation in JIT `setup.zig`, NOT the
> "trampoline on CMP-mismatch" here (which clobbers the op's operands — see
> lesson `2026-06-03-jit-trampoline-mid-op-clobbers-operands` + debt D-235).
>
> PREP for a FRESH CLEAR session to execute D-235 in ONE focused pass (user
> directive 2026-06-02: stop piecemeal; wire it up so the next clear-context
> session does the JIT work "一気に" / not half-baked). This doc is the complete
> design + reference chain + edit plan + test bytes + verification, so the
> execution session does NOT re-investigate. Sibling prep: same shape as
> `.dev/wasm_level_separation_audit.md`. JIT matters for perf — do it properly.

## Goal (one paragraph)

Make the JIT `call_indirect` runtime type check spec-correct (Wasm §3.3.5.5: a
callee whose declared func type is a SUBTYPE of the call's expected type is
ACCEPTED; otherwise TRAP). Today the JIT uses **D-111 structural FuncType
equality** (`canonical_type.canonicalTypeidx` via `funcTypeEql` = params/results
only), which is **finality-blind AND subtype-blind** → two real bugs. The interp
already does this correctly (gti `concreteReaches` authoritative, D-232/ADR-0131);
this ports the same semantics to the JIT backend. Closes the gc/type-subtyping
**4 assert_trap fails (over-accept) + 1 `"run"` return-fail (under-accept)**.

## The two bugs (both REAL — confirmed cyc-5; NOT harness)

The JIT sig-check is `LDR/MOV typeidx_base[idx]; CMP vs expected_d111canonical;
B.NE/JNE → trap`. typeidx_base[idx] = D-111-canonical typeidx (setup, see chain).

- **(A) OVER-acceptance → the 4 gc/type-subtyping assert_trap fails.**
  `$t1=(sub (func))` and `$t2=(sub final (func))` are both FuncType `()->()` →
  `funcTypeEql` true → SAME D-111 canonical → CMP matches → JIT ACCEPTS a
  `call_indirect (type $t1)` on a `$t2`-typed funcref. Spec: `$t2 ≮: $t1` (final,
  distinct identity) → must TRAP. (`fail1`/`fail2` in `gc/raw/type-subtyping.wast`.)
- **(B) UNDER-acceptance → the gc/type-subtyping `"run"` return-fail.**
  `$t1=(sub $t0 (func (result (ref null $t1))))` <: `$t0=(sub (func (result (ref
  null func))))` (declared super + covariant result), but their FuncTypes DIFFER
  (result `(ref null $t1)` vs `(ref null func)`) → different D-111 canonical → CMP
  mismatch → JIT TRAPS a legit subtype call. Must ACCEPT.

Both = ONE root cause: D-111 structural equality instead of the gti subtype check.

## Reference chain (read in order — file:line)

1. **The bug site (arm64)**: `src/engine/codegen/arm64/op_call.zig:222` (`expected_typeidx
   = canonical_type.canonicalTypeidx(ctx.module_types, payload)`) → `:239-250`
   (`LDR W16,[X24,X17,LSL#2]; CMP W16,#expected; B.NE → cind_sig_fixups` = trap).
2. **The bug site (x86_64)**: `src/engine/codegen/x86_64/op_call.zig:411` (same
   `expected_typeidx = canonicalTypeidx`) → `:428-433` (`MOV EAX,[RAX+idx*4]; CMP;
   JNE → trap`). Mirror arm64 exactly.
3. **D-111 canonicalization (the too-coarse check)**: `src/engine/codegen/shared/canonical_type.zig`
   `pub fn canonicalTypeidx(types: []const zir.FuncType, t)` = lowest index with
   `funcTypeEql` (params/results ONLY — no finality, no declared super).
4. **typeidx_base population (where the table's stored typeidx is canonicalized)**:
   `src/engine/setup.zig:618-624` + the element-decode loop that fills `typeidxs_buf`
   with `canonicalTypeidx(...)`; the scalar `JitRuntime.typeidx_base` (`:574`/`:859`)
   and per-table `TableJitCallInfo.typeidx_base`. ALSO `FuncEntity` already carries
   BOTH `.typeidx` (D-111 canonical) AND `.raw_typeidx` (`:441` — `func_typeidxs[i]`)
   → the RAW typeidx is already available; no new decode needed.
5. **The correct subtype check (interp)**: `src/instruction/wasm_3_0/ref_test_ops.zig:125`
   `fn concreteReachesGti(gti, obj_idx, target)` — walks `obj_idx`'s self-inclusive
   `supertype_chain` matching `target` by raw index OR `canonical_ids[s]==canonical_ids[target]`.
   **PRIVATE — make `pub`.** Pub wrapper that takes a Runtime: `:197 concreteReaches`.
6. **gti + canonical_ids (finality-aware)**: `src/feature/gc/type_info.zig` `materialiseGcTypes`
   (`:182`) builds `supertype_chain` + `canonical_ids`; equality includes finality
   (`src/parse/sections.zig:201` `if (finals[ia]!=finals[ib]) return false`). So
   `canonical_ids[$t1] != canonical_ids[$t2]` (distinct finality). gti is materialised
   for subtyping modules per D-232 (`needs_gc_heap OR usesTypeSubtyping`).
7. **The GC-module condition**: `src/feature/gc/needs_heap_detector.zig:78`
   `pub fn usesTypeSubtyping(types: sections.Types) bool` (any non-final OR any with a
   declared super) + `mayUseTypeSubtyping` byte pre-filter. Same predicate the interp
   uses to decide gti materialisation.
8. **The GC trampoline pattern to mirror**: `src/engine/codegen/shared/jit_abi.zig:822`
   `pub fn jitGcRefCast(rt: *JitRuntime, ...) callconv(.c)` — resolves gti from
   `rt.gc_type_infos_ptr`, calls the shared `ref_test_ops` core. New trampoline goes
   next to it.
9. **Interp precedent (the decided semantics)**: ADR-0131 + D-232 (`mvp.zig`
   callIndirectOp: `if (gti) concreteReaches else sigEq`). This is the SAME decision
   ported to JIT — cite ADR-0131, no NEW ADR (codegen mechanism, not new design).
10. **Corpus fixtures**: `test/spec/wasm-3.0-assert/gc/raw/type-subtyping.wast`
    (`fail1`/`fail2` = bug A; `run` = bug B). D-198, D-235.

## Design (crux RESOLVED — use RAW typeidx for subtyping modules, not gti-canonical)

The naive "trampoline on CMP mismatch" does NOT fix bug A (the over-accept has NO
mismatch — D-111 makes $t1/$t2 the same canonical → CMP matches → wrongly accepts).
And gti `canonical_ids` are **u64** (won't fit the `typeidx_base` u32 slot). RESOLUTION:

**For subtyping modules (gti present / `usesTypeSubtyping`), store the RAW typeidx in
`typeidx_base` (not D-111-canonical), and use the RAW expected typeidx at the call
site; on CMP mismatch, CALL a subtype trampoline.** Then:

- exact same type (raw == raw) → CMP match → accept. ✓
- bug A ($t2 vs $t1, distinct raw) → CMP mismatch → trampoline → `concreteReachesGti($t2,$t1)`
  = false (not a subtype; canonical_ids differ by finality) → trap. ✓ FIXED.
- bug B (`$t1<:$t0`, distinct raw) → CMP mismatch → trampoline → `concreteReachesGti($t1,$t0)`
  = true ($t0 in $t1's supertype chain) → accept. ✓ FIXED.
- structurally-equal SAME type across rec groups (distinct raw, genuinely equal) →
  trampoline → canonical_id match → accept. ✓
- **non-GC / non-subtyping modules: UNCHANGED — keep D-111-canonical + B.NE trap**
  (no gti; structural equality is correct there; the trampoline is never emitted).

u32/u64 conflict avoided: raw typeidx is u32 (fits `typeidx_base`); `canonical_ids`
(u64) live INSIDE `concreteReachesGti` (gti array), never in `typeidx_base`.

## Implementation sequence (ONE coordinated change — coupled; do not ship piecemeal)

The setup canonicalization, the call-site expected typeidx, and the mismatch path
must all agree on RAW-vs-D111 keyed on `usesTypeSubtyping`. Thread a single
condition (call it `use_raw_typeidx` / "subtyping module") from compile into both
the setup population and the emit.

1. **`ref_test_ops.zig`**: make `concreteReachesGti` `pub` (no logic change).
2. **`jit_abi.zig`** (next to jitGcRefCast): add
   `pub fn jitCallIndirectSubtypeOk(rt: *JitRuntime, callee_typeidx: u32, expected_typeidx: u32) callconv(.c) u32 {`
   `  const gti = ...rt.gc_type_infos_ptr orelse return 0;`
   `  return @intFromBool(ref_test_ops.concreteReachesGti(gti, callee_typeidx, expected_typeidx)); }`
   (gti null → 0/trap is fine: a non-gti module never hits this path.)
3. **`setup.zig`**: when the module `usesTypeSubtyping` (reuse the parser flag /
   detector), populate `typeidxs_buf` / `typeidx_base` with the **raw** typeidx
   (`func_typeidxs` / `FuncEntity.raw_typeidx`) instead of `canonicalTypeidx`. Else
   keep D-111 canonical. (One branch at the elem-decode loop ~`:618-624` + the
   FuncEntity `typeidx` at `:441` — but note `raw_typeidx` is already stored; the JIT
   table mirror is what matters.)
4. **`arm64/op_call.zig`**: when subtyping module, set `expected_typeidx = raw payload`
   (not canonicalTypeidx); on the sig `B.NE`, instead of jumping straight to trap,
   branch to a subtype-check block: marshal `X0=rt(X19)`, `W1=W16(callee raw)`,
   `W2=expected`, `MOVZ/MOVK X16=&jitCallIndirectSubtypeOk`, `BLR`, `CMP W0,#0`,
   `B.EQ → trap`, else fall through to the funcptr load. Keep the non-subtyping path
   exactly as today (D-111 + B.NE trap). Mind the 4096 imm12 cap (raw typeidx may
   exceed canonical's range — use a reg-loaded compare if needed).
5. **`x86_64/op_call.zig`**: mirror step 4 (JNE → subtype-check block → CALL → JE trap).
6. **Tests**: see below. Then `bash scripts/mac_gate.sh` (test-all) + JIT-corpus
   re-measure + ubuntu kick (x86_64 verifies the x86_64 emit).

## RED tests (TDD — write first, confirm red, then green)

**(A) over-accept — primary, simplest** (`runner_gc_test.zig`, expect `entry.Error.Trap`;
currently returns 42 = the bug):
```
(module
  (type $t1 (sub (func)))        ;; ()->()  open
  (type $t2 (sub final (func)))  ;; ()->()  final — distinct identity, $t2 ≮: $t1
  (type $t3 (func (result i32)))
  (func $f2 (type $t2)) (table funcref (elem $f2))
  (func (export "f") (result i32)
    (call_indirect (type $t1) (i32.const 0))  ;; $f2:$t2 via $t1 → MUST TRAP
    (i32.const 42)))
```
Bytes (verified-by-hand; sub-open=0x50, sub-final=0x4F per sections.zig:434):
`00 61 73 6d 01 00 00 00`
`01 0f 03 50 00 60 00 00 4f 00 60 00 00 60 00 01 7f`  (type)
`03 03 02 01 02`  (func: f2:t1idx=1, f:t3idx=2)
`04 04 01 70 00 01`  (table funcref min 1)
`07 05 01 01 66 00 01`  (export "f" = func 1)
`09 07 01 00 41 00 0b 01 00`  (elem active tbl0 off0 [func0=f2])
`0a 0c 02 02 00 0b 07 00 11 00 00 41 2a 0b`  (code: f2 empty; f: call_indirect t0 tbl0; i32.const 42)
→ runI32Export expects Trap; pre-fix returns 42. CAVEAT: confirm the JIT COMPILES
sub/final func modules (the corpus runs them, so it should; if `JITmodrej`, the test
errors differently — then bug A is a skip not a fail, re-check).

**(B) under-accept** — needs covariant-result subtypes (D-111 must differ). Either
hand-encode `$t0=(sub (func (result funcref)))`, `$t1=(sub $t0 (func (result (ref
null $t1))))`, `$f1:$t1`, `call_indirect (type $t0)` → expect a value (currently
traps); OR rely on the corpus integration check (the `"run"` return-fail flips to
pass). The over-accept unit test + corpus integration is sufficient coverage.

## Verification + no-regression (the green bar)

- New RED test (A) → Trap (green).
- `bash scripts/mac_gate.sh` test-all green (the default gate runs INTERP; this is a
  JIT-emit change — also exercised by runner_gc_test JIT unit tests + the corpus).
- JIT corpus (`ZWASM_SPEC_ENGINE=jit <exe> test/spec/wasm-3.0-assert --fail-detail`):
  **assert_trap fail 4 (gc) → 0; assert_return fail: gc/type-subtyping `run` flips →
  the 762→763 / one of the 2 return fails closed.** (51 memory64 assert_trap stay —
  those are the separate D-234 harness artifact.)
- **MUST NOT regress** the 762 passing JIT assert_return nor any non-GC call_indirect
  (non-subtyping path is byte-identical to today). Watch realworld-run-jit.
- ubuntu kick (x86_64) verifies the x86_64 emit path.

## Risks / cruxes

- The `use_raw_typeidx` condition MUST be identical between setup population and both
  emit sites (else the table's stored key and the call-site expected key disagree →
  every call_indirect in that module mismatches → trampoline-storms or wrong traps).
  Derive both from the same `usesTypeSubtyping`/parser flag.
- Raw typeidx may exceed the 4096 imm12 cap that `canonicalTypeidx` stayed under
  (op_call.zig:226) — load the expected into a reg for the CMP if so.
- gti is per-instance; the trampoline reads `rt.gc_type_infos_ptr` (already wired for
  GC modules). A subtyping-but-no-struct module also materialises gti now (D-232).

## The OTHER remaining JIT gaps (for the same/next session to scope — brief chains)

- **eh/try_table — EH-on-JIT return-fail** (the 2nd of the 2 return fails). Deeper;
  separate. Reference: `codegen/{arm64,x86_64}/ops/wasm_3_0/throw*.zig` +
  `shared/exception_table.zig` + `shared/zwasm_throw.zig` (cross-frame dispatch,
  D-183 landed the interp/JIT unwind). Not D-235 scope.
- **D-234 — 51 memory64 assert_trap FALSE fails** = corpus-runner HARNESS artifact
  (mem64 OOB codegen PROVEN correct via 5 isolated paths). Fix is runner-side: the
  jit-mode assert_trap routes through the persistent `cur_jit`
  (`spec_assert_runner_wasm_3_0.zig` assert_trap branch) which mis-evaluates mem64;
  pin via a GUARDED fresh-instance probe (the naive one SEGVs on import modules) or a
  byte-literal full-fixture unit test. Low priority (codegen correct). Lesson:
  `2026-06-02-jit-corpus-fails-are-often-harness-artifacts`.
- **§10-scope (ADR-0128 "both backends 100%")** = USER-gated. `.dev/phase10_scope_reassessment.md`.
  Determines whether the above must reach 0 for Phase-10 close (multi-memory's 407 JIT
  skips are Phase-14-deferred → JIT skip=0 unreachable in Phase 10 as written).
