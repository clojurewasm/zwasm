;; Collatz conjecture: count steps until n reaches 1.
;; If even: n/2, if odd: 3n+1.
;;
;; Run: zwasm run examples/wat/07_collatz.wat --invoke steps 27
;; Output: 111
;; Run: zwasm run examples/wat/07_collatz.wat --invoke steps 1
;; Output: 0
(module
  (func (export "steps") (param $n i32) (result i32)
    (local $count i32)
    (local.set $count (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.le_s (local.get $n) (i32.const 1)))
        (if (i32.eqz (i32.rem_u (local.get $n) (i32.const 2)))
          (then
            ;; even: n = n / 2
            (local.set $n (i32.div_u (local.get $n) (i32.const 2))))
          (else
            ;; odd: n = 3n + 1
            (local.set $n (i32.add (i32.mul (local.get $n) (i32.const 3)) (i32.const 1)))))
        (local.set $count (i32.add (local.get $count) (i32.const 1)))
        (br $loop)))
    (local.get $count)))
