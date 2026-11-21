; RESULTS.md A6 (V4). Shared with Clojure.
; "defonce: defs name to have the root value of the expr iff the named var has no root value, else
; expr is unevaluated." defonce checks bound? and then defs, as separate steps, so two threads
; that defonce one var at once can both evaluate the expression. 200 runs, a new var each.
(def evals (atom 0))
(defmacro one [n]
  (let [v (symbol (str "d" n))]
    `(let [go# (promise) before# @evals
           fs# (doall (for [_# (range 2)] (future @go# (defonce ~v (do (swap! evals inc) 7)))))]
       (deliver go# true)
       (doseq [f# fs#] @f#)
       (- @evals before#))))
(def results (atom []))
;; One top-level form per run (a single 200-element form is too large for Clojure's compiler).
(defmacro all [] `(do ~@(for [n (range 200)] `(swap! results conj (one ~n)))))
(all)
(println "expected {1 200}, times the expression ran, per run:" (frequencies @results))
#?(:clj (shutdown-agents))
