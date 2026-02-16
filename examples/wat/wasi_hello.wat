;; WASI: print "Hi!\n" to stdout.
;; Uses i32.store to set up memory (WAT parser doesn't support data sections).
;;
;; Run: zwasm run --allow-all examples/wat/wasi_hello.wat
;; Output: Hi!
(module
  ;; Import WASI fd_write(fd, iovs, iovs_len, nwritten) -> errno
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)

  (func (export "_start")
    ;; Write "Hi!\n" (4 bytes) at offset 16.
    ;; 'H'=72, 'i'=105, '!'=33, '\n'=10 → little-endian i32 = 0x0A216948
    (i32.store (i32.const 16) (i32.const 0x0A216948))

    ;; Set up iovec at offset 0: { buf_ptr=16, buf_len=4 }
    (i32.store (i32.const 0) (i32.const 16))   ;; pointer to string
    (i32.store (i32.const 4) (i32.const 4))    ;; length = 4

    ;; fd_write(fd=1(stdout), iovs=0, iovs_len=1, nwritten=8)
    (drop (call $fd_write
      (i32.const 1)   ;; stdout
      (i32.const 0)   ;; iovec array at offset 0
      (i32.const 1)   ;; one iovec
      (i32.const 8))) ;; nwritten pointer
  ))
