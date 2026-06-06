;; i32x4.relaxed_trunc_f32x4_u (0xFD 0x102) — lane0 = trunc(5.9) = 5.
(module (func (export "test") (result i32)
  (i32x4.extract_lane 0
    (i32x4.relaxed_trunc_f32x4_u (v128.const f32x4 5.9 0 0 0)))))
