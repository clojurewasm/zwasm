;; WASI-0.3 / CM-async fixture (D-335 unit E1, ADR-0190): the stderr host stream
;; peer (mirror of the stdout fixture, fd 2). Confirms the wasi:cli/stderr
;; write-via-stream path (wired in E1, fd=2) routes a guest stream.write to the
;; stderr sink. Guest writes "er\n" through a stream, drops, EXITs.
(component
  (import "wasi:cli/stderr@0.3.0" (instance $stderr
    (type $ec (enum "io" "illegal-byte-sequence" "pipe"))
    (export "error-code" (type (eq $ec)))
    (export "write-via-stream"
      (func (param "data" (stream u8)) (result (future (result (error $ec))))))))
  (type $st (stream u8))
  (core module $libc (memory (export "mem") 1))
  (core instance $libc (instantiate $libc))
  (core func $wvs (canon lower (func $stderr "write-via-stream")))
  (core func $sn (canon stream.new $st))
  (core func $wr (canon stream.write $st (memory $libc "mem")))
  (core func $dw (canon stream.drop-writable $st))
  (core module $m
    (import "async" "write-via-stream" (func $wvs (param i32) (result i32)))
    (import "async" "stream-new" (func $sn (result i64)))
    (import "async" "stream-write" (func $wr (param i32 i32 i32) (result i32)))
    (import "async" "drop-writable" (func $dw (param i32)))
    (import "libc" "mem" (memory 1))
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32)
      (local $h i64) (local $w i32)
      (i32.store8 (i32.const 0) (i32.const 0x65)) ;; 'e'
      (i32.store8 (i32.const 1) (i32.const 0x72)) ;; 'r'
      (i32.store8 (i32.const 2) (i32.const 0x0a)) ;; '\n'
      (local.set $h (call $sn))
      (local.set $w (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32))))
      (drop (call $wvs (i32.wrap_i64 (local.get $h)))) ;; hand readable to stderr sink
      (call $wr (local.get $w) (i32.const 0) (i32.const 3))
      (i32.const 0x30) (i32.ne) (if (then unreachable)) ;; COMPLETED(3)
      (call $dw (local.get $w))
      i32.const 0)) ;; EXIT
  (core instance $deps
    (export "write-via-stream" (func $wvs))
    (export "stream-new" (func $sn))
    (export "stream-write" (func $wr))
    (export "drop-writable" (func $dw)))
  (core instance $i (instantiate $m (with "async" (instance $deps)) (with "libc" (instance $libc))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
