;; Wasm cross-feature: call_indirect (table dispatch) × memory64.
;; `test` does `call_indirect` through table[0] (= $worker) — distinct from
;; the call_ref combos: call_indirect performs table-bounds + sig-check
;; dispatch, then $worker addresses `(memory i64 1)`. Locks R15/runtime_ptr
;; survival across the call_indirect bridge into a memory64-addressing callee
;; (the table index stays i32 — memory64 affects memory addressing, not table
;; indexing). Store 42 at addr 32; load it back → 42.
;;
;; Stress axes (test_discipline.md §1): dispatch shape (call_indirect →
;; memory64 op) + ABI boundary (R15 used by both the sig-check trap stub and
;; the callee's vm_base reload). → 42.
;;
;; Provenance: internally derived from 10.P cross-feature close-prep (cyc219);
;; assembled with wasm-tools parse.
(module
  (type $sig (func (result i32)))
  (memory i64 1)
  (table 1 funcref)
  (elem (i32.const 0) $worker)
  (func $worker (type $sig) (result i32)
    i64.const 32
    i32.const 42
    i32.store offset=0 align=2
    i64.const 32
    i32.load offset=0 align=2)
  (func (export "test") (result i32)
    i32.const 0
    call_indirect (type $sig)))
