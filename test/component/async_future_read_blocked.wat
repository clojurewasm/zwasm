;; WASI-0.3 / CM-async fixture (D-335 unit D-ζ2, ADR-0189): the future analogue
;; of async_stream_read_blocked. A guest mints a future and reads its readable
;; end with no writer ready → the read returns BLOCKED (0xffffffff). Exercises
;; the SharedFuture rendezvous (the `.future` arm of end.copy), distinct from
;; the SharedStream path the stream fixtures cover. Single-task reaches only
;; BLOCKED here (COMPLETION needs a peer — Unit E).
(component
  (type $ft (future u8))
  (core module $libc (memory (export "mem") 1))
  (core instance $libc (instantiate $libc))
  (core func $fn (canon future.new $ft))
  (core func $rd (canon future.read $ft (memory $libc "mem")))
  (core module $m
    (import "async" "future-new" (func $fn (result i64)))
    (import "async" "future-read" (func $rd (param i32 i32 i32) (result i32)))
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32)
      (local $h i64)
      (local.set $h (call $fn))
      ;; read readable end (ri = low 32) into mem[0], count 1 → BLOCKED
      (call $rd (i32.wrap_i64 (local.get $h)) (i32.const 0) (i32.const 1))
      (i32.const -1) ;; 0xffffffff = BLOCKED
      (i32.ne)
      (if (then unreachable)) ;; trap if the read did NOT block
      i32.const 0)) ;; 0 = EXIT
  (core instance $deps
    (export "future-new" (func $fn))
    (export "future-read" (func $rd)))
  (core instance $i (instantiate $m (with "async" (instance $deps))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
