;; 64-bit integer arithmetic.
;;
;; Run: zwasm run --invoke pow examples/wat/i64_math.wat 2 32
;; Output: 4294967296
;; Run: zwasm run --invoke gcd examples/wat/i64_math.wat 48 18
;; Output: 6
(module
  ;; Integer exponentiation: base^exp (iterative).
  (func (export "pow") (param $base i64) (param $exp i64) (result i64)
    (local $result i64)
    (local.set $result (i64.const 1))
    (block $done
      (loop $loop
        (br_if $done (i64.eqz (local.get $exp)))
        (local.set $result (i64.mul (local.get $result) (local.get $base)))
        (local.set $exp (i64.sub (local.get $exp) (i64.const 1)))
        (br $loop)))
    (local.get $result))

  ;; Greatest common divisor (Euclidean algorithm).
  (func (export "gcd") (param $a i64) (param $b i64) (result i64)
    (local $t i64)
    (block $done
      (loop $loop
        (br_if $done (i64.eqz (local.get $b)))
        (local.set $t (i64.rem_u (local.get $a) (local.get $b)))
        (local.set $a (local.get $b))
        (local.set $b (local.get $t))
        (br $loop)))
    (local.get $a)))
