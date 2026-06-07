;; D-302 — a module carrying the branch-hinting proposal's
;; `metadata.code.branch_hint` CUSTOM section must parse + run with the
;; hints IGNORED (advisory QoI, no semantic effect). v1 advertised Branch
;; Hinting COMPLETE; v2 accepts the section via the generic custom-section
;; skip path. The custom section is appended to this module's .wasm by the
;; fixture generator (wat cannot express custom sections).
(module
  (func (export "test") (result i32) (i32.const 42)))
