;; §11.3 SIMD micro-bench — i8x16.swizzle (one op class, anti-DCE via v128.store).
(module
  (memory (export "memory") 1)
  (func (export "_start")
    (local $i i32)
    (local $a v128)
    (local.set $i (i32.const 5000000))
    (local.set $a (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))
    (block $done
      (loop $loop
        (local.set $a (i8x16.swizzle (local.get $a) (v128.const i8x16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (br_if $loop (local.get $i))))
    (v128.store (i32.const 0) (local.get $a))))
