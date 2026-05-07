;; Wasm spec §4.4.7 (memory.copy) — src+n > mem_size traps independently
;; of dst+n. dst=0 (in-bounds), src=65530, n=10 → src+n=65540 OOB.
;; Witness: the second bounds check (src+n) is wired up in addition to
;; the first (dst+n).
(module
  (memory 1)
  (func (export "test") (result i32)
    i32.const 0           ;; dst — in-bounds
    i32.const 65530       ;; src — overshoots
    i32.const 10          ;; n
    memory.copy
    i32.const 0))
