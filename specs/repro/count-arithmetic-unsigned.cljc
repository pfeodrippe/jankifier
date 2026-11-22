; RESULTS.md S9.
; Arithmetic on count's result is unsigned when jank compiles it natively (count gives a C++
; usize): below zero it wraps around, so comparisons see a huge number, while functions that box
; it (neg?, pr-str) see a negative one.
(defn below [s] (- (count s) 3000))
(defn below-zero? [s] (< (- (count s) 3000) 0))
(defn at-least-zero [s] (max 0 (- (count s) 3000)))
(println "expected -2997, (- (count \"abc\") 3000):          " (pr-str (below "abc")))
(println "expected true, (< (- (count \"abc\") 3000) 0):     " (pr-str (below-zero? "abc")))
(println "expected 0, (max 0 (- (count \"abc\") 3000)):      " (pr-str (at-least-zero "abc")))
