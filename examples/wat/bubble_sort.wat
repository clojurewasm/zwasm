;; Bubble sort in linear memory.
;;
;; Run: zwasm run --invoke sort examples/wat/bubble_sort.wat
;; Output: 1
;; (Loads [5,3,8,1,2] into memory, sorts, returns 1 if sorted correctly.)
(module
  (memory (export "memory") 1)

  ;; Load test data [5, 3, 8, 1, 2] into memory at offset 0.
  (func $load_data
    (i32.store (i32.const 0) (i32.const 5))
    (i32.store (i32.const 4) (i32.const 3))
    (i32.store (i32.const 8) (i32.const 8))
    (i32.store (i32.const 12) (i32.const 1))
    (i32.store (i32.const 16) (i32.const 2)))

  ;; Bubble sort n i32 values starting at offset 0.
  (func $bubble_sort (param $n i32)
    (local $j i32)
    (local $a i32)
    (local $b i32)
    (local $swapped i32)
    (block $done
      (loop $outer
        (local.set $swapped (i32.const 0))
        (local.set $j (i32.const 0))
        (block $inner_done
          (loop $inner
            (br_if $inner_done
              (i32.ge_s (local.get $j) (i32.sub (local.get $n) (i32.const 1))))
            (local.set $a (i32.load (i32.mul (local.get $j) (i32.const 4))))
            (local.set $b (i32.load (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4))))
            (if (i32.gt_s (local.get $a) (local.get $b))
              (then
                (i32.store (i32.mul (local.get $j) (i32.const 4)) (local.get $b))
                (i32.store (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4)) (local.get $a))
                (local.set $swapped (i32.const 1))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $inner)))
        (br_if $done (i32.eqz (local.get $swapped)))
        (local.set $n (i32.sub (local.get $n) (i32.const 1)))
        (br $outer))))

  ;; Sort the array and verify it becomes [1, 2, 3, 5, 8].
  (func (export "sort") (result i32)
    (call $load_data)
    (call $bubble_sort (i32.const 5))
    (i32.and
      (i32.and
        (i32.eq (i32.load (i32.const 0)) (i32.const 1))
        (i32.eq (i32.load (i32.const 4)) (i32.const 2)))
      (i32.and
        (i32.eq (i32.load (i32.const 8)) (i32.const 3))
        (i32.and
          (i32.eq (i32.load (i32.const 12)) (i32.const 5))
          (i32.eq (i32.load (i32.const 16)) (i32.const 8)))))))
