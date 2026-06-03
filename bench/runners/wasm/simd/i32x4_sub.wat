;; §11.3 SIMD micro-bench — i32x4.sub (one op class, anti-DCE via v128.store).
(module
  (memory (export "memory") 1)
  (func (export "_start")
    (local $i i32)
    (local $a v128)
    (local.set $i (i32.const 5000000))
    (local.set $a (v128.const i32x4 99 99 99 99))
    (block $done
      (loop $loop
        (local.set $a (i32x4.sub (local.get $a) (v128.const i32x4 1 1 1 1)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (br_if $loop (local.get $i))))
    (v128.store (i32.const 0) (local.get $a))))
