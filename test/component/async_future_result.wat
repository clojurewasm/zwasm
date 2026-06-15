;; WASI-0.3 / CM-async fixture (D-335 Unit E, ADR-0190): the return-future of
;; write-via-stream. The guest writes "hi" through a stdout stream, drops the
;; writable end, then `future.read`s the returned future<result<_,error-code>>
;; → COMPLETED(1) with the `ok` discriminant (0). Proves the host stream peer's
;; result future resolves (a host sink always succeeds → ok).
(component
  (import "wasi:cli/stdout@0.3.0" (instance $stdout
    (type $ec (enum "io" "illegal-byte-sequence" "pipe"))
    (export "error-code" (type (eq $ec)))
    (export "write-via-stream"
      (func (param "data" (stream u8)) (result (future (result (error $ec))))))))
  (type $st (stream u8))
  (type $ec2 (enum "io" "illegal-byte-sequence" "pipe"))
  (type $ft (future (result (error $ec2))))
  (core module $libc (memory (export "mem") 1))
  (core instance $libc (instantiate $libc))
  (core func $wvs (canon lower (func $stdout "write-via-stream")))
  (core func $sn (canon stream.new $st))
  (core func $wr (canon stream.write $st (memory $libc "mem")))
  (core func $dw (canon stream.drop-writable $st))
  (core func $fr (canon future.read $ft (memory $libc "mem")))
  (core module $m
    (import "async" "write-via-stream" (func $wvs (param i32) (result i32)))
    (import "async" "stream-new" (func $sn (result i64)))
    (import "async" "stream-write" (func $wr (param i32 i32 i32) (result i32)))
    (import "async" "drop-writable" (func $dw (param i32)))
    (import "async" "future-read" (func $fr (param i32 i32 i32) (result i32)))
    (import "libc" "mem" (memory 1))
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32)
      (local $h i64) (local $w i32) (local $fut i32)
      (i32.store8 (i32.const 0) (i32.const 0x68)) ;; 'h'
      (i32.store8 (i32.const 1) (i32.const 0x69)) ;; 'i'
      (local.set $h (call $sn))
      (local.set $w (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32))))
      (local.set $fut (call $wvs (i32.wrap_i64 (local.get $h)))) ;; → result future handle
      (call $wr (local.get $w) (i32.const 0) (i32.const 2))
      (i32.const 0x20) (i32.ne) (if (then unreachable)) ;; COMPLETED(2)
      (call $dw (local.get $w))
      (call $fr (local.get $fut) (i32.const 8) (i32.const 1)) ;; future.read into mem[8]
      (i32.const 0x10) (i32.ne) (if (then unreachable)) ;; COMPLETED(1)
      (if (i32.load8_u (i32.const 8)) (then unreachable)) ;; ok discriminant == 0
      i32.const 0)) ;; EXIT
  (core instance $deps
    (export "write-via-stream" (func $wvs))
    (export "stream-new" (func $sn))
    (export "stream-write" (func $wr))
    (export "drop-writable" (func $dw))
    (export "future-read" (func $fr)))
  (core instance $i (instantiate $m (with "async" (instance $deps)) (with "libc" (instance $libc))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
