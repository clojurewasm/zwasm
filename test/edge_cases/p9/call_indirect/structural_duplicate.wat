;; D-111 discharge — structural FuncType matching at call_indirect.
;; Two distinct typeidx ($A and $B) share the same shape
;; `(i32) -> i32`. Pre-d-27 the call_indirect sig check used
;; nominal `CMP W16, #expected_typeidx`, so calling via
;; type $A on a func registered with type $B trapped despite
;; structural equivalence (Wasm spec §3.4.6 + §4.4.10.1).
;;
;; d-27 canonicalizes typeidx at codegen + applyTableInit so
;; both sides see the lowest-index typeidx for a given shape.
;; Calling the func via $A returns the func's result (no trap).
(module
  (type $A (func (param i32) (result i32)))
  (type $B (func (param i32) (result i32))) ;; same shape, dup typeidx
  (func $square (type $B) (i32.mul (local.get 0) (local.get 0)))
  (table 1 funcref)
  (elem (i32.const 0) $square)
  (func (export "test") (result i32)
    (call_indirect (type $A) (i32.const 6) (i32.const 0))))
