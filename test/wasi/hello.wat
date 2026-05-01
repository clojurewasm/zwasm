;; (Phase 4 / §9.4 / 4.10) Hello-world WASI fixture exercising
;; fd_write to stdout (fd 1) followed by proc_exit(0).
;;
;; Compile via:  wat2wasm test/wasi/hello.wat -o test/wasi/hello.wasm
;;
;; Layout:
;;   linear memory[0..8]   = wasi_ciovec { buf: u32, buf_len: u32 }
;;   linear memory[8..14]  = "hello\n"
;;   linear memory[16..20] = nwritten_out (u32)
(module
  (type $sig_fd_write (func (param i32 i32 i32 i32) (result i32)))
  (type $sig_proc_exit (func (param i32)))
  (type $sig_main (func))

  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (type $sig_fd_write)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (type $sig_proc_exit)))

  (memory 1)
  (data (i32.const 8) "hello\n")

  (func $main (type $sig_main)
    ;; Initialise the ciovec at memory[0..8].
    i32.const 0    ;; address for ciovec.buf
    i32.const 8    ;; payload string offset
    i32.store
    i32.const 4    ;; address for ciovec.buf_len
    i32.const 6    ;; "hello\n" is 6 bytes
    i32.store

    ;; fd_write(fd=1, ciovec_ptr=0, ciovec_count=1, nwritten_ptr=16)
    i32.const 1
    i32.const 0
    i32.const 1
    i32.const 16
    call $fd_write
    drop

    ;; proc_exit(0)
    i32.const 0
    call $proc_exit)

  (export "main" (func $main)))
