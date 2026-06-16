(module (func (export "test") (result i32)
  (i32x4.extract_lane 0 (i32x4.trunc_sat_f64x2_s_zero (f64x2.splat (f64.const 2.7))))))