;; §11.3 SIMD micro-bench — f32x4.mul (one op class, anti-DCE via v128.store).
(module
  (memory (export "memory") 1)
  (func (export "_start")
    (local $i i32)
    (local $a v128)
    (local.set $i (i32.const 5000000))
    (local.set $a (v128.const f32x4 1 1 1 1))
    (block $done
      (loop $loop
        (local.set $a (f32x4.mul (local.get $a) (v128.const f32x4 1.0000001 1 1 1)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (br_if $loop (local.get $i))))
    (v128.store (i32.const 0) (local.get $a))))
