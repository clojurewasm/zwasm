;; i64.add128 (0xFC 19) — carry lo→hi: (2^64-1) + 1 = (lo=0, hi=1); lo+hi=1.
(module (func (export "test") (result i32)
  (i64.add128 (i64.const 0xFFFFFFFFFFFFFFFF)(i64.const 0)(i64.const 1)(i64.const 0))
  (i64.add) (i32.wrap_i64)))
