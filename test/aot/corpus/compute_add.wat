;; AOT-diff corpus: pure compute — must MATCH across .wasm vs .cwasm lanes.
(module
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (func (export "_start")
    (call $exit (i32.add (i32.const 40) (i32.const 2)))))
