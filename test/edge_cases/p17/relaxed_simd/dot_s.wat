;; i16x8.relaxed_dot_i8x16_i7x16_s (0xFD 0x112) — pairwise i8 dot → i16x8.
;; a=[1..16], b=all 1. lane0 = a[0]*1 + a[1]*1 = 1+2 = 3; lane1 = 3+4 = 7.
(module
  (func (export "test") (result i32)
    (i16x8.extract_lane_s 0
      (i16x8.relaxed_dot_i8x16_i7x16_s
        (v128.const i8x16 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)
        (v128.const i8x16 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1))))
  (func (export "test_lane1") (result i32)
    (i16x8.extract_lane_s 1
      (i16x8.relaxed_dot_i8x16_i7x16_s
        (v128.const i8x16 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)
        (v128.const i8x16 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1)))))
