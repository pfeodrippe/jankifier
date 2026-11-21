; RESULTS.md A6 (V7). Shared with Clojure.
; "require: Loads libs, skipping any that are already loaded." load-lib reads *loaded-libs*, loads
; the lib, and only then adds it, with no lock around the two, so two threads requiring the same
; lib at once can both load it. 200 runs, forgetting the lib between them.
; Run from this directory: `jank run --module-path . require-race.cljc`, or
; `clojure -Sdeps '{:paths ["."]}' -M require-race.cljc`.
(def loads (atom 0))
(defn forget []
  #?(:jank (swap! @#'clojure.core/*loaded-libs* disj 'repro-require-lib)
     :clj (dosync (commute @#'clojure.core/*loaded-libs* disj 'repro-require-lib))))
(defn run []
  (forget)
  (let [go (promise) before @loads
        fs (doall (for [_ (range 2)] (future @go (require 'repro-require-lib))))]
    (deliver go true)
    (doseq [f fs] @f)
    (- @loads before)))
(println "expected {1 200}, times the lib's body ran, per run:" (frequencies (repeatedly 200 run)))
#?(:clj (shutdown-agents))
