;; i32x4.relaxed_trunc_f64x2_s_zero (0xFD 0x103) — lane0 = trunc(7.8) = 7.
(module (func (export "test") (result i32)
  (i32x4.extract_lane 0
    (i32x4.relaxed_trunc_f64x2_s_zero (v128.const f64x2 7.8 -2.0)))))
