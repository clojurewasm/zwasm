;; Primality test by trial division.
;;
;; Run: zwasm run examples/wat/28_is_prime.wat --invoke is_prime 97
;; Output: 1
;; Run: zwasm run examples/wat/28_is_prime.wat --invoke is_prime 100
;; Output: 0
(module
  ;; Returns 1 if n is prime, 0 otherwise.
  (func (export "is_prime") (param $n i32) (result i32)
    (local $i i32)
    (if (i32.le_s (local.get $n) (i32.const 1))
      (then (return (i32.const 0))))
    (if (i32.le_s (local.get $n) (i32.const 3))
      (then (return (i32.const 1))))
    (if (i32.eqz (i32.rem_u (local.get $n) (i32.const 2)))
      (then (return (i32.const 0))))

    ;; Check odd divisors from 3 up to sqrt(n).
    (local.set $i (i32.const 3))
    (block $done
      (loop $loop
        ;; if i*i > n, break (n is prime)
        (br_if $done (i32.gt_s
          (i32.mul (local.get $i) (local.get $i))
          (local.get $n)))
        ;; if n % i == 0, not prime
        (if (i32.eqz (i32.rem_u (local.get $n) (local.get $i)))
          (then (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 2)))
        (br $loop)))
    (i32.const 1)))
