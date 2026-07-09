;; AOT-diff corpus: struct.new hits the baked jitGcAlloc absolute address —
;; D-516 unsound class (fatal signal under PIE ASLR in a fresh process).
(module
  (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
  (type $point (struct (field i32) (field i32)))
  (func (export "_start")
    (local $p (ref $point))
    (local.set $p (struct.new $point (i32.const 40) (i32.const 2)))
    (call $exit (i32.add
      (struct.get $point 0 (local.get $p))
      (struct.get $point 1 (local.get $p))))))
