;; Wasm spec §4.4.7 (memory.fill) — dst+n > mem_size must trap.
;; Memory size = 1 page = 65536 bytes. Fill at dst=65530 with n=10
;; → end = 65540 > 65536 → out-of-bounds trap.
(module
  (memory 1)
  (func (export "test") (result i32)
    i32.const 65530       ;; dst
    i32.const 0           ;; val
    i32.const 10          ;; n — overshoots by 4
    memory.fill
    i32.const 0))
