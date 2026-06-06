;; i16x8.relaxed_q15mulr_s (0xFD 0x111) — Q15 rounding mul: round(a*b/2^15).
;; 16384(0.5) * 16384(0.5) = 8192(0.25).
(module (func (export "test") (result i32)
  (i16x8.extract_lane_s 0
    (i16x8.relaxed_q15mulr_s
      (v128.const i16x8 16384 16384 16384 16384 16384 16384 16384 16384)
      (v128.const i16x8 16384 16384 16384 16384 16384 16384 16384 16384)))))
