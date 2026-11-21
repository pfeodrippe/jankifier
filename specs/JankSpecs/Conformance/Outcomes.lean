import Std.Data.HashSet

/-!
# Outcome sets

For concurrent programs a run's interleaving can't be observed, only its
outcome. `outcomes` explores every run of a model instance to its end (states
without successors) and collects what each end state shows; a conformance check
then asserts that every outcome jank showed is one of them, and reports which of
them jank showed.
-/

namespace JankSpecs.Outcomes

/-- The observations of the end states reachable from `init` through `next`,
identifying states by `key`. -/
partial def outcomes {σ : Type} (init : List σ) (next : σ → List σ) (key : σ → String)
    (obs : σ → String) : List String := Id.run do
  let mut seen : Std.HashSet String := {}
  let mut todo := init
  let mut out : Std.HashSet String := {}
  repeat
    let s :: rest := todo | break
    todo := rest
    let k := key s
    if seen.contains k then continue
    seen := seen.insert k
    let succ := next s
    if succ.isEmpty then
      out := out.insert (obs s)
    else
      todo := succ ++ todo
  return out.toList.mergeSort (· ≤ ·)

/-- Fails unless every observed outcome is one the model allows; prints how
many of the model's outcomes were observed. -/
def check (name : String) (allowed observed : List String) : IO Unit := do
  let bad := observed.filter (!allowed.contains ·)
  unless bad.isEmpty do
    throw <| IO.userError s!"{name}: jank showed {bad}, which the model doesn't allow; it allows {allowed}"
  let seen := allowed.filter (observed.contains ·)
  IO.println s!"{name}: conforms ({observed.length} distinct outcomes observed, {seen.length} of the model's {allowed.length})"

end JankSpecs.Outcomes
