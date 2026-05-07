;; Wasm spec §4.4.7 (memory.copy) — dst+n > mem_size traps.
;; Memory = 1 page = 65536 bytes. dst=65530, src=0, n=10 → dst+n = 65540 OOB.
(module
  (memory 1)
  (func (export "test") (result i32)
    i32.const 65530       ;; dst — overshoots
    i32.const 0           ;; src
    i32.const 10          ;; n
    memory.copy
    i32.const 0))
