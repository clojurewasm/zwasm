;; WASI-0.3 / CM-async fixture (D-335 unit D-ζ2 Slice 2, ADR-0189): an async
;; export whose core entry calls `stream.new` (minting a readable+writable end
;; pair over one shared rendezvous), discards the packed i64 handles, then
;; returns EXIT. Exercises the P3 runner's stream.new host builtin end-to-end —
;; before ζ2 the canon stream.new import was UnsupportedWasiImport.
(component
  (type $st (stream u8))
  (core func $sn (canon stream.new $st))
  (core module $m
    (import "async" "stream-new" (func $sn (result i64)))
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32)
      (drop (call $sn)) ;; mint a stream (ri | wi<<32); discard the handles
      i32.const 0))     ;; 0 = EXIT
  (core instance $deps (export "stream-new" (func $sn)))
  (core instance $i (instantiate $m (with "async" (instance $deps))))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
