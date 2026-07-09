;; AOT-diff corpus: memory.grow — unsupported by the cwasm mini-runtime
;; (D-517): grow returns -1 there → exit 100 instead of 42.
(module
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (memory 1)
  (func (export "_start")
    (if (i32.eq (memory.grow (i32.const 1)) (i32.const -1))
      (then (call $exit (i32.const 100))))
    (i32.store (i32.const 65536) (i32.const 42))
    (call $exit (i32.load (i32.const 65536)))))
