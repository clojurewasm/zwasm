;; Wasm 3.0 GC `Heaptype_sub/func`: a CONCRETE func typedef's head is `func`,
;; so `(ref $ft)` satisfies `funcref` / `(ref func)`. This is the ADR-0123
;; case (`ref_func.1`) and it must survive the kind-aware narrowing that stops
;; a struct/array typedef from satisfying the same slots: before that change
;; the validator answered "yes" for EVERY concrete index regardless of kind,
;; and a `(ref $struct)` reaching a funcref slot was later read as a func
;; entity (`refAsFuncEntity` — a fatal signal on the JIT, an alignment panic
;; on the interp). Narrowing that rule must not take this case with it.
;;
;; Stress axes (test_discipline.md §1): validator boundary (concrete typedef
;; -> abstract head) x head kind (func, the one kind that DOES reach `func`)
;; x site (local.set / call argument / table.set) x execution (the funcref
;; actually survives the round trip and is called through call_indirect).
;;
;; Provenance: hand-written guard for the narrowing; wasm-tools parse.
(module
  (type $ft (func (result i32)))
  (func $seven (type $ft) (result i32) i32.const 7)
  (elem declare func $seven)
  (table 1 funcref)

  (func $takes (param funcref) (result i32)
    local.get 0
    ref.is_null)

  (func (export "test") (result i32)
    (local $l funcref)
    ref.func $seven          ;; (ref $ft) -> funcref local
    local.set $l
    local.get $l
    ref.is_null              ;; 0
    ref.func $seven          ;; (ref $ft) -> funcref call argument
    call $takes              ;; 0
    i32.add                  ;; 0
    i32.const 0
    ref.func $seven          ;; (ref $ft) -> funcref table element
    table.set 0
    i32.const 0
    call_indirect (type $ft) ;; 7
    i32.add))                ;; 7
