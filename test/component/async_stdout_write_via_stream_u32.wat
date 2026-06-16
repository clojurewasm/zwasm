;; WASI-0.3 / CM-async fixture (D-335 typed marshalling): a TYPED (multi-byte)
;; stream<u32>. A guest mints a stream<u32>, hands the readable end to
;; wasi:cli/stdout write-via-stream, writes 2 u32 ELEMENTS to the writable end
;; → COMPLETION(2 elements), the host sink must capture 2*4 = 8 BYTES (not 2).
;; Discriminates the typed marshalling (elem_size=4) from the u8/count==bytes bug.
(component
  (import "wasi:cli/stdout@0.3.0" (instance $stdout
    (type $ec (enum "io" "illegal-byte-sequence" "pipe"))
    (export "error-code" (type (eq $ec)))
    (export "write-via-stream"
      (func (param "data" (stream u32)) (result (future (result (error $ec))))))))
  (type $st (stream u32))
  (core module $libc (memory (export "mem") 1))
  (core instance $libc (instantiate $libc))
  (core func $wvs (canon lower (func $stdout "write-via-stream")))
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
      (i32.store (i32.const 0) (i32.const 0x11223344))  ;; u32 #0
      (i32.store (i32.const 4) (i32.const 0x55667788))  ;; u32 #1
      (local.set $h (call $sn))
      (local.set $w (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32)))) ;; wi
      (drop (call $wvs (i32.wrap_i64 (local.get $h))))                        ;; hand readable end to host
      (call $wr (local.get $w) (i32.const 0) (i32.const 2)) ;; write 2 ELEMENTS → COMPLETED(2) = 0x20
      (i32.const 0x20) (i32.ne) (if (then unreachable))
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
