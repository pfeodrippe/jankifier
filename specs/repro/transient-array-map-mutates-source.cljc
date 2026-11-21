; RESULTS.md A1 (also determinismo's jank analysis, §3.14).
; A transient of an array map (every map of up to 8 entries) shares the persistent map's array
; (native_array_map's copy constructor is `= default`) and writes into it: assoc! of an existing
; key overwrites the source, dissoc! shifts it (a key twice), a persistent! result changes when a
; later transient of it does, and clojure.core functions built on transients change their argument.
; Clojure leaves every source as it was. Hash maps aren't affected.
(let [m (zipmap (range 20) (range 20)) _ (persistent! (assoc! (transient m) 0 99))]
  (println "expected 0, a hash map after assoc!:                   " (get m 0)))
(let [m {:a 1} _ (persistent! (assoc! (transient m) :a 2))]
  (println "expected {:a 1}, an array map after assoc!:            " m))
(let [m {:a 1 :b 2} _ (persistent! (dissoc! (transient m) :a))]
  (println "expected {:a 1, :b 2}, after dissoc!:                  " m))
(let [r (persistent! (transient {:a 1})) _ (persistent! (assoc! (transient r) :a 3))]
  (println "expected {:a 1}, a persistent! result, after a transient of it:" r))
(let [m {:a 1 :b 2} _ (into m {:a 9})]
  (println "expected {:a 1, :b 2}, after (into m {:a 9}):          " m))
(let [m {:a 1 :b 2} _ (update-vals m inc)]
  (println "expected {:a 1, :b 2}, after (update-vals m inc):      " m))
