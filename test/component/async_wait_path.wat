;; WASI-0.3 / CM-async fixture (D-335 unit E2c, ADR-0191): the WAIT-path e2e.
;; The guest opens a host-source stream (stdin), issues a stream.read that PARKS
;; (the source is "not ready"), joins the readable end to a waitable set, then
;; the task entry RETURNS WAIT(set). The host loop's waitOn delivers the source
;; bytes → STREAM_READ event → re-enters the guest `callback`, which asserts the
;; delivered "ok" landed in memory and EXITs. First e2e exercising the real
;; `driveCallbackLoop` WAIT branch (today only EXIT/YIELD were e2e).
(component
  (import "wasi:cli/stdin@0.3.0" (instance $stdin
    (type $ec (enum "io" "illegal-byte-sequence" "pipe"))
    (export "error-code" (type (eq $ec)))
    (export "read-via-stream"
      (func (result (tuple (stream u8) (future (result (error $ec)))))))))
  (type $st (stream u8))
  (core module $libc (memory (export "mem") 1))
  (core instance $libc (instantiate $libc))
  (core func $rvs (canon lower (func $stdin "read-via-stream") (memory $libc "mem")))
  (core func $rd (canon stream.read $st (memory $libc "mem")))
  (core func $wsn (canon waitable-set.new))
  (core func $wj (canon waitable.join))
  (core module $m
    (import "async" "read-via-stream" (func $rvs (param i32)))
    (import "async" "stream-read" (func $rd (param i32 i32 i32) (result i32)))
    (import "async" "ws-new" (func $wsn (result i32)))
    (import "async" "w-join" (func $wj (param i32 i32)))
    (import "libc" "mem" (memory 1))
    ;; callback(event_code, p1=waitable, p2=payload) -> packed result.
    (func (export "callback") (param i32 i32 i32) (result i32)
      (if (i32.ne (local.get 0) (i32.const 2)) (then unreachable))   ;; STREAM_READ=2
      (if (i32.ne (i32.load8_u (i32.const 0)) (i32.const 0x6f)) (then unreachable)) ;; 'o'
      (if (i32.ne (i32.load8_u (i32.const 1)) (i32.const 0x6b)) (then unreachable)) ;; 'k'
      i32.const 0) ;; EXIT
    (func (export "run") (result i32)
      (local $r i32) (local $set i32)
      (call $rvs (i32.const 16))             ;; tuple<stream,future> at mem[16] (ri@16)
      (local.set $r (i32.load (i32.const 16)))
      (call $rd (local.get $r) (i32.const 0) (i32.const 8)) ;; read → PARKS (BLOCKED)
      (i32.const -1) (i32.ne) (if (then unreachable))       ;; assert it blocked
      (local.set $set (call $wsn))
      (call $wj (local.get $r) (local.get $set))            ;; join the readable end
      (i32.or (i32.shl (local.get $set) (i32.const 4)) (i32.const 2)))) ;; return WAIT(set)
  (core instance $deps
    (export "read-via-stream" (func $rvs))
    (export "stream-read" (func $rd))
    (export "ws-new" (func $wsn))
    (export "w-join" (func $wj)))
  (core instance $i (instantiate $m (with "async" (instance $deps)) (with "libc" (instance $libc))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
