;; zwasm v2 — C-API conformance guest: preopen smoke (ADR-0184 step 4).
;;
;; Expects the C host (wasi_preopen.c) to preopen a directory (fd 3)
;; containing `hello.txt` whose content starts with 'p' ("preopen!").
;; path_open + fd_read it; any failure exits with a distinct nonzero
;; code via proc_exit, success returns normally from _start (exit 0).
;;
;; Memory layout: 8 = opened-fd retptr, 16 = "hello.txt", 32 = iovec,
;; 48 = nread retptr, 64 = read buffer.
(module
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_read"
    (func $fd_read (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 16) "hello.txt")
  (func (export "_start")
    ;; path_open(dirfd=3, dirflags=0, path, oflags=0,
    ;;           rights_base=FD_READ, rights_inheriting=0, fdflags=0, retptr=8)
    (if (i32.ne
          (call $path_open
            (i32.const 3)
            (i32.const 0)
            (i32.const 16) (i32.const 9)
            (i32.const 0)
            (i64.const 2) (i64.const 0)
            (i32.const 0)
            (i32.const 8))
          (i32.const 0))
      (then (call $proc_exit (i32.const 1))))
    ;; iovec { base=64, len=32 }; fd_read(opened_fd, iovs=32, 1, nread=48)
    (i32.store (i32.const 32) (i32.const 64))
    (i32.store (i32.const 36) (i32.const 32))
    (if (i32.ne
          (call $fd_read
            (i32.load (i32.const 8))
            (i32.const 32) (i32.const 1) (i32.const 48))
          (i32.const 0))
      (then (call $proc_exit (i32.const 2))))
    (if (i32.eqz (i32.load (i32.const 48)))
      (then (call $proc_exit (i32.const 3))))
    (if (i32.ne (i32.load8_u (i32.const 64)) (i32.const 0x70))
      (then (call $proc_exit (i32.const 4))))))
