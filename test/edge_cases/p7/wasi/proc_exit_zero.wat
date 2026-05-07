;; Chunk 7.9-d-3: WASI proc_exit dispatched via the registered
;; handler (instead of the default trap trampoline). The handler
;; sets trap_flag = 1 and returns; the JIT body's epilogue still
;; runs, but the entry shim observes trap_flag and surfaces
;; Error.Trap. Fixture verifies the dispatch wiring + signature
;; compatibility (proc_exit returns void; the JIT call site
;; emitted via op_call properly handles the void-return case).
(module
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32)))
  (func (export "test") (result i32)
    i32.const 0
    call $proc_exit
    i32.const 99))   ;; unreachable in practice (post-trap_flag set)
