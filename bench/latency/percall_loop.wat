;; Per-call latency guest. One structure, one knob: the loop trip count is a
;; runtime parameter so no engine can fold it away, and the accumulator is
;; returned so none can delete the loop. 13 wasm instructions per trip.
(module
  (func (export "work") (param $n i32) (result i32)
    (local $i i32) (local $acc i32)
    (block $done
      (loop $lp
        (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $acc (i32.add (local.get $acc) (local.get $i)))
        (local.set $i   (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $acc)))
