; RESULTS.md C3.
; A future's thread pushes its conveyed binding frame and never pops it; frames are kept per OS
; thread id and never removed; macOS reuses thread ids. So a later future that gets the same
; thread id starts from the stale frame and sees an earlier future's binding. 200 tries.
(def ^:dynamic *x* :root)
(defn once []
  @(binding [*x* :v1] (future *x*))
  @(future *x*))
(println "expected 0, futures created outside the binding that saw it, of 200:"
         (count (filter #(= :v1 %) (repeatedly 200 once))))
