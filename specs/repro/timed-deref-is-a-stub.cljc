; RESULTS.md S3.
; (deref ref timeout-ms timeout-val) is an empty function in clojure/core.jank ("TODO: Blocking"):
; it returns nil at once, without waiting for the value or returning timeout-val.
#?(:jank (cpp/raw "#include <unistd.h>"))
#?(:jank (cpp/raw "#include <cstdio>"))
(println "expected 1, a delivered promise:     " (pr-str (deref (doto (promise) (deliver 1)) 10 :timeout)))
(println "expected :timeout, a pending promise: " (pr-str (deref (promise) 10 :timeout)))
(println "expected :timeout, a slow future:     "
         (pr-str (deref (future #?(:jank (cpp/usleep 2000000) :clj (Thread/sleep 2000)) 1) 10 :timeout)))
#?(:jank (do (cpp/fflush cpp/stdout) (cpp/_exit 0)) :clj (shutdown-agents))
