;; AOT-diff corpus: call_indirect happy path (elem-initialized slots are
;; pre-resolved into funcptr_base, so the baked resolve helper is not hit) —
;; MATCH expected; guards against regression while de-baking (D-516).
(module
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (type $ii (func (result i32)))
  (table 2 funcref)
  (elem (i32.const 0) $f40 $f2)
  (func $f40 (result i32) (i32.const 40))
  (func $f2 (result i32) (i32.const 2))
  (func (export "_start")
    (call $exit (i32.add
      (call_indirect (type $ii) (i32.const 0))
      (call_indirect (type $ii) (i32.const 1))))))
