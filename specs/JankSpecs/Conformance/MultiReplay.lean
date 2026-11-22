import JankSpecs.Blind.Multi
import Std.Data.HashSet

/-!
# Replaying multimethod programs through the model

`jank-specs.conformance.multi` runs random programs of `derive`, `defmethod`,
`prefer-method` and calls on jank (and on Clojure). `checkProgram` follows a
program through the model: setup steps are actions; for each call it explores
every order of the method table (`visit`) to the call's end, and jank's result
must be one of those ends. Dispatch values are `Fin 5`; 4 is `:default`.

A call's result: `method k` (the method of `k`), `default` (the `:default`
method), `none` (no method), `ambiguous` ("multiple methods").
-/

namespace Multi.Replay

open Multi

abbrev D := Fin 5
abbrev L := Label D phase_t_IndT res_t_IndT fix_t_IndT
abbrev St := State (FieldConcreteType D phase_t_IndT res_t_IndT fix_t_IndT)

/-- The theory with the proposed fixes `fixes` (none: jank as it is). -/
def thyWith (fixes : List fix_t_IndT) : Theory D phase_t_IndT res_t_IndT fix_t_IndT :=
  { defaultVal := 4, maxSetups := 16, maxPrefs := 8, focus := 0,
    fixed := fun f => decide (f ∈ fixes) }

def thy := thyWith []

def sysWith (fixes : List fix_t_IndT) :=
  letI : Veil.LogSwitch := ⟨false⟩
  enumerableTransitionSystem D phase_t_IndT res_t_IndT fix_t_IndT (thyWith fixes)

def sys := sysWith []

def d (n : Nat) : D := Fin.ofNat 5 n

/-- jank's result, as the harness prints it (a method returns its own
dispatch value; the `:default` one returns 4). -/
def resOf (s : St) : String :=
  match s.res with
  | .method => if s.resKey.val == 4 then "default" else s!"method {s.resKey.val}"
  | .defaultMethod => "default"
  | .noMethod => "none"
  | .ambiguous => "ambiguous"

/-- Clojure's result, by the model's copy of `MultiFn`'s loop. -/
def resOfC (s : St) : String :=
  match s.resC with
  | .method => if s.resKeyC.val == 4 then "default" else s!"method {s.resKeyC.val}"
  | .defaultMethod => "default"
  | .noMethod => "none"
  | .ambiguous => "ambiguous"

inductive Step where
  | derive (x y : Nat)
  | defmethod (k : Nat)
  | prefer (x y : Nat)
  /-- A call, with what jank returned and what Clojure returned. -/
  | call (v : Nat) (jank clojure : String)

def apply1 (l : L) (cur : List St) (fixes : List fix_t_IndT := []) : List St :=
  cur.flatMap fun s =>
    (((sysWith fixes).tr (thyWith fixes) s).successes.filter fun (l', _) =>
      reprStr l' == reprStr l).map (·.2)

/-- Every end of the call in progress, over all orders. -/
partial def ends (todo : List St) (seen : Std.HashSet String) (acc : List St)
    (fixes : List fix_t_IndT := []) : List St :=
  match todo with
  | [] => acc
  | s :: rest =>
    let k := reprStr s
    if seen.contains k then ends rest seen acc fixes
    else if s.phase == .done then ends rest (seen.insert k) (s :: acc) fixes
    else ends ((((sysWith fixes).tr (thyWith fixes) s).successes.map (·.2)) ++ rest)
      (seen.insert k) acc fixes

def replay (steps : List Step) (fixes : List fix_t_IndT := []) : Except String (List String) := do
  let mut cur : List St := (sysWith fixes).initStates
  let mut i := 0
  let mut notes : List String := []
  for st in steps do
    match st with
    | .derive x y => cur := apply1 (.derive (d x) (d y)) cur fixes
    | .defmethod k => cur := apply1 (.defmethod (d k)) cur fixes
    | .prefer x y => cur := apply1 (.preferMethod (d x) (d y)) cur fixes
    | .call v jank clojure =>
      let done := ends (apply1 (.call (d v)) cur fixes) {} [] fixes
      let allowed := (done.map resOf).eraseDups
      let allowedC := (done.map resOfC).eraseDups
      let ok := done.filter fun s => resOf s == jank
      if ok.isEmpty then
        throw s!"step {i}: call of {v}: jank gave {jank}, the model allows {allowed}"
      unless allowedC.contains clojure do
        notes := notes ++ [s!"step {i}: call of {v}: Clojure gave {clojure}, the model's copy of Clojure's loop allows {allowedC}"]
      if jank != clojure then
        notes := notes ++ [s!"step {i}: call of {v}: jank {jank}, Clojure {clojure}"]
      cur := apply1 .next ok fixes
    if cur.isEmpty then
      throw s!"step {i}: the model doesn't allow this step"
    i := i + 1
  return notes

/-- Fails unless jank's results are allowed by the model; prints where jank
and Clojure differ, and any Clojure result the model's copy of its loop
doesn't allow. -/
def checkProgram (name : String) (steps : List Step) : IO Unit :=
  match replay steps with
  | .ok [] => IO.println s!"{name}: conforms"
  | .ok notes => IO.println s!"{name}: conforms; {"; ".intercalate notes}"
  | .error e => throw <| IO.userError s!"{name}: {e}"

-- The model checker's counterexample for `mm1_dispatch` with a preference:
-- jank throws in every order, Clojure returns 0's method.
#eval checkProgram "mm1-preference" [
  .derive 3 2, .defmethod 0, .derive 2 1, .defmethod 2, .derive 3 0, .prefer 0 1,
  .call 3 "ambiguous" "method 0"]

-- A wrong result is rejected.
#eval show IO Unit from do
  match replay [.defmethod 0, .call 0 "none" "method 0"] with
  | .ok _ => throw <| IO.userError "a wrong result was accepted"
  | .error _ => pure ()

end Multi.Replay
