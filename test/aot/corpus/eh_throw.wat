;; AOT-diff corpus: try_table/throw — EH tables are not serialized and the
;; rethrow helper address is baked — D-516 unsound class.
(module
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (tag $e (param i32))
  (func (export "_start")
    (call $exit
      (block $h (result i32)
        (try_table (catch $e $h)
          (throw $e (i32.const 42)))
        (i32.const 0)))))
