;; Tail calls: return_call avoids stack overflow (Wasm 3.0).
;; Without tail calls, deep recursion would exhaust the stack.
;;
;; Run: zwasm run --invoke sum examples/wat/25_return_call.wat 1000000
;; Output: 500000500000
;; (Sum 1..n using tail-recursive accumulator — no stack overflow.)
(module
  ;; Tail-recursive sum with accumulator.
  (func $sum_acc (param $n i64) (param $acc i64) (result i64)
    (if (result i64) (i64.eqz (local.get $n))
      (then (local.get $acc))
      (else
        (return_call $sum_acc
          (i64.sub (local.get $n) (i64.const 1))
          (i64.add (local.get $acc) (local.get $n))))))

  ;; Public entry point.
  (func (export "sum") (param $n i64) (result i64)
    (call $sum_acc (local.get $n) (i64.const 0))))
