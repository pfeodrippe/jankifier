; RESULTS.md C5.
; A delay whose body derefs the delay itself: jank's delay deref takes a std::mutex (not
; recursive), so the body's deref waits for itself forever. Clojure's Delay locks with
; synchronized (reentrant): the body runs again and again until the stack overflows, and the deref
; throws. Either way it can't return a value, but jank hangs instead of throwing.
#?(:jank (cpp/raw "#include <unistd.h>"))
#?(:jank (cpp/raw "#include <cstdio>"))
(def d (delay (inc @d)))
(def f (future (try @d (catch #?(:jank :default :clj Throwable) _ :threw))))
#?(:jank (cpp/usleep 3000000) :clj (Thread/sleep 3000))
(println "expected :threw:" (if (realized? f) (pr-str @f) "still running after 3 s"))
#?(:jank (do (cpp/fflush cpp/stdout) (cpp/_exit 0)) :clj (shutdown-agents))
