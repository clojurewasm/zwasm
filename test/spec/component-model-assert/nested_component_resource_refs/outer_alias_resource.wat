;; Invalid component (DETECTED — assert_invalid rejects as InvalidAlias, rule 12): a nested inline component
;; outer-aliases the parent's resource type; aliasing a resource-carrying type
;; across a component boundary is invalid ("refers to resources not defined in
;; the current component", resources.wast ~5 cases). Detecting this needs
;; recursive nested-component decode — the decoder currently enumerates
;; top-level sections only and leaves inner component sections undecoded.
(component $A
  (type $t (resource (rep i32)))
  (component (alias outer $A $t (type $foo)))
)
