;; Wasm 3.0 GC: iso-recursive CANONICAL type equality at a call arg.
;; Two SINGLETON rec groups each define `(struct (field i32))` — distinct
;; type indices ($a=0, $b=1) but the SAME canonical type (Wasm 3.0 GC §3.3
;; iso-recursive equivalence). `$get` takes `(ref $a)`; `_start`/`test`
;; passes `(ref $b)` (from `$mk`) — spec-valid because `$b ≡ $a`.
;;
;; Regression: the per-function validator's subtypeCtx used raw-index
;; supertype reach (gcConcreteReaches) and rejected this ("type mismatch:
;; expected (ref $type), found (ref $type)" — same print, different index),
;; while the module-validation path already honoured canonical equality.
;; Fixed by threading the full Types so subtypeCtx uses
;; gcConcreteReachesCanonical (ADR-0126). Surfaced by a Guile-Hoot
;; (Scheme->wasm-gc) corpus module at func #84; wasm-tools validates it.
;;
;; Stress axes (test_discipline.md §1): GC subtyping (cross-rec-group
;; canonical identity) × call-arg type check. Returns the struct field = 99.
;;
;; Provenance: minimal reduction of /tmp/hoot-spike (front ③ GC corpus);
;; assembled with wasm-tools parse.
(module
  (rec (type $a (struct (field i32))))
  (rec (type $b (struct (field i32))))
  (func $mk (result (ref $b))
    i32.const 99
    struct.new $b)
  (func $get (param (ref $a)) (result i32)
    local.get 0
    struct.get $a 0)
  (func (export "test") (result i32)
    call $mk
    call $get))
