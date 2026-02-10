;; Sieve of Eratosthenes — memory-heavy, loop-heavy
;; sieve(N) returns count of primes up to N
;; Uses linear memory: 1 byte per number
(module
  (memory (export "memory") 16) ;; 1MB = enough for sieve up to ~1M

  (func (export "sieve") (param $n i32) (result i32)
    (local $i i32)
    (local $j i32)
    (local $count i32)

    ;; Initialize: set all bytes to 1 (potential prime)
    (local.set $i (i32.const 2))
    (block $init_done
      (loop $init_loop
        (br_if $init_done (i32.gt_s (local.get $i) (local.get $n)))
        (i32.store8 (local.get $i) (i32.const 1))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $init_loop)
      )
    )

    ;; Sieve
    (local.set $i (i32.const 2))
    (block $sieve_done
      (loop $sieve_loop
        (br_if $sieve_done (i32.gt_s (i32.mul (local.get $i) (local.get $i)) (local.get $n)))
        (if (i32.load8_u (local.get $i))
          (then
            ;; Mark multiples of i as composite
            (local.set $j (i32.mul (local.get $i) (local.get $i)))
            (block $mark_done
              (loop $mark_loop
                (br_if $mark_done (i32.gt_s (local.get $j) (local.get $n)))
                (i32.store8 (local.get $j) (i32.const 0))
                (local.set $j (i32.add (local.get $j) (local.get $i)))
                (br $mark_loop)
              )
            )
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $sieve_loop)
      )
    )

    ;; Count primes
    (local.set $count (i32.const 0))
    (local.set $i (i32.const 2))
    (block $count_done
      (loop $count_loop
        (br_if $count_done (i32.gt_s (local.get $i) (local.get $n)))
        (if (i32.load8_u (local.get $i))
          (then
            (local.set $count (i32.add (local.get $count) (i32.const 1)))
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $count_loop)
      )
    )

    (local.get $count)
  )
)
