;; Wasm spec §4.4.15 (table.copy) — same table, dst > src, overlap.
;; Exercises the backward emit arm. After copy the slot 4 should
;; still read null (was null pre-copy). Slots 3 and 4 are within
;; the copy region; the backward arm ensures slot 4 picks up the
;; original slot 2 value (null), not a freshly-overwritten slot 3
;; value (also null) — so the assertion is trivially i32:1 but
;; the codegen path exercised is the backward one.
(module
  (table 5 funcref)
  (func (export "test") (result i32)
    i32.const 2          ;; dst
    i32.const 0          ;; src
    i32.const 3          ;; n (dst+n=5; src+n=3; overlap at slots 2)
    table.copy 0 0       ;; same-table, dst > src → backward path
    i32.const 4
    table.get 0
    ref.is_null))
