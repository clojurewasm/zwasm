;; i8x16.relaxed_swizzle (0xFD 0x100) — in-range index. data=[0..15],
;; idx[0]=15 → result lane0 = data[15] = 15.
(module (func (export "test") (result i32)
  (i8x16.extract_lane_u 0
    (i8x16.relaxed_swizzle
      (v128.const i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
      (v128.const i8x16 15 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))))
