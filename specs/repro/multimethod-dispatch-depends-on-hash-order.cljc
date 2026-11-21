; RESULTS.md A4. Shared with Clojure.
; With methods on i, j and k, where k derives from both i and j and the dispatch value d derives
; from k, k is the most specific match. The dispatch loop (Clojure's findAndCacheBestMethod,
; copied by jank) throws "multiple methods" when the method table's hash order puts i and j before
; k. This runs 40 such multimethods, with different keyword names, so different hash orders.
(defmacro one [n]
  (let [kw (fn [p] (keyword "t" (str p n)))
        f (symbol (str "f" n))]
    `(do (derive ~(kw "d") ~(kw "k")) (derive ~(kw "k") ~(kw "i")) (derive ~(kw "k") ~(kw "j"))
         (defmulti ~f identity)
         (defmethod ~f ~(kw "i") [~'_] :i)
         (defmethod ~f ~(kw "j") [~'_] :j)
         (defmethod ~f ~(kw "k") [~'_] :k)
         (try (~f ~(kw "d")) (catch #?(:jank :default :clj Throwable) ~'_ :threw)))))
(defmacro all [] `(vector ~@(for [n (range 40)] `(one ~n))))
(println "expected {:k 40}, results of 40 dispatches:" (frequencies (all)))
