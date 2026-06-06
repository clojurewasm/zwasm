;; f32x4.relaxed_max (0xFD 0x10E) — max(3.0, 7.0)=7 at lane0.
(module (func (export "test") (result i32)
  (i32.trunc_f32_s (f32x4.extract_lane 0
    (f32x4.relaxed_max (v128.const f32x4 3.0 0 0 0) (v128.const f32x4 7.0 0 0 0))))))
