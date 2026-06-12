;; Invalid component: export name `BadEXPort` mixes case within a word —
;; not kebab case (Explainer.md `exportname` → `plainname` → `label`).
;; ADR-0176 validator rule 5.
(component
  (type $t (func))
  (export "BadEXPort" (type $t))
)
