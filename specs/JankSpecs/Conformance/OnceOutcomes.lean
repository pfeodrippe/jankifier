import JankSpecs.Concurrency.Once
import JankSpecs.Conformance.Outcomes

/-!
# The run-once model's outcomes

For the program `conformance/concurrency/once.py` runs on jank (three threads,
each dereffing a delay, delivering a promise and dereffing it, and realizing a
lazy seq whose body throws on its first call), every outcome the model allows:
how many times the delay's body ran and what the derefs got (`v` a value, `e`
the error), the value the promise's derefs got, and how many times the lazy
seq's body ran and how many realizations threw.
-/

namespace Once.Outcomes

open Once JankSpecs.Outcomes

abbrev Th := Fin 3
abbrev St := State (FieldConcreteType Th (Fin 2) body_t_IndT dpc_t_IndT res_t_IndT)

def theory (b : body_t_IndT) : Theory Th (Fin 2) body_t_IndT dpc_t_IndT res_t_IndT :=
  ⟨b, fun _ => true, 0⟩

def sys (b : body_t_IndT) :=
  letI : Veil.LogSwitch := ⟨false⟩
  enumerableTransitionSystem Th (Fin 2) body_t_IndT dpc_t_IndT res_t_IndT (theory b)

def showGot : res_t_IndT → String
  | .ok => "v"
  | .err => "e"
  | .nothing => "-"

def obs (s : St) : String :=
  let got := (List.finRange 3).map fun t => showGot ((s.got : Std.ExtTreeMap Th res_t_IndT).getD t .nothing)
  let pv := (List.finRange 3).filterMap fun t =>
    ((List.finRange 2).find? fun v => (s.promiseGot : Std.ExtTreeSet (Th × Fin 2)).contains (t, v)).map (·.val)
  let lazyErrs := ((List.finRange 3).filter fun t =>
    (s.lazyGot : Std.ExtTreeMap Th res_t_IndT).getD t .nothing == .err).length
  s!"delay runs={s.runs} got={got.mergeSort (fun a b => decide (a ≤ b))}|promise={pv.eraseDups}|lazy calls={s.lazyCalls} errors={lazyErrs}"

def onceOutcomes (b : body_t_IndT) : List String :=
  outcomes (sys b).initStates (fun s => ((sys b).tr (theory b) s).successes.map (·.2)) reprStr obs

#eval onceOutcomes .returns
#eval onceOutcomes .throws

end Once.Outcomes
