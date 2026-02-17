(module
  ;; dot_product benchmark: scalar vs SIMD (f32x4)
  ;; Computes dot product of two f32 arrays of length N.
  ;; Memory layout: A at offset 0, B at offset 4*N.
  ;; N = 4096 (16KB per array).
  (memory (export "memory") 1)

  ;; Initialize arrays with deterministic values
  (func $init (export "init")
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (i32.const 4096)))
        ;; A[i] = (i+1) as f32
        (f32.store
          (i32.mul (local.get $i) (i32.const 4))
          (f32.convert_i32_u (i32.add (local.get $i) (i32.const 1))))
        ;; B[i] = 1.0 / (i+1) as f32
        (f32.store
          (i32.add (i32.const 16384) (i32.mul (local.get $i) (i32.const 4)))
          (f32.div (f32.const 1.0) (f32.convert_i32_u (i32.add (local.get $i) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; Scalar dot product: iterate element by element
  (func $dot_scalar (export "dot_scalar") (param $iters i32) (result f32)
    (local $iter i32)
    (local $i i32)
    (local $sum f32)
    (call $init)
    (local.set $iter (i32.const 0))
    (block $outer_done
      (loop $outer
        (br_if $outer_done (i32.ge_u (local.get $iter) (local.get $iters)))
        (local.set $sum (f32.const 0))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_u (local.get $i) (i32.const 4096)))
            (local.set $sum
              (f32.add
                (local.get $sum)
                (f32.mul
                  (f32.load (i32.mul (local.get $i) (i32.const 4)))
                  (f32.load (i32.add (i32.const 16384) (i32.mul (local.get $i) (i32.const 4)))))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)
          )
        )
        (local.set $iter (i32.add (local.get $iter) (i32.const 1)))
        (br $outer)
      )
    )
    (local.get $sum)
  )

  ;; SIMD dot product: process 4 f32s at a time using v128
  (func $dot_simd (export "dot_simd") (param $iters i32) (result f32)
    (local $iter i32)
    (local $i i32)
    (local $sum v128)
    (local $tmp f32)
    (call $init)
    (local.set $iter (i32.const 0))
    (block $outer_done
      (loop $outer
        (br_if $outer_done (i32.ge_u (local.get $iter) (local.get $iters)))
        (local.set $sum (v128.const i32x4 0 0 0 0))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_u (local.get $i) (i32.const 4096)))
            (local.set $sum
              (f32x4.add
                (local.get $sum)
                (f32x4.mul
                  (v128.load (i32.mul (local.get $i) (i32.const 4)))
                  (v128.load (i32.add (i32.const 16384) (i32.mul (local.get $i) (i32.const 4)))))))
            (local.set $i (i32.add (local.get $i) (i32.const 4)))
            (br $loop)
          )
        )
        (local.set $iter (i32.add (local.get $iter) (i32.const 1)))
        (br $outer)
      )
    )
    ;; Horizontal sum of f32x4: extract all 4 lanes and add
    (f32.add
      (f32.add
        (f32x4.extract_lane 0 (local.get $sum))
        (f32x4.extract_lane 1 (local.get $sum)))
      (f32.add
        (f32x4.extract_lane 2 (local.get $sum))
        (f32x4.extract_lane 3 (local.get $sum))))
  )
)
