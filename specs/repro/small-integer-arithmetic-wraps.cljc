; RESULTS.md S10.
; Integer arithmetic wraps at 32 bits: integers that fit in 32 bits are small_integers, and +, -
; and * of two of them compute in i32 before boxing (runtime/core/math.hpp). No error. (inc and +'
; promote.)
(defn add [a b] (+ a b))
(println "expected 2147483648, (inc 2147483647):                " (pr-str (inc 2147483647)))
(println "expected 2147483648, (+ 2147483647 1):                " (pr-str (+ 2147483647 1)))
(println "expected 2147483648, (add 2147483647 1):              " (pr-str (add 2147483647 1)))
(println "expected 1000000000000000000, (* 1000000000 1000000000):" (pr-str (* 1000000000 1000000000)))
(println "expected 3000000000, (reduce + (repeat 3 1000000000)):  " (pr-str (reduce + (repeat 3 1000000000))))
(println "expected -2147483649, (- -2147483648 1):              " (pr-str (- -2147483648 1)))
