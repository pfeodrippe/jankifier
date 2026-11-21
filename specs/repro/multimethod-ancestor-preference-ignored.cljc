; RESULTS.md A3.
; Dispatch ignores a prefer-method declared on an ancestor of a dispatch value: is_preferred gets
; the hierarchy var (reset_cache stores `hierarchy`, not its value), and (parents var tag) is nil,
; so jank throws "multiple methods" where Clojure uses the preferred method.
(defmacro attempt [form]
  `(try (pr-str ~form) (catch #?(:jank :default :clj Throwable) ~'_ "threw")))
;; A direct preference works.
(derive ::x ::p) (derive ::x ::q)
(defmulti h identity)
(defmethod h ::p [_] :p)
(defmethod h ::q [_] :q)
(prefer-method h ::p ::q)
(println "expected :p, a direct preference:                     " (attempt (h ::x)))
;; The preference is on ::a2's parent ::a.
(derive ::c ::a2) (derive ::a2 ::a) (derive ::c ::b)
(defmulti f identity)
(defmethod f ::a2 [_] :a2)
(defmethod f ::b [_] :b)
(prefer-method f ::a ::b)
(println "expected :a2, preferred through its parent:            " (attempt (f ::c)))
;; The model checker's counterexample: ::v0 is preferred over ::v1, which ::v2 derives from.
(derive ::v3 ::v2) (derive ::v2 ::v1) (derive ::v3 ::v0)
(defmulti g identity)
(defmethod g ::v0 [_] :v0)
(defmethod g ::v2 [_] :v2)
(prefer-method g ::v0 ::v1)
(println "expected :v0, preferred over the other's parent:       " (attempt (g ::v3)))
