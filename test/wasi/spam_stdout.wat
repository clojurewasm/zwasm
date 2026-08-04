;; A WASI command that writes a 64-byte line to stdout forever, IGNORING the
;; errno. The shape that measured 64 MB of host capture per 1e6 fuel from
;; ClojureWasm (D-533): nothing but a capture cap bounds it, because fuel bounds
;; instructions and bytes-per-instruction is the guest's choice. Ignoring the
;; errno is the point — a cap must hold against a guest that does not cooperate.
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 8) "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
  (func (export "_start")
    (i32.store (i32.const 0) (i32.const 8))
    (i32.store (i32.const 4) (i32.const 64))
    (loop $again
      (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 200)))
      (br $again))))
