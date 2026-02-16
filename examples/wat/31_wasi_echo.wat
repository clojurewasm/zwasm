;; WASI: read from stdin and echo to stdout.
;;
;; Run: echo "Hello" | zwasm run --allow-all examples/wat/31_wasi_echo.wat
;; Output: Hello
(module
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)

  ;; Layout:
  ;;   0-3:   iovec.buf_ptr (→ 16)
  ;;   4-7:   iovec.buf_len (1024)
  ;;   8-11:  nread / nwritten result
  ;;   16+:   data buffer

  (func (export "_start")
    (local $nread i32)

    ;; Set up iovec: buf_ptr=16, buf_len=1024
    (i32.store (i32.const 0) (i32.const 16))
    (i32.store (i32.const 4) (i32.const 1024))

    ;; fd_read(stdin=0, iovs=0, iovs_len=1, nread=8)
    (drop (call $fd_read
      (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 8)))

    ;; Get bytes read.
    (local.set $nread (i32.load (i32.const 8)))

    ;; Update iovec length to actual bytes read.
    (i32.store (i32.const 4) (local.get $nread))

    ;; fd_write(stdout=1, iovs=0, iovs_len=1, nwritten=8)
    (drop (call $fd_write
      (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 8)))))
