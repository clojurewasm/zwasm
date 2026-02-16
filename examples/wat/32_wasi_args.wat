;; WASI: print command-line arguments to stdout.
;;
;; Demonstrates args_sizes_get + args_get to receive string arguments.
;;
;; Run: zwasm examples/wat/32_wasi_args.wat --allow-all -- hello world
;; Output:
;;   examples/wat/32_wasi_args.wat
;;   hello
;;   world
(module
  (import "wasi_snapshot_preview1" "args_sizes_get"
    (func $args_sizes_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "args_get"
    (func $args_get (param i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))

  (memory (export "memory") 1)

  ;; Layout:
  ;;   0-3:   argc result
  ;;   4-7:   argv_buf_size result
  ;;   8-11:  iovec.buf_ptr
  ;;   12-15: iovec.buf_len
  ;;   16-19: nwritten result
  ;;   64+:   argv pointers array
  ;;   256+:  argv string buffer

  (func (export "_start")
    (local $argc i32)
    (local $i i32)
    (local $ptr i32)
    (local $len i32)
    (local $next i32)

    ;; Get argument count and total size.
    (drop (call $args_sizes_get (i32.const 0) (i32.const 4)))
    (local.set $argc (i32.load (i32.const 0)))

    ;; Get argument pointers (at 64) and string data (at 256).
    (drop (call $args_get (i32.const 64) (i32.const 256)))

    ;; Print each argument followed by a newline.
    (local.set $i (i32.const 0))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $i) (local.get $argc)))

        ;; argv[i] pointer
        (local.set $ptr
          (i32.load (i32.add (i32.const 64)
            (i32.mul (local.get $i) (i32.const 4)))))

        ;; Find string length (null-terminated).
        (local.set $len (i32.const 0))
        (block $end
          (loop $scan
            (br_if $end (i32.eqz
              (i32.load8_u (i32.add (local.get $ptr) (local.get $len)))))
            (local.set $len (i32.add (local.get $len) (i32.const 1)))
            (br $scan)))

        ;; Write the argument string.
        (i32.store (i32.const 8) (local.get $ptr))
        (i32.store (i32.const 12) (local.get $len))
        (drop (call $fd_write (i32.const 1) (i32.const 8) (i32.const 1) (i32.const 16)))

        ;; Write a newline. Store '\n' right after nwritten area.
        (i32.store8 (i32.const 20) (i32.const 10))
        (i32.store (i32.const 8) (i32.const 20))
        (i32.store (i32.const 12) (i32.const 1))
        (drop (call $fd_write (i32.const 1) (i32.const 8) (i32.const 1) (i32.const 16)))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))))
