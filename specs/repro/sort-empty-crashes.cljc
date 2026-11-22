; RESULTS.md S5.
; sort and sort-by of an empty collection return an empty native_vector_sequence, whose first
; reads past its end: SIGSEGV. seq of it is nil, so code that checks seq first works.
(println "expected [], (vec (sort [])):          " (pr-str (vec (sort []))))
(println "expected 1, (first (sort [1])):          " (pr-str (first (sort [1]))))
;; stdio's buffer is lost if jank crashes: flush what came before.
#?(:jank (cpp/raw "#include <cstdio>"))
#?(:jank (cpp/fflush cpp/stdout))
(println "expected nil, (first (sort [])):       " (pr-str (first (sort []))))
