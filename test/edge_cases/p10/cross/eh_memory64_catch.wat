;; Wasm 3.0 cross-feature: exception-handling × memory64.
;; A `try_table (catch $e $h)` body stores 55 to an i64-indexed
;; `(memory i64 1)`, loads it back, then `throw`s tag `$e (param i32)`
;; carrying the loaded value → caught → block result 55. Exercises EH-
;; on-JIT unwinding (ADR-0114) sharing a frame with memory64 i64-
;; addressing (D-209): the throw site is reached after a memory64 op,
;; so the trap-stub / landing-pad path must coexist with the memory64
;; vm_base/mem_limit reload in the same function.
;;
;; Stress axes (test_discipline.md §1): control flow (throw/catch) +
;; ABI boundary (R15 used by both memory64 ops and the EH trampoline). → 55.
;;
;; Provenance: internally derived from 10.P I3 cross-feature close-prep
;; (cyc216); assembled with wasm-tools parse.
(module
  (tag $e (param i32))
  (memory i64 1)
  (func (export "test") (result i32)
    (block $h (result i32)
      (try_table (result i32) (catch $e $h)
        i64.const 24
        i32.const 55
        i32.store offset=0 align=2
        i64.const 24
        i32.load offset=0 align=2
        throw $e))))
