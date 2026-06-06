;; i32x4.relaxed_trunc_f64x2_u_zero (0xFD 0x104) — lane0 = trunc(9.1) = 9.
(module (func (export "test") (result i32)
  (i32x4.extract_lane 0
    (i32x4.relaxed_trunc_f64x2_u_zero (v128.const f64x2 9.1 3.0)))))
