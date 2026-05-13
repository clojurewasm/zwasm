;; D-093 (d-10) regression: `(if (param i32) (result i32))` else-arm
;; path. The if takes param=1, cond=0 → else-arm consumes the
;; re-pushed param as 1 + (-2) = -1.
;;
;; Provenance: if.wast `param` export with `param(0)`. Pre-d-10 the
;; else-arm body saw the then-arm's result vreg leaked through emit,
;; producing wrong shape and silently miscomputing.
;;
;; Expected: -1 (= 0xFFFFFFFF as u32).
(module
  (func (export "test") (result i32)
    (i32.const 1)
    (if (param i32) (result i32) (i32.const 0)
      (then (i32.const 2) (i32.add))
      (else (i32.const -2) (i32.add)))))
