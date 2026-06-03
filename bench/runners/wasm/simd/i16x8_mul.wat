;; §11.3 SIMD micro-bench — i16x8.mul (one op class, anti-DCE via v128.store).
(module
  (memory (export "memory") 1)
  (func (export "_start")
    (local $i i32)
    (local $a v128)
    (local.set $i (i32.const 5000000))
    (local.set $a (v128.const i16x8 1 1 1 1 1 1 1 1))
    (block $done
      (loop $loop
        (local.set $a (i16x8.mul (local.get $a) (v128.const i16x8 3 1 1 1 1 1 1 1)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (br_if $loop (local.get $i))))
    (v128.store (i32.const 0) (local.get $a))))
