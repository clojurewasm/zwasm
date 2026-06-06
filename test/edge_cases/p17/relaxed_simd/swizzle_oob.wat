;; i8x16.relaxed_swizzle (0xFD 0x100) — out-of-range index → 0 (v2 choice).
;; idx[1]=16 (≥16) → result lane1 = 0.
(module (func (export "test") (result i32)
  (i8x16.extract_lane_u 1
    (i8x16.relaxed_swizzle
      (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
      (v128.const i8x16 0 16 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))))
