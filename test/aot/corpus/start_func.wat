;; AOT-diff corpus: (start) is not serialized into .cwasm — the cwasm lane
;; silently skips it and reads 0 (D-518 wrong-result class).
(module
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (memory 1)
  (func $init (i32.store (i32.const 0) (i32.const 42)))
  (start $init)
  (func (export "_start")
    (call $exit (i32.load (i32.const 0)))))
