;; Wasm 3.0 cross-feature: function-references (call_ref) × memory64.
;; A typed funcref is called via `call_ref`; the callee addresses an
;; i64-indexed `(memory i64 1)`. Exercises the interaction of the
;; funcref-call JIT path (D-207) with memory64 i64-addressing (D-209):
;; the runtime_ptr/R15 set up for call_ref must remain valid for the
;; callee's vm_base/mem_limit reload, and the callee's memory ops must
;; route through the i64 address path even when reached indirectly.
;;
;; Stress axes (test_discipline.md §1): dispatch shape (call_ref →
;; memory64 op) + ABI boundary (R15 survival across call_ref into a
;; memory-using callee). Store 42 at addr 8; load it back → 42.
;;
;; Provenance: internally derived from the 10.P I3 cross-feature
;; close-prep (cyc215); assembled with wasm-tools parse.
(module
  (type $sig (func (result i32)))
  (memory i64 1)
  (func $worker (type $sig) (result i32)
    i64.const 8
    i32.const 42
    i32.store offset=0 align=2
    i64.const 8
    i32.load offset=0 align=2)
  (func (export "test") (result i32)
    ref.func $worker
    call_ref $sig)
  (elem declare func $worker))
