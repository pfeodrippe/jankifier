; RESULTS.md C2.
; compare-and-set! is one std::atomic::compare_exchange_weak (obj/atom.cpp:220), which C++ allows
; to fail even when the atom holds the expected value. Clojure's compareAndSet never does. Whether
; it happens depends on the CPU jank was compiled for: on Apple Silicon the compiler emits the CAS
; instruction (casal, as jank 0.1's binary has), which can't fail spuriously, so this prints 0
; there. On a CPU without it (ARMv8.0, e.g. a Raspberry Pi 4's Cortex-A72), it's a load-exclusive
; / store-exclusive pair, which fails whenever another core stores to the same memory in between,
; even the same value. compare-exchange-weak-spurious.cpp shows that on this machine, by compiling
; the same C++ call for both CPUs. Here another thread keeps storing the atom's current value
; while this one compare-and-set!s it with that value, 200000 times.
(def a (atom 0))
(def stop (atom false))
(def other (future (while (not @stop) (swap! a identity))))
(def spurious
  (loop [i 0 n 0]
    (if (= i 200000)
      n
      (let [v @a]
        (recur (inc i) (if (and (not (compare-and-set! a v v)) (identical? v @a)) (inc n) n))))))
(reset! stop true)
@other
(println "expected 0, compare-and-set! failures with the expected value in place, of 200000:" spurious)
#?(:clj (shutdown-agents))
