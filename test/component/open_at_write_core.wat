;; Core module for the WASI-P2 descriptor.open-at unit test. Given a directory
;; descriptor handle (run's param), opens/creates "f.txt" under it, writes
;; "DATA42" at offset 0 via descriptor.write, drops the file descriptor, and
;; returns the open-at result discriminant (0 = ok).
(module
  (import "fs" "open-at" (func $open (param i32 i32 i32 i32 i32 i32 i32)))
  (import "fs" "write" (func $write (param i32 i32 i32 i64 i32)))
  (import "fs" "drop" (func $drop (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 16) "f.txt")
  (data (i32.const 32) "DATA42")
  (func (export "run") (param $dir i32) (result i32)
    (local $fh i32)
    ;; open-at(dir, path-flags=0, path=16, len=5, open-flags=CREAT|TRUNC=9, descr-flags=0, retptr=64)
    (call $open (local.get $dir) (i32.const 0) (i32.const 16) (i32.const 5) (i32.const 9) (i32.const 0) (i32.const 64))
    (local.set $fh (i32.load (i32.const 68))) ;; result payload (own<descriptor>) at retptr+4
    (call $write (local.get $fh) (i32.const 32) (i32.const 6) (i64.const 0) (i32.const 80))
    (call $drop (local.get $fh))
    (i32.load (i32.const 64))) ;; open-at result disc
)
