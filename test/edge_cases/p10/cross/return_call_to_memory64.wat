;; Wasm 3.0 cross-feature: tail-call (return_call) × memory64.
;; `test` tail-calls `$worker` via `return_call`; the callee addresses
;; an i64-indexed `(memory i64 1)`. Exercises the interaction of the
;; tail-call frame-teardown JIT path (D-205) with memory64 i64-
;; addressing: after the caller's frame is torn down and control
;; transfers to the callee, the callee's memory64 vm_base/mem_limit
;; reload via R15 must still be correct.
;;
;; Stress axes (test_discipline.md §1): control flow (tail-call frame
;; teardown) + dispatch shape (return_call → memory64 op) + ABI
;; boundary (R15 survival across the tail jump). Store 99 at addr 16;
;; load it back → 99.
;;
;; Provenance: internally derived from the 10.P I3 cross-feature
;; close-prep (cyc215); assembled with wasm-tools parse.
(module
  (type $sig (func (result i32)))
  (memory i64 1)
  (func $worker (type $sig) (result i32)
    i64.const 16
    i32.const 99
    i32.store offset=0 align=2
    i64.const 16
    i32.load offset=0 align=2)
  (func (export "test") (result i32)
    return_call $worker))
