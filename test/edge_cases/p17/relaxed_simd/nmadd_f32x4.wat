;; f32x4.relaxed_nmadd (0xFD 0x106) — -(a*b)+c, lane0 = -(3*5)+20 = 5.
(module (func (export "test") (result i32)
  (i32.trunc_f32_s (f32x4.extract_lane 0
    (f32x4.relaxed_nmadd (v128.const f32x4 3 0 0 0) (v128.const f32x4 5 0 0 0) (v128.const f32x4 20 0 0 0))))))
