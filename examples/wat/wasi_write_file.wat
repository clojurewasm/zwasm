;; WASI: write a message to a file.
;;
;; Run: zwasm run --allow-all --dir /tmp examples/wat/wasi_write_file.wat
;; Output: (creates /tmp/zwasm.txt)
;; Verify: cat /tmp/zwasm.txt → "OK"
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_close"
    (func $fd_close (param i32) (result i32)))

  (memory (export "memory") 1)

  ;; Layout:
  ;;   0-3:   fd result from path_open
  ;;   4-7:   iovec.buf_ptr
  ;;   8-11:  iovec.buf_len
  ;;   12-15: nwritten
  ;;   64+:   filename "zwasm.txt"
  ;;   128+:  message "OK"

  (func (export "_start")
    (local $fd i32)

    ;; Store filename "zwasm.txt" at offset 64 (9 bytes).
    ;; "zwas" = 0x7361777A, "m.tx" = 0x78742E6D, "t" = 0x74
    (i32.store (i32.const 64) (i32.const 0x7361777A))
    (i32.store (i32.const 68) (i32.const 0x78742E6D))
    (i32.store8 (i32.const 72) (i32.const 0x74))

    ;; Store message "OK" at offset 128 (2 bytes).
    (i32.store16 (i32.const 128) (i32.const 0x4B4F))

    ;; Open file for writing (create if not exists).
    (drop (call $path_open
      (i32.const 3)          ;; preopened dir fd
      (i32.const 0)          ;; dirflags
      (i32.const 64)         ;; path ptr
      (i32.const 9)          ;; path len
      (i32.const 1)          ;; oflags: CREAT
      (i64.const 64)         ;; rights: FD_WRITE
      (i64.const 0)          ;; rights_inheriting
      (i32.const 0)          ;; fdflags
      (i32.const 0)))        ;; result fd at offset 0

    (local.set $fd (i32.load (i32.const 0)))

    ;; Set up iovec: buf_ptr=128, buf_len=2
    (i32.store (i32.const 4) (i32.const 128))
    (i32.store (i32.const 8) (i32.const 2))

    ;; Write to file.
    (drop (call $fd_write
      (local.get $fd) (i32.const 4) (i32.const 1) (i32.const 12)))

    ;; Close.
    (drop (call $fd_close (local.get $fd)))))
