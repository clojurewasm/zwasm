;; Mutual recursion: is_even / is_odd.
;;
;; Run: zwasm run examples/wat/23_mutual_recursion.wat --invoke is_even 10
;; Output: 1
;; Run: zwasm run examples/wat/23_mutual_recursion.wat --invoke is_even 7
;; Output: 0
;; Run: zwasm run examples/wat/23_mutual_recursion.wat --invoke is_odd 7
;; Output: 1
(module
  ;; Returns 1 if n is even (via mutual recursion with is_odd).
  (func $is_even (export "is_even") (param $n i32) (result i32)
    (if (result i32) (i32.eqz (local.get $n))
      (then (i32.const 1))
      (else (call $is_odd (i32.sub (local.get $n) (i32.const 1))))))

  ;; Returns 1 if n is odd (via mutual recursion with is_even).
  (func $is_odd (export "is_odd") (param $n i32) (result i32)
    (if (result i32) (i32.eqz (local.get $n))
      (then (i32.const 0))
      (else (call $is_even (i32.sub (local.get $n) (i32.const 1)))))))
