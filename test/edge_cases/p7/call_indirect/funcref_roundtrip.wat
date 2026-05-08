;; Boundary: call_indirect through a funcref table populated by
;; an active element segment. Pre-7.10-m the runtime's
;; `funcptrs_buf` was zero-initialised only — call_indirect
;; loaded a NULL funcptr and SEGV'd at PC=0 on every fixture in
;; the realworld corpus (D-049).
;;
;; Wasm spec §4.5.7 (table.init / element-segment instantiation)
;; defines the runtime semantics this fixture exercises:
;;   - declared table `(table 1 funcref)` allocates one slot;
;;   - active element segment installs `$callee` at table[0];
;;   - exported `test` does `i32.const 0; call_indirect (type $i)`,
;;     dispatching to `$callee` which returns 42.
;;
;; Provenance: §9.7 / 7.10-m — minimal call_indirect roundtrip
;; isolating the SEGV root cause from the realworld corpus
;; (which mixes call_indirect with WASI imports + complex bodies).
(module
  (type $i (func (result i32)))
  (table 1 funcref)
  (elem (i32.const 0) $callee)
  (func $callee (type $i)
    i32.const 42)
  (func (export "test") (result i32)
    i32.const 0
    call_indirect (type $i)))
