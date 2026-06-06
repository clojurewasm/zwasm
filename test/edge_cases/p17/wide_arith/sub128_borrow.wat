;; i64.sub128 (0xFC 20) — borrow: 2^64 - 1 = (lo=2^64-1, hi=0); lo+hi wraps to 0xFFFFFFFF=-1.
(module (func (export "test") (result i32)
  (i64.sub128 (i64.const 0)(i64.const 1)(i64.const 1)(i64.const 0))
  (i64.add) (i32.wrap_i64)))
