;; D-310 boundary fixture: an imported HOST func placed in a funcref table via
;; an active elem segment, then reached by call_indirect. Before the fix the
;; imported func's placeholder carried an empty ()->() sig (type mismatch) and
;; call_indirect executed the placeholder body instead of dispatching to the
;; host thunk. run(x) = inc(x) via the table => x+1.
(module
  (type $t (func (param i32) (result i32)))
  (import "env" "inc" (func $inc (type $t)))
  (table 1 1 funcref)
  (elem (i32.const 0) $inc)
  (func (export "run") (param i32) (result i32)
    (local.get 0)
    (i32.const 0)
    (call_indirect (type $t))))
