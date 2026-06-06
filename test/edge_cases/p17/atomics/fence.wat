;; Wasm threads proposal — atomic.fence (0xFE 0x03 0x00).
;; Arity 0->0, no memarg, no memory required ("no memory is ok",
;; threads/test/core/threads/atomic.wast:963). Proves the whole
;; 0xFE prefix pipeline (parse -> validate -> lower -> interp/JIT
;; no-op) end-to-end: the fence executes, then 42 is returned.
(module
  (func (export "test") (result i32)
    atomic.fence
    i32.const 42))
