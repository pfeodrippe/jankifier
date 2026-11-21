; RESULTS.md A6 (V5). Shared with Clojure.
; "After the body is executed, the root values of all the Vars will be set back to their old
; values." with-redefs reads the old root, binds the new one, runs the body, and binds the old one
; back. Two threads doing it on one var at once: the second can read the first's temporary value
; as "old", and restore it last. 2000 runs.
#?(:jank (cpp/raw "#include <unistd.h>"))
(def y 3)
(defn run []
  (alter-var-root #'y (constantly 3))
  (let [go (promise)
        fs (doall (for [_ (range 2)]
                    (future @go (with-redefs [y 50] #?(:jank (cpp/usleep 50) :clj (Thread/sleep 0 50000))))))]
    (deliver go true)
    (doseq [f fs] @f)
    y))
(println "expected {3 2000}, the root after both, per run:" (frequencies (repeatedly 2000 run)))
#?(:clj (shutdown-agents))
