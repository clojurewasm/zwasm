;; D-093 (d-12) regression: multi-result `(if (result i32 i32))`
;; consumed by `i32.mul`. Pre-d-12 liveness's `.end` for if-frames
;; was transparent; V_else_0 / V_else_1 died at their def_pc so
;; regalloc aliased them, and both merge slots collapsed onto the
;; same value. After d-12: `.else` + `.end` bump V_then_i /
;; V_else_i `last_use_pc` so all 4 vregs have distinct slots and
;; the merge MOVs deliver correct values.
;;
;; Input cond=0 → else-arm → (-3, -4). i32.mul = 12.
;; Mirrors `if.wast:as-binary-operands(0)` minus the unsupported
;; runner-shape-gap (3-i32-arg dispatch).
;;
;; Expected: 12.
(module
  (func (export "test") (result i32)
    (i32.mul
      (if (result i32 i32) (i32.const 0)
        (then (i32.const 3) (i32.const 4))
        (else (i32.const -3) (i32.const -4))))))
