;; WASI-0.3 / CM-async fixture (D-335 typed marshalling, READ direction): the
;; TYPED (multi-byte) counterpart of async_stdin_read_via_stream.wat. The host
;; source supplies 8 stdin bytes; the guest reads them as 2 u32 ELEMENTS via a
;; stream<u32> → COMPLETED(2) (NOT 8), and the bytes land verbatim in guest
;; memory. Discriminates the read-path elem_size=4 marshalling (count*elem_size
;; bytes sliced, n/elem_size elements completed) from the u8/count==bytes path.
;; read-via-stream: func() -> tuple<stream<u32>, future<result<_, error-code>>>;
;; returns >1 flat value → lowered via a retptr (MAX_FLAT_RESULTS=1).
(component
  (import "wasi:cli/stdin@0.3.0" (instance $stdin
    (type $ec (enum "io" "illegal-byte-sequence" "pipe"))
    (export "error-code" (type (eq $ec)))
    (export "read-via-stream"
      (func (result (tuple (stream u32) (future (result (error $ec)))))))))
  (type $st (stream u32))
  (core module $libc (memory (export "mem") 1))
  (core instance $libc (instantiate $libc))
  (core func $rvs (canon lower (func $stdin "read-via-stream") (memory $libc "mem")))
  (core func $rd (canon stream.read $st (memory $libc "mem")))
  (core module $m
    (import "async" "read-via-stream" (func $rvs (param i32))) ;; retptr for the tuple
    (import "async" "stream-read" (func $rd (param i32 i32 i32) (result i32)))
    (import "libc" "mem" (memory 1))
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32)
      (local $r i32)
      (call $rvs (i32.const 16)) ;; write tuple<stream,future> at mem[16] (ri@16, fut@20)
      (local.set $r (i32.load (i32.const 16))) ;; the readable stream handle
      (call $rd (local.get $r) (i32.const 0) (i32.const 2)) ;; read up to 2 ELEMENTS into mem[0]
      (i32.const 0x20) (i32.ne) (if (then unreachable)) ;; assert COMPLETED(2) = (2<<4)|0
      (i32.load (i32.const 0)) (i32.const 0x11223344) (i32.ne) (if (then unreachable)) ;; u32 #0 (8 bytes consumed)
      (i32.load (i32.const 4)) (i32.const 0x55667788) (i32.ne) (if (then unreachable)) ;; u32 #1
      i32.const 0)) ;; EXIT
  (core instance $deps
    (export "read-via-stream" (func $rvs))
    (export "stream-read" (func $rd)))
  (core instance $i (instantiate $m (with "async" (instance $deps)) (with "libc" (instance $libc))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
