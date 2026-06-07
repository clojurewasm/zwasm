;; Adversarial fixture (D-308): a WASI-P2 component importing an UNKNOWN wasi
;; interface alongside a supported one. `wasi:sockets/tcp` is not in the
;; adapter's classify table (sockets = D3-8, deferred), so building the host
;; synthetic instance must raise a CLEAN `error.UnsupportedWasiImport` — never a
;; SIGNAL from the deferred instance/linker/module cleanup. A guest core
;; instance ($pre) is built BEFORE the failing host instance so the cleanup runs
;; with already-appended modules/linkers/instances (the partial-state path the
;; original D3-2 RED run crashed on).
(component
  (import "wasi:cli/exit@0.2.0" (instance $cli-exit
    (export "exit" (func (param "status" (result))))))
  (import "wasi:sockets/tcp@0.2.0" (instance $sock
    (export "bogus-op" (func))))

  (core func $exit (canon lower (func $cli-exit "exit")))
  (core func $bogus (canon lower (func $sock "bogus-op")))

  ;; A standalone guest module instantiated first — forces the cleanup to run
  ;; with a non-empty modules/linkers/instances list when the host instance fails.
  (core module $Pre
    (func (export "noop")))
  (core instance $pre (instantiate $Pre))

  (core module $M
    (import "io" "exit" (func $exit (param i32)))
    (import "io" "bogus" (func $bogus))
    (func (export "run") (result i32)
      (call $exit (i32.const 1))
      (i32.const 0)))

  ;; Host synthetic instance: exit classifies OK, bogus → UnsupportedWasiImport.
  (core instance $deps-io
    (export "exit" (func $exit))
    (export "bogus" (func $bogus)))
  (core instance $m (instantiate $M (with "io" (instance $deps-io))))

  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.2.0" (instance $run-inst))
)
