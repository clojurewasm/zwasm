;; Block with typed results: if/else returning values.
;; NOTE: The CLI displays i32 -1 as unsigned 4294967295.
;;
;; Run: zwasm run --invoke classify examples/wat/20_multi_return.wat 0
;; Output: 0
;; Run: zwasm run --invoke classify examples/wat/20_multi_return.wat 42
;; Output: 1
;; Run: zwasm run --invoke classify_neg examples/wat/20_multi_return.wat
;; Output: 4294967295 (= -1 as i32, meaning "negative")
;; (0=zero, 1=positive, -1=negative)
(module
  ;; Classify a number as negative (-1), zero (0), or positive (1).
  (func (export "classify") (param $x i32) (result i32)
    (if (result i32) (i32.eqz (local.get $x))
      (then (i32.const 0))
      (else
        (if (result i32) (i32.gt_s (local.get $x) (i32.const 0))
          (then (i32.const 1))
          (else (i32.const -1))))))

  ;; Hardcoded negative input demo: classify(-5) = -1.
  (func (export "classify_neg") (result i32)
    (if (result i32) (i32.eqz (i32.const -5))
      (then (i32.const 0))
      (else
        (if (result i32) (i32.gt_s (i32.const -5) (i32.const 0))
          (then (i32.const 1))
          (else (i32.const -1)))))))
