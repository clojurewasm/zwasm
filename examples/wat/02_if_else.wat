;; If/else: conditional branching.
;;
;; Run: zwasm run examples/wat/02_if_else.wat --invoke abs -7
;; Output: 7
;; Run: zwasm run examples/wat/02_if_else.wat --invoke max 3 8
;; Output: 8
(module
  ;; Absolute value: if n < 0 then -n else n.
  (func (export "abs") (param $n i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $n) (i32.const 0))
      (then (i32.sub (i32.const 0) (local.get $n)))
      (else (local.get $n))))

  ;; Maximum of two values.
  (func (export "max") (param $a i32) (param $b i32) (result i32)
    (if (result i32) (i32.gt_s (local.get $a) (local.get $b))
      (then (local.get $a))
      (else (local.get $b)))))
