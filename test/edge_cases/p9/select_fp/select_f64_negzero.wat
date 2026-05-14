;; D-115 d-39 probe (f64 sibling of select_f32_negzero): untyped
;; `select` on f64 operands. Pre-d-39 emit dispatched the gpr32
;; CSEL path on FP-class operands, reading val1/val2 from the
;; wrong spill slot (the GPR-class slot at the same id rather
;; than the FP-class slot the operand lives in). For f64 the
;; bug also truncated to 4 bytes; this fixture's lower 32 bits
;; alone don't disambiguate val1/val2, so we reinterpret-cast
;; the f64 result and reduce by xor-folding upper and lower
;; halves to confirm the full 64 bits round-trip correctly.
;;
;; Expected: select(-0x1p-1074, +0x1p-1074, cond=1) = -0x1p-1074
;; bits = 0x8000000000000001; (lo ^ hi) = 0x80000001 = i32:-2147483647
(module
  (func (export "test") (result i32)
    (i32.xor
      (i32.wrap_i64
        (i64.reinterpret_f64
          (select
            (f64.const -0x1p-1074)
            (f64.const 0x1p-1074)
            (i32.const 1))))
      (i32.wrap_i64
        (i64.shr_u
          (i64.reinterpret_f64
            (select
              (f64.const -0x1p-1074)
              (f64.const 0x1p-1074)
              (i32.const 1)))
          (i64.const 32))))))
