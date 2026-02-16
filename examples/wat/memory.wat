;; Linear memory: store and load values.
;;
;; Run: zwasm run --invoke sum_array examples/wat/memory.wat 5
;; Output: 15
;; (Stores 1..n into memory then sums them.)
(module
  (memory (export "memory") 1)

  ;; Store values 1..n at consecutive i32 slots, then sum them.
  (func (export "sum_array") (param $n i32) (result i32)
    (local $i i32)
    (local $sum i32)
    (local $addr i32)

    ;; Store phase: mem[i*4] = i+1 for i in 0..n-1
    (local.set $i (i32.const 0))
    (block $done
      (loop $store
        (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
        (i32.store
          (i32.mul (local.get $i) (i32.const 4))
          (i32.add (local.get $i) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $store)))

    ;; Sum phase: sum mem[i*4] for i in 0..n-1
    (local.set $i (i32.const 0))
    (local.set $sum (i32.const 0))
    (block $done2
      (loop $load
        (br_if $done2 (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $sum
          (i32.add (local.get $sum)
            (i32.load (i32.mul (local.get $i) (i32.const 4)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $load)))

    (local.get $sum)))
