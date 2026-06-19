;; Invalid component (DETECTED — assert_invalid rejects as InvalidName): an `integrity=<...>` hash
;; extern name whose payload is not valid base64 ("not valid base64",
;; import.wast ~5 cases). Validator rule 5 deliberately accepts `=`-carrying
;; importname forms unchecked (depname/urlname/hashname grammars deferred).
(component
  (import "integrity=<sha256-!!!not-base64!!!>" (func))
)
