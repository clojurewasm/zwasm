;; WASI-0.3 / CM-async fixture (D-335 / D-337): a guest mints a future and drops
;; its writable end WITHOUT writing a value. Per CanonicalABI.md §Future State
;; the writable end of a future cannot be dropped before its value is written —
;; `WritableFutureEnd.drop` traps. So the drop-writable call itself traps (the
;; host trampoline returns FutureDropBeforeWrite); the guest never reaches the
;; unreachable below. This is the future-specific divergence from streams (whose
;; writable end may be dropped freely, the reader then observing DROPPED).
(component
  (type $ft (future u8))
  (core func $fn (canon future.new $ft))
  (core func $dw (canon future.drop-writable $ft))
  (core module $m
    (import "async" "future-new" (func $fn (result i64)))
    (import "async" "drop-writable" (func $dw (param i32)))
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32)
      (local $h i64)
      (local.set $h (call $fn))
      ;; drop the writable end (wi = high 32) with no value written → traps
      (call $dw (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32))))
      ;; a spec-correct drop traps above; reaching here (clean EXIT) would mean
      ;; the guard is missing — the test asserts the trap, so a clean run fails it
      i32.const 0))
  (core instance $deps
    (export "future-new" (func $fn))
    (export "drop-writable" (func $dw)))
  (core instance $i (instantiate $m (with "async" (instance $deps))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
