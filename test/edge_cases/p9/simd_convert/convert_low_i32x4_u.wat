(module (func (export "test") (result i32)
  (i32.trunc_f64_u (f64x2.extract_lane 0 (f64x2.convert_low_i32x4_u (i32x4.splat (i32.const 5)))))))