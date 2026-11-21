; RESULTS.md C8.
; On macOS, future-cancel cancels the thread (pthread_cancel) but nothing records it: it returns
; nil, future-cancelled? and realized? stay false, and deref returns nil. Clojure: true, true,
; true, and deref throws a CancellationException.
#?(:jank (cpp/raw "#include <unistd.h>"))
#?(:jank (cpp/raw "#include <cstdio>"))
(def f (future #?(:jank (cpp/usleep 5000000) :clj (Thread/sleep 5000)) :done))
#?(:jank (cpp/usleep 200000) :clj (Thread/sleep 200))
(println "expected true, future-cancel:     " (pr-str (future-cancel f)))
(println "expected true, future-cancelled?: " (pr-str (future-cancelled? f)))
(println "expected true, realized?:         " (pr-str (realized? f)))
(println "expected threw, deref:            " (try (pr-str @f) (catch #?(:jank :default :clj Throwable) _ "threw")))
#?(:jank (do (cpp/fflush cpp/stdout) (cpp/_exit 0)) :clj (shutdown-agents))
