(module
  ;; matrix_mul benchmark: scalar vs SIMD (f32x4)
  ;; Multiplies two 16x16 f32 matrices. C = A * B.
  ;; Memory layout: A at 0, B at 1024, C at 2048.
  ;; Each matrix is 16*16*4 = 1024 bytes.
  ;; Uses high iteration count to compensate for small matrix size.
  (memory (export "memory") 1)

  ;; Initialize A and B with deterministic values
  (func $init (export "init")
    (local $r i32) (local $c i32) (local $off i32)
    (local.set $r (i32.const 0))
    (block $rdone
      (loop $rloop
        (br_if $rdone (i32.ge_u (local.get $r) (i32.const 16)))
        (local.set $c (i32.const 0))
        (block $cdone
          (loop $cloop
            (br_if $cdone (i32.ge_u (local.get $c) (i32.const 16)))
            (local.set $off (i32.mul (i32.add (i32.mul (local.get $r) (i32.const 16)) (local.get $c)) (i32.const 4)))
            ;; A[r][c] = (r*16+c+1) mod 100 / 100.0
            (f32.store (local.get $off)
              (f32.div
                (f32.convert_i32_u (i32.rem_u (i32.add (i32.add (i32.mul (local.get $r) (i32.const 16)) (local.get $c)) (i32.const 1)) (i32.const 100)))
                (f32.const 100.0)))
            ;; B[r][c] = (c*16+r+1) mod 100 / 100.0
            (f32.store (i32.add (i32.const 1024) (local.get $off))
              (f32.div
                (f32.convert_i32_u (i32.rem_u (i32.add (i32.add (i32.mul (local.get $c) (i32.const 16)) (local.get $r)) (i32.const 1)) (i32.const 100)))
                (f32.const 100.0)))
            (local.set $c (i32.add (local.get $c) (i32.const 1)))
            (br $cloop)
          )
        )
        (local.set $r (i32.add (local.get $r) (i32.const 1)))
        (br $rloop)
      )
    )
  )

  ;; Scalar: C[r][c] = sum_k A[r][k] * B[k][c]
  (func $matmul_scalar (export "matmul_scalar") (param $iters i32) (result f32)
    (local $iter i32) (local $r i32) (local $c i32) (local $k i32) (local $sum f32)
    (local $c_off i32)
    (call $init)
    (local.set $iter (i32.const 0))
    (block $idone
      (loop $iloop
        (br_if $idone (i32.ge_u (local.get $iter) (local.get $iters)))
        (local.set $r (i32.const 0))
        (block $rdone
          (loop $rloop
            (br_if $rdone (i32.ge_u (local.get $r) (i32.const 16)))
            (local.set $c (i32.const 0))
            (block $cdone
              (loop $cloop
                (br_if $cdone (i32.ge_u (local.get $c) (i32.const 16)))
                (local.set $sum (f32.const 0))
                (local.set $k (i32.const 0))
                (block $kdone
                  (loop $kloop
                    (br_if $kdone (i32.ge_u (local.get $k) (i32.const 16)))
                    (local.set $sum
                      (f32.add (local.get $sum)
                        (f32.mul
                          (f32.load (i32.mul (i32.add (i32.mul (local.get $r) (i32.const 16)) (local.get $k)) (i32.const 4)))
                          (f32.load (i32.add (i32.const 1024)
                            (i32.mul (i32.add (i32.mul (local.get $k) (i32.const 16)) (local.get $c)) (i32.const 4)))))))
                    (local.set $k (i32.add (local.get $k) (i32.const 1)))
                    (br $kloop)
                  )
                )
                (local.set $c_off (i32.mul (i32.add (i32.mul (local.get $r) (i32.const 16)) (local.get $c)) (i32.const 4)))
                (f32.store (i32.add (i32.const 2048) (local.get $c_off)) (local.get $sum))
                (local.set $c (i32.add (local.get $c) (i32.const 1)))
                (br $cloop)
              )
            )
            (local.set $r (i32.add (local.get $r) (i32.const 1)))
            (br $rloop)
          )
        )
        (local.set $iter (i32.add (local.get $iter) (i32.const 1)))
        (br $iloop)
      )
    )
    ;; Return C[0][0] as verification
    (f32.load (i32.const 2048))
  )

  ;; SIMD: process 4 columns at a time using f32x4
  (func $matmul_simd (export "matmul_simd") (param $iters i32) (result f32)
    (local $iter i32) (local $r i32) (local $c i32) (local $k i32)
    (local $sum v128) (local $a_splat v128)
    (local $c_off i32)
    (call $init)
    (local.set $iter (i32.const 0))
    (block $idone
      (loop $iloop
        (br_if $idone (i32.ge_u (local.get $iter) (local.get $iters)))
        (local.set $r (i32.const 0))
        (block $rdone
          (loop $rloop
            (br_if $rdone (i32.ge_u (local.get $r) (i32.const 16)))
            ;; Process 4 columns at a time
            (local.set $c (i32.const 0))
            (block $cdone
              (loop $cloop
                (br_if $cdone (i32.ge_u (local.get $c) (i32.const 16)))
                (local.set $sum (v128.const i32x4 0 0 0 0))
                (local.set $k (i32.const 0))
                (block $kdone
                  (loop $kloop
                    (br_if $kdone (i32.ge_u (local.get $k) (i32.const 16)))
                    ;; a_splat = splat(A[r][k])
                    (local.set $a_splat
                      (f32x4.splat
                        (f32.load (i32.mul (i32.add (i32.mul (local.get $r) (i32.const 16)) (local.get $k)) (i32.const 4)))))
                    ;; sum += a_splat * B[k][c..c+3]
                    (local.set $sum
                      (f32x4.add (local.get $sum)
                        (f32x4.mul (local.get $a_splat)
                          (v128.load (i32.add (i32.const 1024)
                            (i32.mul (i32.add (i32.mul (local.get $k) (i32.const 16)) (local.get $c)) (i32.const 4)))))))
                    (local.set $k (i32.add (local.get $k) (i32.const 1)))
                    (br $kloop)
                  )
                )
                ;; Store C[r][c..c+3]
                (local.set $c_off (i32.mul (i32.add (i32.mul (local.get $r) (i32.const 16)) (local.get $c)) (i32.const 4)))
                (v128.store (i32.add (i32.const 2048) (local.get $c_off)) (local.get $sum))
                (local.set $c (i32.add (local.get $c) (i32.const 4)))
                (br $cloop)
              )
            )
            (local.set $r (i32.add (local.get $r) (i32.const 1)))
            (br $rloop)
          )
        )
        (local.set $iter (i32.add (local.get $iter) (i32.const 1)))
        (br $iloop)
      )
    )
    ;; Return C[0][0] as verification
    (f32.load (i32.const 2048))
  )
)
