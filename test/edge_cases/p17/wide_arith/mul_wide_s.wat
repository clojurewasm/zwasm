;; i64.mul_wide_s (0xFC 21) — (-1)*(-1) = 1 = (lo=1, hi=0); lo+hi=1.
(module (func (export "test") (result i32)
  (i64.mul_wide_s (i64.const -1)(i64.const -1))
  (i64.add) (i32.wrap_i64)))
