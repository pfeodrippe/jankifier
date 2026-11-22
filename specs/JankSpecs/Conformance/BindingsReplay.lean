import JankSpecs.Concurrency.Bindings

/-!
# Replaying jank's behaviour through the bindings model

`jank-specs.conformance.bindings` (src/jank_specs/conformance/) runs generated
jank programs and passes what they did to `replay`, as traces of `Bindings`'
actions; `replay` follows each trace through every state the model can be in.

The instance: thread 0 is the main thread, 1..7 are futures; OS thread ids
0..5, with 0 the main thread's (real ids are numbered in the order the program
sees them); values 0 (`*x*`'s root), 1 and 2.
-/

namespace Bindings.Replay

open Bindings

abbrev Th := Fin 8
abbrev Tid := Fin 6
abbrev Val := Fin 3
abbrev L := Label Th Tid Val fix_t_IndT
abbrev St := State (FieldConcreteType Th Tid Val fix_t_IndT)

/-- The theory with the proposed fixes `fixes` (none: jank as it is). -/
def thyWith (fixes : List fix_t_IndT) : Theory Th Tid Val fix_t_IndT :=
  ⟨0, 0, 0, 0, fun f => decide (f ∈ fixes)⟩

def thy := thyWith []

def sysWith (fixes : List fix_t_IndT) :=
  letI : Veil.LogSwitch := ⟨false⟩
  enumerableTransitionSystem Th Tid Val fix_t_IndT (thyWith fixes)

def sys := sysWith []

/-- What a step shows: nothing, what a deref returned (`none`: `nil`), or that
it threw (with the fix `c8`). -/
inductive Obs where
  | none
  | deref (v : Option Val)
  | threw
  deriving Repr

def obsOk : Obs → St → Bool
  | .none, _ => true
  | .deref v, s => s.lastDeref == v && !s.lastDerefThrew
  | .threw, s => s.lastDerefThrew

def replay (steps : List (L × Obs)) (fixes : List fix_t_IndT := []) : Except String Unit := do
  let mut current : List St := (sysWith fixes).initStates
  let mut i := 0
  for (l, o) in steps do
    let moves := current.flatMap fun s =>
      ((sysWith fixes).tr (thyWith fixes) s).successes.filter fun (l', _) => reprStr l' == reprStr l
    if moves.isEmpty then
      throw s!"step {i}: the model doesn't allow {reprStr l} here"
    let next := moves.filterMap fun (_, s') => if obsOk o s' then some s' else none
    if next.isEmpty then
      let allowed := (moves.map fun (_, s') => reprStr s'.lastDeref).eraseDups
      throw s!"step {i}: {reprStr l} showed {reprStr o}, the model allows {allowed}"
    current := next
    i := i + 1

def checkTrace (name : String) (steps : List (L × Obs)) : IO Unit :=
  match replay steps with
  | .ok () => IO.println s!"{name}: conforms ({steps.length} steps)"
  | .error e => throw <| IO.userError s!"{name}: {e}"

-- The experiment in `PLAN.md`: a future in a binding, joined, then one
-- outside it, on the same OS thread id, sees the binding.
#eval checkTrace "plan-experiment" [
  (.push 1, .none), (.spawn 1 1, .none), (.pop, .none),
  (.finish 1, .none), (.deref 1, .deref (some 1)),
  (.spawn 2 1, .none), (.finish 2, .none), (.deref 2, .deref (some 1))]

-- A wrong observation is rejected.
#eval show IO Unit from do
  match replay [(.spawn 1 1, .none), (.finish 1, .none), (.deref 1, .deref (some 1))] with
  | .ok () => throw <| IO.userError "a wrong observation was accepted"
  | .error _ => pure ()

end Bindings.Replay
