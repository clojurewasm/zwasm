;; Chunk 7.9-d-3: end-to-end WASI fd_write with real linear
;; memory init. Memory section declares 1 page; data segment
;; populates the iovec at offset 8 (buf_off=0, buf_len=5) and
;; the string "hello" at offset 0. Function calls fd_write(1,
;; iovs_ptr=8, iovs_len=1, nwritten_ptr=16) and returns errno.
;;
;; Validates: (1) memory section decoded → memory_slice
;; allocated; (2) data segments evaluated + copied; (3) fd_write
;; bounds-checks via mem_limit (no longer 0); (4) iov walk reads
;; buf_off + buf_len from memory; (5) nwritten store works.
;;
;; d-3 MVP fd_write skips actual stdout write, so the host
;; observes "5 bytes accepted" in nwritten. Real stdout routing
;; is d-4.
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory 1)
  (data (i32.const 0) "hello")
  (data (i32.const 8) "\00\00\00\00\05\00\00\00")  ;; iovec: buf=0, len=5
  (func (export "test") (result i32)
    i32.const 1       ;; fd = stdout
    i32.const 8       ;; iovs_ptr (addr of iovec)
    i32.const 1       ;; iovs_len
    i32.const 16      ;; nwritten_ptr
    call $fd_write))
