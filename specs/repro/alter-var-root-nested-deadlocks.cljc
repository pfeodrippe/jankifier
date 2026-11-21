; RESULTS.md A5.
; alter_root holds write_mutex (a folly::SharedMutex, not recursive) while it calls the function,
; so a function that alters the same var waits for itself forever. Clojure's alterRoot is
; synchronized (reentrant): the inner alter runs, then the outer stores (inc 0), so the root is 1.
; (deref with a timeout is a stub in jank, see timed-deref-is-a-stub.cljc, so this waits 3 s and
; asks realized?.)
#?(:jank (cpp/raw "#include <unistd.h>"))
#?(:jank (cpp/raw "#include <cstdio>"))
(def z 0)
(def f (future (alter-var-root #'z (fn [v] (alter-var-root #'z inc) (inc v)))))
#?(:jank (cpp/usleep 3000000) :clj (Thread/sleep 3000))
(println "expected returned, root 1:" (if (realized? f) (str "returned, root " z) "still running after 3 s"))
#?(:jank (do (cpp/fflush cpp/stdout) (cpp/_exit 0)) :clj (shutdown-agents))
