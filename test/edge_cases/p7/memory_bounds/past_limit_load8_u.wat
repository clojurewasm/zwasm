;; Boundary: i32.load8_u with eff_addr == mem_limit (1 byte past end).
;; eff_addr (65536) + access_size (1) == 65537 > mem_limit (65536) → TRAP.
;; Witnesses that narrowed loads also enforce spec-strict bounds.
(module
  (memory 1)
  (func (export "test") (result i32)
    i32.const 65536
    i32.load8_u))
