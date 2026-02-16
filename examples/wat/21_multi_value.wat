;; Multi-value: functions returning multiple values (Wasm 2.0).
;;
;; Run: zwasm run examples/wat/21_multi_value.wat --invoke swap 10 20
;; Output: 20 10
;; Run: zwasm run examples/wat/21_multi_value.wat --invoke divmod 17 5
;; Output: 3 2
(module
  ;; Swap two values.
  (func (export "swap") (param $a i32) (param $b i32) (result i32 i32)
    (local.get $b)
    (local.get $a))

  ;; Return quotient and remainder.
  (func (export "divmod") (param $a i32) (param $b i32) (result i32 i32)
    (i32.div_s (local.get $a) (local.get $b))
    (i32.rem_s (local.get $a) (local.get $b)))

  ;; Min and max of two values.
  (func (export "minmax") (param $a i32) (param $b i32) (result i32 i32)
    (select (local.get $a) (local.get $b)
      (i32.lt_s (local.get $a) (local.get $b)))
    (select (local.get $a) (local.get $b)
      (i32.gt_s (local.get $a) (local.get $b)))))
