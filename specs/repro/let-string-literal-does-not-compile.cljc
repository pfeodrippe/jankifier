; RESULTS.md S2.
; A let* or loop (so let and loop) whose value is a string literal doesn't compile: codegen
; declares the result with the literal's C++ type (`const char[3] v2{ };`, "brackets are not
; allowed here"). do, letfn, and a let whose value is (str "ok") compile.
(defn passing [x] (let [t x] (str "ok")))
(println "expected ok, (let [t x] (str \"ok\")):" (passing 1))
(defn failing [x] (let [t x] "ok"))
(println "expected ok, (let [t x] \"ok\"):" (failing 1))
