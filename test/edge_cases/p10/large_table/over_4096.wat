;; D-331(A) — JIT instantiation of a table whose declared minimum
;; exceeds the old arbitrary 4096-entry eager-allocation cap in
;; engine/setup.zig. Real-world Go (wasip1) declares a ~5790-entry
;; funcref table; the cap rejected it as UnsupportedEntrySignature
;; even though the interp instantiates it (it allocates `min` cells
;; with no cap). 5000 > 4096 reproduces the boundary; the entry
;; export just returns a constant so the edge runner asserts the
;; instance stood up rather than any table behaviour.
(module
  (table 5000 funcref)
  (func (export "test") (result i32)
    i32.const 42))
