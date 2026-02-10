;; N-body simulation (simplified 2-body) — f64-heavy benchmark
;; Simulates gravitational interaction for N steps
;; Returns final position x1 as f64 bits (i64)
(module
  (memory (export "memory") 1)

  ;; Body layout in memory (2 bodies, each 48 bytes):
  ;; offset 0: x (f64), y (f64), z (f64), vx (f64), vy (f64), vz (f64)
  ;; Body 0: offset 0
  ;; Body 1: offset 48

  (func $init (export "init")
    ;; Body 0: Sun at origin, zero velocity
    (f64.store (i32.const 0)  (f64.const 0.0))   ;; x
    (f64.store (i32.const 8)  (f64.const 0.0))   ;; y
    (f64.store (i32.const 16) (f64.const 0.0))   ;; z
    (f64.store (i32.const 24) (f64.const 0.0))   ;; vx
    (f64.store (i32.const 32) (f64.const 0.0))   ;; vy
    (f64.store (i32.const 40) (f64.const 0.0))   ;; vz

    ;; Body 1: Jupiter-like orbit
    (f64.store (i32.const 48)  (f64.const 4.84143144246472090))  ;; x
    (f64.store (i32.const 56)  (f64.const -1.16032004402742839)) ;; y
    (f64.store (i32.const 64)  (f64.const -0.10362204447112311)) ;; z
    (f64.store (i32.const 72)  (f64.const 0.00166007664274403694)) ;; vx
    (f64.store (i32.const 80)  (f64.const 0.00769901118419740425)) ;; vy
    (f64.store (i32.const 88)  (f64.const -0.0000690460016972063023)) ;; vz
  )

  ;; Combined init + advance for CLI benchmarking (single invocation)
  (func (export "run") (param $steps i32) (result i64)
    (call $init)
    (call $advance (local.get $steps))
  )

  (func $advance (export "advance") (param $steps i32) (result i64)
    (local $i i32)
    (local $dt f64)
    (local $dx f64) (local $dy f64) (local $dz f64)
    (local $dist2 f64) (local $dist f64) (local $mag f64)
    (local $mass0 f64) (local $mass1 f64)

    (local.set $dt (f64.const 0.01))
    (local.set $mass0 (f64.const 39.4784176)) ;; 4*pi^2 (solar mass in natural units)
    (local.set $mass1 (f64.const 0.03769367)) ;; Jupiter mass ratio * 4pi^2

    (local.set $i (i32.const 0))
    (block $done
      (loop $step
        (br_if $done (i32.ge_s (local.get $i) (local.get $steps)))

        ;; dx = x0 - x1, dy = y0 - y1, dz = z0 - z1
        (local.set $dx (f64.sub (f64.load (i32.const 0)) (f64.load (i32.const 48))))
        (local.set $dy (f64.sub (f64.load (i32.const 8)) (f64.load (i32.const 56))))
        (local.set $dz (f64.sub (f64.load (i32.const 16)) (f64.load (i32.const 64))))

        ;; dist2 = dx*dx + dy*dy + dz*dz
        (local.set $dist2
          (f64.add
            (f64.add
              (f64.mul (local.get $dx) (local.get $dx))
              (f64.mul (local.get $dy) (local.get $dy))
            )
            (f64.mul (local.get $dz) (local.get $dz))
          )
        )

        ;; dist = sqrt(dist2), mag = dt / (dist2 * dist)
        (local.set $dist (f64.sqrt (local.get $dist2)))
        (local.set $mag (f64.div (local.get $dt)
          (f64.mul (local.get $dist2) (local.get $dist))))

        ;; Update velocities: v0 -= dx*mass1*mag, v1 += dx*mass0*mag
        ;; vx0
        (f64.store (i32.const 24)
          (f64.sub (f64.load (i32.const 24))
            (f64.mul (local.get $dx) (f64.mul (local.get $mass1) (local.get $mag)))))
        ;; vx1
        (f64.store (i32.const 72)
          (f64.add (f64.load (i32.const 72))
            (f64.mul (local.get $dx) (f64.mul (local.get $mass0) (local.get $mag)))))
        ;; vy0
        (f64.store (i32.const 32)
          (f64.sub (f64.load (i32.const 32))
            (f64.mul (local.get $dy) (f64.mul (local.get $mass1) (local.get $mag)))))
        ;; vy1
        (f64.store (i32.const 80)
          (f64.add (f64.load (i32.const 80))
            (f64.mul (local.get $dy) (f64.mul (local.get $mass0) (local.get $mag)))))
        ;; vz0
        (f64.store (i32.const 40)
          (f64.sub (f64.load (i32.const 40))
            (f64.mul (local.get $dz) (f64.mul (local.get $mass1) (local.get $mag)))))
        ;; vz1
        (f64.store (i32.const 88)
          (f64.add (f64.load (i32.const 88))
            (f64.mul (local.get $dz) (f64.mul (local.get $mass0) (local.get $mag)))))

        ;; Update positions: x += vx * dt
        (f64.store (i32.const 0) (f64.add (f64.load (i32.const 0))
          (f64.mul (local.get $dt) (f64.load (i32.const 24)))))
        (f64.store (i32.const 8) (f64.add (f64.load (i32.const 8))
          (f64.mul (local.get $dt) (f64.load (i32.const 32)))))
        (f64.store (i32.const 16) (f64.add (f64.load (i32.const 16))
          (f64.mul (local.get $dt) (f64.load (i32.const 40)))))
        (f64.store (i32.const 48) (f64.add (f64.load (i32.const 48))
          (f64.mul (local.get $dt) (f64.load (i32.const 72)))))
        (f64.store (i32.const 56) (f64.add (f64.load (i32.const 56))
          (f64.mul (local.get $dt) (f64.load (i32.const 80)))))
        (f64.store (i32.const 64) (f64.add (f64.load (i32.const 64))
          (f64.mul (local.get $dt) (f64.load (i32.const 88)))))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $step)
      )
    )

    ;; Return x1 position as i64 (f64 bits)
    (i64.load (i32.const 48))
  )
)
