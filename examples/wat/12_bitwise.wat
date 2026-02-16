;; Bitwise operations: popcount, clz, ctz, rotl.
;;
;; Run: zwasm run --invoke popcount examples/wat/12_bitwise.wat 255
;; Output: 8
;; Run: zwasm run --invoke clz examples/wat/12_bitwise.wat 1
;; Output: 31
;; Run: zwasm run --invoke is_power_of_two examples/wat/12_bitwise.wat 64
;; Output: 1
(module
  ;; Count the number of 1-bits.
  (func (export "popcount") (param $x i32) (result i32)
    (i32.popcnt (local.get $x)))

  ;; Count leading zeros.
  (func (export "clz") (param $x i32) (result i32)
    (i32.clz (local.get $x)))

  ;; Count trailing zeros.
  (func (export "ctz") (param $x i32) (result i32)
    (i32.ctz (local.get $x)))

  ;; Rotate left by r bits.
  (func (export "rotl") (param $x i32) (param $r i32) (result i32)
    (i32.rotl (local.get $x) (local.get $r)))

  ;; Check if x is a power of two (x > 0 and x & (x-1) == 0).
  (func (export "is_power_of_two") (param $x i32) (result i32)
    (i32.and
      (i32.gt_s (local.get $x) (i32.const 0))
      (i32.eqz
        (i32.and
          (local.get $x)
          (i32.sub (local.get $x) (i32.const 1)))))))
