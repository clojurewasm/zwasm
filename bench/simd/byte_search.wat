(module
  ;; byte_search benchmark: scalar vs SIMD (i8x16)
  ;; Counts occurrences of a target byte in a buffer.
  ;; Memory layout: buffer at offset 0, length 65536 bytes.
  (memory (export "memory") 2)

  ;; Initialize buffer with pseudo-random bytes
  (func $init (export "init")
    (local $i i32)
    (local $val i32)
    (local.set $i (i32.const 0))
    (local.set $val (i32.const 12345))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (i32.const 65536)))
        ;; Simple LCG: val = (val * 1103515245 + 12345) & 0xFF
        (local.set $val
          (i32.and
            (i32.add (i32.mul (local.get $val) (i32.const 1103515245)) (i32.const 12345))
            (i32.const 255)))
        (i32.store8 (local.get $i) (local.get $val))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; Scalar: count bytes matching target, one at a time
  (func $search_scalar (export "search_scalar") (param $iters i32) (param $target i32) (result i32)
    (local $iter i32) (local $i i32) (local $count i32)
    (call $init)
    (local.set $iter (i32.const 0))
    (block $odone
      (loop $oloop
        (br_if $odone (i32.ge_u (local.get $iter) (local.get $iters)))
        (local.set $count (i32.const 0))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_u (local.get $i) (i32.const 65536)))
            (local.set $count
              (i32.add (local.get $count)
                (i32.eq (i32.load8_u (local.get $i)) (local.get $target))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $loop)
          )
        )
        (local.set $iter (i32.add (local.get $iter) (i32.const 1)))
        (br $oloop)
      )
    )
    (local.get $count)
  )

  ;; SIMD: count bytes matching target, 16 at a time using i8x16
  (func $search_simd (export "search_simd") (param $iters i32) (param $target i32) (result i32)
    (local $iter i32) (local $i i32) (local $count i32)
    (local $target_vec v128) (local $matches v128) (local $acc v128)
    (local $batch i32)
    (call $init)
    (local.set $iter (i32.const 0))
    (block $odone
      (loop $oloop
        (br_if $odone (i32.ge_u (local.get $iter) (local.get $iters)))
        (local.set $count (i32.const 0))
        (local.set $target_vec (i8x16.splat (local.get $target)))
        (local.set $i (i32.const 0))
        (block $done
          (loop $loop
            (br_if $done (i32.ge_u (local.get $i) (i32.const 65536)))
            ;; Process in batches of 255*16 to avoid i8 overflow in accumulator
            (local.set $acc (v128.const i32x4 0 0 0 0))
            (local.set $batch (i32.const 0))
            (block $batch_done
              (loop $batch_loop
                (br_if $batch_done (i32.or
                  (i32.ge_u (local.get $batch) (i32.const 255))
                  (i32.ge_u (local.get $i) (i32.const 65536))))
                ;; matches = eq(buf[i..i+16], target)  — 0xFF for match, 0x00 for no match
                (local.set $matches (i8x16.eq (v128.load (local.get $i)) (local.get $target_vec)))
                ;; acc -= matches  (subtracting 0xFF = adding 1)
                (local.set $acc (i8x16.sub (local.get $acc) (local.get $matches)))
                (local.set $i (i32.add (local.get $i) (i32.const 16)))
                (local.set $batch (i32.add (local.get $batch) (i32.const 1)))
                (br $batch_loop)
              )
            )
            ;; Horizontal sum of i8x16 accumulator
            ;; Widen to i16x8, then to i32x4, then extract and sum
            ;; Use i16x8.extadd_pairwise_i8x16_u to sum pairs
            (local.set $acc (i32x4.extadd_pairwise_i16x8_u (i16x8.extadd_pairwise_i8x16_u (local.get $acc))))
            (local.set $count (i32.add (local.get $count)
              (i32.add
                (i32.add
                  (i32x4.extract_lane 0 (local.get $acc))
                  (i32x4.extract_lane 1 (local.get $acc)))
                (i32.add
                  (i32x4.extract_lane 2 (local.get $acc))
                  (i32x4.extract_lane 3 (local.get $acc))))))
            (br $loop)
          )
        )
        (local.set $iter (i32.add (local.get $iter) (i32.const 1)))
        (br $oloop)
      )
    )
    (local.get $count)
  )
)
