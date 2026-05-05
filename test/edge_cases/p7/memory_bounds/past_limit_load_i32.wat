;; Boundary: i32.load whose last byte is one past the memory end.
;; eff_addr (65533) + access_size (4) == 65537 > mem_limit (65536) → TRAP.
;; Spec: out of bounds memory access. Pre-#1 fix this passed silently
;; (the broken `eff_addr >= mem_limit` check let 65533 < 65536 through).
(module
  (memory 1)
  (func (export "test") (result i32)
    i32.const 65533
    i32.load))
