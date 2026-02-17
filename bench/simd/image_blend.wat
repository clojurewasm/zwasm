(module
  ;; image_blend benchmark: scalar vs SIMD
  ;; Alpha-blends two 128x128 RGBA images.
  ;; Memory layout: image A at 0, image B at 65536, output at 131072.
  ;; Each image is 128*128*4 = 65536 bytes. Alpha = 128 (50% blend).
  (memory (export "memory") 4)

  ;; Initialize images with deterministic pixel values
  (func $init (export "init")
    (local $i i32) (local $val i32)
    (local.set $i (i32.const 0))
    (local.set $val (i32.const 42))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (i32.const 65536)))
        ;; Image A: gradient
        (local.set $val (i32.and (i32.add (i32.mul (local.get $val) (i32.const 7)) (i32.const 13)) (i32.const 255)))
        (i32.store8 (local.get $i) (local.get $val))
        ;; Image B: inverse gradient
        (i32.store8 (i32.add (i32.const 65536) (local.get $i))
          (i32.sub (i32.const 255) (local.get $val)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; Scalar: blend = (A * alpha + B * (256-alpha)) >> 8
  (func $blend_scalar (export "blend_scalar") (param $iters i32) (result i32)
    (local $iter i32) (local $i i32) (local $a i32) (local $b i32)
    (call $init)
    (local.set $iter (i32.const 0))
    (block $odone
      (loop $oloop
        (br_if $odone (i32.ge_u (local.get $iter) (local.get $iters)))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_u (local.get $i) (i32.const 65536)))
            (local.set $a (i32.load8_u (local.get $i)))
            (local.set $b (i32.load8_u (i32.add (i32.const 65536) (local.get $i))))
            ;; out = (a * 128 + b * 128) >> 8 = (a + b) >> 1
            (i32.store8 (i32.add (i32.const 131072) (local.get $i))
              (i32.shr_u
                (i32.add
                  (i32.mul (local.get $a) (i32.const 128))
                  (i32.mul (local.get $b) (i32.const 128)))
                (i32.const 8)))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)
          )
        )
        (local.set $iter (i32.add (local.get $iter) (i32.const 1)))
        (br $oloop)
      )
    )
    ;; Return first output pixel as verification
    (i32.load8_u (i32.const 131072))
  )

  ;; SIMD: blend 16 bytes at a time using i8x16.avgr_u (unsigned average)
  ;; avgr_u(a,b) = (a + b + 1) >> 1, which is close to 50% blend
  (func $blend_simd (export "blend_simd") (param $iters i32) (result i32)
    (local $iter i32) (local $i i32)
    (call $init)
    (local.set $iter (i32.const 0))
    (block $odone
      (loop $oloop
        (br_if $odone (i32.ge_u (local.get $iter) (local.get $iters)))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_u (local.get $i) (i32.const 65536)))
            (v128.store (i32.add (i32.const 131072) (local.get $i))
              (i8x16.avgr_u
                (v128.load (local.get $i))
                (v128.load (i32.add (i32.const 65536) (local.get $i)))))
            (local.set $i (i32.add (local.get $i) (i32.const 16)))
            (br $loop)
          )
        )
        (local.set $iter (i32.add (local.get $iter) (i32.const 1)))
        (br $oloop)
      )
    )
    ;; Return first output pixel as verification
    (i32.load8_u (i32.const 131072))
  )
)
