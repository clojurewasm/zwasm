;; i64.mul_wide_u (0xFC 22) — 2^32 * 2^32 = 2^64 = (lo=0, hi=1); lo+hi=1.
(module (func (export "test") (result i32)
  (i64.mul_wide_u (i64.const 0x100000000)(i64.const 0x100000000))
  (i64.add) (i32.wrap_i64)))
