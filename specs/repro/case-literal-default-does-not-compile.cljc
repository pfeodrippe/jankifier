; RESULTS.md S8.
; A case whose default is a number or boolean literal doesn't compile: the generated C++ assigns
; the literal's native value to the result object ("no viable overloaded '='", from case*).
; jank compiles a function's body when it's first called, so the error shows then.
(defn with-keyword [k] (case k :a 1 :other))
(println "expected :other, (case k :a 1 :other):" (pr-str (with-keyword :b)))
(defn with-true [k] (case k :a 1 true))
(println "expected true, (case k :a 1 true):    " (pr-str (with-true :b)))
