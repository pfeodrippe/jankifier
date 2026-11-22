import JankSpecs.Blind.Transients

/-!
# What the transient model predicts after `persistent!`

For each kind and operation, the model's prediction for the operation on a
transient after `persistent!`: `threw` or `returned`.
`jank-specs.conformance.transients` runs the same on jank, and compares
with `predict`.
-/

namespace Transients.Check

open Transients

abbrev Tr := Fin 6

def kinds : List kind_t_IndT := [.vector, .arrayMap, .hashMap, .hashSet, .sortedMap, .sortedSet]

def supportedT : kind_t_IndT → op_t_IndT → Bool
  | .vector, .disjOp | .vector, .callFallbackOp => false
  | .vector, _ => true
  | .hashSet, .assocOp | .hashSet, .dissocOp | .hashSet, .popOp | .hashSet, .nthOp
  | .hashSet, .nthFallbackOp | .hashSet, .findOp => false
  | .sortedSet, .assocOp | .sortedSet, .dissocOp | .sortedSet, .popOp | .sortedSet, .nthOp
  | .sortedSet, .nthFallbackOp | .sortedSet, .findOp => false
  | .hashSet, _ | .sortedSet, _ => true
  | _, .disjOp | _, .popOp | _, .nthOp | _, .nthFallbackOp => false
  | _, _ => true

def checksT : kind_t_IndT → op_t_IndT → Bool
  | .vector, .nthOp | .vector, .findOp | .vector, .containsOp => false
  | .arrayMap, .getFallbackOp | .arrayMap, .findOp | .arrayMap, .containsOp
  | .arrayMap, .callFallbackOp => false
  | _, _ => true

/-- The theory with the proposed fixes `fixes` (none: jank as it is). -/
def thyWith (fixes : List fix_t_IndT) : Theory Tr kind_t_IndT op_t_IndT out_t_IndT fix_t_IndT :=
  { kindOf := fun t => kinds.getD t.val .vector, supported := supportedT, checks := checksT, focus := 0,
    fixed := fun f => decide (f ∈ fixes) }

def thy := thyWith []

def sysWith (fixes : List fix_t_IndT) :=
  letI : Veil.LogSwitch := ⟨false⟩
  enumerableTransitionSystem Tr kind_t_IndT op_t_IndT out_t_IndT fix_t_IndT (thyWith fixes)

def sys := sysWith []

abbrev L := Label Tr kind_t_IndT op_t_IndT out_t_IndT fix_t_IndT

def step (l : L) (cur : List (State (FieldConcreteType Tr kind_t_IndT op_t_IndT out_t_IndT fix_t_IndT)))
    (fixes : List fix_t_IndT := []) :=
  cur.flatMap fun s => (((sysWith fixes).tr (thyWith fixes) s).successes.filter fun (l', _) =>
    reprStr l' == reprStr l).map (·.2)

/-- The model's prediction for `o` on a transient of kind number `k`, after
`persistent!`. -/
def predict (k : Nat) (o : op_t_IndT) (fixes : List fix_t_IndT := []) : String :=
  let t : Tr := Fin.ofNat 6 k
  match step (.apply t o) (step (.apply t .persistentOp) (sysWith fixes).initStates fixes) fixes with
  | [s] => if s.lastOut == .threw then "threw" else "returned"
  | _ => "not supported"

/-- Fails unless jank did what the model predicts for each (kind, operation). -/
def checkTable (observed : List (Nat × op_t_IndT × String)) : IO Unit := do
  let bad := observed.filter fun (k, o, r) => predict k o != r
  unless bad.isEmpty do
    throw <| IO.userError s!"jank differs from the model: {bad.map fun (k, o, r) => (k, reprStr o, r, predict k o)}"
  let unchecked := observed.filter fun (_, _, r) => r == "returned"
  IO.println s!"after persistent!: conforms ({observed.length} operations; {unchecked.length} returned instead of throwing)"

#eval (predict 0 .nthOp, predict 0 .getOp, predict 1 .containsOp, predict 2 .containsOp)

end Transients.Check
