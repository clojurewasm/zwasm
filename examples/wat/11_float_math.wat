;; Floating-point operations with hardcoded inputs.
;; NOTE: The CLI displays f64 results as raw i64 bit patterns.
;; Use Python to decode: struct.unpack('d', struct.pack('q', VALUE))
;;
;; Run: zwasm run --invoke pi_area_r5 examples/wat/11_float_math.wat
;; Output: 4635227165180642107 (= 78.5398... as f64 bits)
;; Run: zwasm run --invoke distance_3_4 examples/wat/11_float_math.wat
;; Output: 4617315517961601024 (= 5.0 as f64 bits)
;; Run: zwasm run --invoke c_to_f_100 examples/wat/11_float_math.wat
;; Output: 4641663103447072768 (= 212.0 as f64 bits)
(module
  ;; Area of a circle with radius 5: pi * 5^2 = 78.5398...
  (func (export "pi_area_r5") (result f64)
    (f64.mul
      (f64.const 3.141592653589793)
      (f64.mul (f64.const 5.0) (f64.const 5.0))))

  ;; Euclidean distance from origin for (3, 4): sqrt(9 + 16) = 5.0
  (func (export "distance_3_4") (result f64)
    (f64.sqrt
      (f64.add
        (f64.mul (f64.const 3.0) (f64.const 3.0))
        (f64.mul (f64.const 4.0) (f64.const 4.0)))))

  ;; Celsius to Fahrenheit: 100C = 212F
  (func (export "c_to_f_100") (result f64)
    (f64.add
      (f64.mul (f64.const 100.0) (f64.div (f64.const 9.0) (f64.const 5.0)))
      (f64.const 32.0)))

  ;; Clamp demo: clamp(15.0, 0.0, 10.0) = 10.0
  (func (export "clamp_demo") (result f64)
    (f64.min (f64.max (f64.const 15.0) (f64.const 0.0)) (f64.const 10.0))))
