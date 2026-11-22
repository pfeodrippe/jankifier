; RESULTS.md S6.
; re-find and re-matches give "" for an optional group that didn't match; Clojure gives nil.
(println "expected [\"ab\" \"b\"], (re-find #\"a(b)?\" \"ab\"):" (pr-str (re-find #"a(b)?" "ab")))
(println "expected [\"a\" nil], (re-find #\"a(b)?\" \"a\"):  " (pr-str (re-find #"a(b)?" "a")))
(println "expected [\"a\" nil], (re-matches #\"a(b)?\" \"a\"):" (pr-str (re-matches #"a(b)?" "a")))
