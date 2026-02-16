;; The select instruction: branchless conditional.
;;
;; Run: zwasm run --invoke max examples/wat/06_select.wat 7 3
;; Output: 7
;; Run: zwasm run --invoke min examples/wat/06_select.wat 7 3
;; Output: 3
(module
  ;; Return the larger of two i32 values (branchless).
  (func (export "max") (param $a i32) (param $b i32) (result i32)
    (select
      (local.get $a)
      (local.get $b)
      (i32.gt_s (local.get $a) (local.get $b))))

  ;; Return the smaller of two i32 values (branchless).
  (func (export "min") (param $a i32) (param $b i32) (result i32)
    (select
      (local.get $a)
      (local.get $b)
      (i32.lt_s (local.get $a) (local.get $b))))

  ;; Absolute value (branchless).
  (func (export "abs") (param $x i32) (result i32)
    (select
      (local.get $x)
      (i32.sub (i32.const 0) (local.get $x))
      (i32.ge_s (local.get $x) (i32.const 0)))))
