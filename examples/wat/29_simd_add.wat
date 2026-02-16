;; SIMD: add two i32x4 vectors and extract a lane
;; Run: zwasm run examples/wat/29_simd_add.wat --invoke test
;; Expected: 33 (30 + 3)
(module
  (func (export "test") (result i32)
    v128.const i32x4 10 20 30 40
    v128.const i32x4 1 2 3 4
    i32x4.add
    i32x4.extract_lane 2))
