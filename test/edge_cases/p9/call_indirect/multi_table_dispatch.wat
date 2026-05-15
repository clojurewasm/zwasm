;; D-112 d-42 discharge — multi-table call_indirect dispatch.
;;
;; Module declares two funcref tables. Table 0 holds $dummy (a
;; no-arg, no-result function); table 1 holds $real (a (i32) -> i32
;; multiplier). The exported `test` invokes call_indirect via
;; **table 1**, idx 0, with `(type $sig)` — Wasm spec §3.4.6 +
;; §4.4.10.1. The runtime should dispatch through table 1's funcptr
;; / typeidx view; pre-d-42 the JIT's call_indirect emit ignored
;; ZirInstr.extra (table_idx) and always loaded table 0's view, so
;; the sig check compared `typeidx($dummy)` against `typeidx($sig)`
;; → mismatch → trap.
;;
;; Expected: $real(6) = 6 * 7 = 42.
(module
  (type $sig (func (param i32) (result i32)))
  (func $dummy)
  (func $real (param i32) (result i32)
    (i32.mul (local.get 0) (i32.const 7)))
  (table $t0 1 funcref)
  (table $t1 1 funcref)
  (elem (table $t0) (i32.const 0) func $dummy)
  (elem (table $t1) (i32.const 0) func $real)
  (func (export "test") (result i32)
    (call_indirect $t1 (type $sig) (i32.const 6) (i32.const 0))))
