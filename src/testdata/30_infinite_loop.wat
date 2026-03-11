(module
  (func (export "loop") (result i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $break
      (loop $continue
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $continue)
      )
    )
    (local.get $i)
  )
)
