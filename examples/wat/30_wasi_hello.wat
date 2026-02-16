;; WASI: print "Hi!\n" to stdout.
;;
;; The simplest WASI example: write 4 bytes to file descriptor 1 (stdout).
;; Uses fd_write with an iovec (pointer + length) structure in linear memory.
;;
;; Run: zwasm run --allow-all examples/wat/30_wasi_hello.wat
;; Output: Hi!
(module
  ;; Import WASI fd_write(fd, iovs, iovs_len, nwritten) -> errno
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)

  ;; Store "Hi!\n" at offset 16 via data section.
  (data (i32.const 16) "Hi!\n")

  (func (export "_start")
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
