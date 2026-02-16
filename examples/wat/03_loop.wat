;; Loop: sum integers from 1 to n.
;;
;; Run: zwasm run examples/wat/03_loop.wat --invoke sum 100
;; Output: 5050
(module
  (func (export "sum") (param $n i32) (result i32)
    (local $i i32)
    (local $acc i32)
    (local.set $i (i32.const 1))
    (block $break
      (loop $continue
        ;; if i > n, break
        (br_if $break (i32.gt_s (local.get $i) (local.get $n)))
        ;; acc += i
        (local.set $acc
          (i32.add (local.get $acc) (local.get $i)))
        ;; i += 1
        (local.set $i
          (i32.add (local.get $i) (i32.const 1)))
        (br $continue)))
    ;; Return accumulated sum.
    local.get $acc))
