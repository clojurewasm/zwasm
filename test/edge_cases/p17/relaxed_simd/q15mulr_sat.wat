;; i16x8.relaxed_q15mulr_s overflow: INT16_MIN*INT16_MIN → INT16_MAX 32767 (v2 choice).
(module (func (export "test") (result i32)
  (i16x8.extract_lane_s 0
    (i16x8.relaxed_q15mulr_s
      (v128.const i16x8 -32768 -32768 -32768 -32768 -32768 -32768 -32768 -32768)
      (v128.const i16x8 -32768 -32768 -32768 -32768 -32768 -32768 -32768 -32768)))))
