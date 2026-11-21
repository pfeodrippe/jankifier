; RESULTS.md A2.
; "persistent! ... The transient collection cannot be used after this call, any such use will
; throw an exception." Seven reads don't check that the transient is still active
; (assert_active) and return its data: on a vector nth (one argument), contains?, find; on an
; array map get with a fallback, contains?, find, and calling it with a fallback. Clojure throws.
(defmacro after [label coll form]
  `(println ~label (try (let [~'t (transient ~coll)] (persistent! ~'t) (pr-str ~form))
                        (catch #?(:jank :default :clj Throwable) ~'_ "threw"))))
(after "expected threw, vector count:           " [1] (count t))
(after "expected threw, vector nth:             " [1] (nth t 0))
(after "expected threw, vector contains?:       " [1] (contains? t 0))
(after "expected threw, vector find:            " [1] (find t 0))
(after "expected threw, array map get:          " {0 1} (get t 0))
(after "expected threw, array map get, fallback:" {0 1} (get t 0 :nf))
(after "expected threw, array map contains?:    " {0 1} (contains? t 0))
(after "expected threw, array map find:         " {0 1} (find t 0))
(after "expected threw, array map call fallback:" {0 1} (t 0 :nf))
