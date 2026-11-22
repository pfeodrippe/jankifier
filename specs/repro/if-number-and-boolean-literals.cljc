; RESULTS.md S7.
; An if with a number literal in one branch and a boolean literal in the other gets the number's
; C++ type, so the boolean comes back as a number (true as 1, false as 0), with no error.
(defn with-keyword [k] (if (= k :a) :one true))
(println "expected true, (if c :one true) when c is false:" (pr-str (with-keyword :b)))
(defn with-true [k] (if (= k :a) 1 true))
(println "expected true, (if c 1 true) when c is false:   " (pr-str (with-true :b)))
(defn with-false [k] (if (= k :a) 1 false))
(println "expected false, (if c 1 false) when c is false: " (pr-str (with-false :b)))
