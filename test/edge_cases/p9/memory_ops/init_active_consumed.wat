;; Wasm spec §4.5.5 — active data segments are consumed at
;; instantiation; their effective size becomes 0 for any
;; subsequent `memory.init`. Without an explicit `data.drop`,
;; calling `memory.init` on the active segment with n > 0 traps
;; "out of bounds memory access". §9.9 / 9.9-l-1b-d093-d50 fix
;; (D-119/D-120): both `setupRuntime` (standalone) and
;; `populateDataSegments` (spec_assert harness) mark active
;; segments as dropped at module load so this trap fires.
(module
  (memory 1)
  (data (i32.const 0) "x")
  (func (export "test") (result i32)
    i32.const 0
    i32.const 0
    i32.const 1
    memory.init 0
    i32.const 0))
