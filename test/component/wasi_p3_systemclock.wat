;; Official WASI 0.3.0 clocks surface: system-clock (the renamed 0.2 wall-clock,
;; instant{seconds: s64, nanoseconds: u32}) + get-resolution on both clocks.
;; exit(0) iff now().seconds is past 2017 (> 1_500_000_000) AND both clock
;; resolutions are sane (0 < res <= 1s), else exit(1).
;; Exercises the clocks_system_now / clocks_system_get_resolution /
;; clocks_monotonic_get_resolution trampolines: now() -> instant lowers to a
;; core (i32 retptr)->() with the 12-byte record written at retptr;
;; get-resolution() -> duration(u64) lowers to ()->i64.
(component
  (import "wasi:clocks/system-clock@0.3.0" (instance $sys
    (type $instant-def (record (field "seconds" s64) (field "nanoseconds" u32)))
    (export "instant" (type $instant (eq $instant-def)))
    (export "now" (func (result $instant)))
    (export "get-resolution" (func (result u64)))))
  (import "wasi:clocks/monotonic-clock@0.3.0" (instance $mono
    (export "get-resolution" (func (result u64)))))
  (import "wasi:cli/exit@0.3.0" (instance $cli-exit
    (export "exit" (func (param "status" (result))))))

  (core module $libc (memory (export "memory") 1))
  (core instance $libc (instantiate $libc))
  (core func $sys-now (canon lower (func $sys "now") (memory $libc "memory")))
  (core func $sys-res (canon lower (func $sys "get-resolution")))
  (core func $mono-res (canon lower (func $mono "get-resolution")))
  (core func $exit (canon lower (func $cli-exit "exit")))

  (core module $M
    (import "io" "sys-now" (func $sys_now (param i32)))  ;; retptr to a 12-byte instant area
    (import "io" "sys-res" (func $sys_res (result i64)))
    (import "io" "mono-res" (func $mono_res (result i64)))
    (import "io" "exit" (func $exit (param i32)))
    (import "libc" "memory" (memory 1))
    ;; 0 < res <= 1s (1_000_000_000 ns) — sane host clock granularity.
    (func $res_sane (param $r i64) (result i32)
      (i32.and
        (i64.gt_u (local.get $r) (i64.const 0))
        (i64.le_u (local.get $r) (i64.const 1000000000))))
    (func (export "run") (result i32)
      (call $sys_now (i32.const 16))                 ;; write instant at offset 16
      (if (i32.and
            (i64.gt_s (i64.load (i32.const 16)) (i64.const 1500000000)) ;; seconds @ 16 (s64)
            (i32.and
              (call $res_sane (call $sys_res))
              (call $res_sane (call $mono_res))))
        (then (call $exit (i32.const 0)))
        (else (call $exit (i32.const 1))))
      (i32.const 0)))

  (core instance $deps-io
    (export "sys-now" (func $sys-now))
    (export "sys-res" (func $sys-res))
    (export "mono-res" (func $mono-res))
    (export "exit" (func $exit)))
  (core instance $m (instantiate $M
    (with "io" (instance $deps-io))
    (with "libc" (instance $libc))))

  (type $run-result (result))
  (func $run (result $run-result) (canon lift (core func $m "run")))
  (component $RunShim
    (import "import-func-run" (func $rf (result (result))))
    (export "run" (func $rf)))
  (instance $run-inst (instantiate $RunShim (with "import-func-run" (func $run))))
  (export "wasi:cli/run@0.3.0" (instance $run-inst))
)
