;; WASI-0.3 / CM-async fixture (D-335 unit E3, ADR-0190): the stdin host stream
;; peer (host-as-WRITER — the reverse of E1's stdout sink). The guest calls
;; read-via-stream → gets (stream<u8>, future) via a retptr tuple → reads the
;; stream → the host SOURCE supplies stdin bytes ("ok") → COMPLETED(2), bytes
;; copied into guest memory. Guest self-asserts the code + bytes, then EXITs.
;; read-via-stream: func() -> tuple<stream<u8>, future<result<_, error-code>>>;
;; returns >1 flat value → lowered via a retptr (MAX_FLAT_RESULTS=1).
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
  (core module $m
    (import "async" "read-via-stream" (func $rvs (param i32))) ;; retptr for the tuple
    (import "async" "stream-read" (func $rd (param i32 i32 i32) (result i32)))
    (import "libc" "mem" (memory 1))
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32)
      (local $r i32)
      (call $rvs (i32.const 16)) ;; write tuple<stream,future> at mem[16] (ri@16, fut@20)
      (local.set $r (i32.load (i32.const 16))) ;; the readable stream handle
      (call $rd (local.get $r) (i32.const 0) (i32.const 8)) ;; read up to 8 bytes into mem[0]
      (i32.const 0x20) (i32.ne) (if (then unreachable)) ;; assert COMPLETED(2) = (2<<4)|0
      (i32.load8_u (i32.const 0)) (i32.const 0x6f) (i32.ne) (if (then unreachable)) ;; 'o'
      (i32.load8_u (i32.const 1)) (i32.const 0x6b) (i32.ne) (if (then unreachable)) ;; 'k'
      i32.const 0)) ;; EXIT
  (core instance $deps
    (export "read-via-stream" (func $rvs))
    (export "stream-read" (func $rd)))
  (core instance $i (instantiate $m (with "async" (instance $deps)) (with "libc" (instance $libc))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
