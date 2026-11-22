import JankSpecs.Blind.ArrayMap

/-!
# Replaying array map programs through the storage model

`jank-specs.conformance.arraymap` runs random programs of `{}`, `assoc`,
`dissoc`, `transient`, `assoc!`, `dissoc!` and `persistent!` on jank, then
prints every persistent map, entry by entry in the order jank stores them.
`replay` runs the same program through `ArrayMap` and requires the model to
print exactly the same (the model is deterministic, given which new
array each step takes; the harness picks the lowest unused one, as here).

Objects are `Fin 8`, arrays `Fin 12`, keys and values `Fin 2`, three slots.
-/

namespace ArrayMap.Replay

open ArrayMap

abbrev O := Fin 8
abbrev B := Fin 12
abbrev K := Fin 2
abbrev V := Fin 2
abbrev S := Fin 3
abbrev L := Label O B K V S fix_t_IndT
abbrev St := State (FieldConcreteType O B K V S fix_t_IndT)

/-- The theory with the proposed fixes `fixes` (none: jank as it is). -/
def thyWith (fixes : List fix_t_IndT) : Theory O B K V S fix_t_IndT :=
  { slotIdx := fun s => s.val, slotNext := fun s => s + 1, maxCap := 3,
    allowTransients := true, focus := 0, buf0 := 0, key0 := 0, val0 := 0,
    fixed := fun f => decide (f ∈ fixes) }

def thy := thyWith []

def sysWith (fixes : List fix_t_IndT) :=
  letI : Veil.LogSwitch := ⟨false⟩
  enumerableTransitionSystem O B K V S fix_t_IndT (thyWith fixes)

def sys := sysWith []

def step (l : L) (cur : List St) (fixes : List fix_t_IndT := []) : List St :=
  cur.flatMap fun s =>
    (((sysWith fixes).tr (thyWith fixes) s).successes.filter fun (l', _) =>
      reprStr l' == reprStr l).map (·.2)

/-- An object's entries, in slot order, as `[k v]` pairs. -/
def entries (s : St) (o : O) : String :=
  let b := (s.bufOf : Std.ExtTreeMap O B).getD o 0
  let n := (s.len : Std.ExtTreeMap O Nat).getD o 0
  let slots := (List.finRange 3).filter (·.val < n)
  let cell (sl : S) :=
    s!"[{((s.cellKey : Std.ExtTreeMap (B × S) K).getD (b, sl) 0).val} {((s.cellVal : Std.ExtTreeMap (B × S) V).getD (b, sl) 0).val}]"
  "[" ++ " ".intercalate (slots.map cell) ++ "]"

/-- Whether the model prints what jank printed, for each persistent object, after the steps
`labels`: why not, if it doesn't. -/
def replay (labels : List L) (printed : List (Nat × String)) (fixes : List fix_t_IndT := []) :
    Except String Unit := do
  let mut cur := (sysWith fixes).initStates
  let mut i := 0
  for l in labels do
    let next := step l cur fixes
    if next.isEmpty then
      throw s!"step {i} ({reprStr l}) isn't allowed by the model"
    cur := next
    i := i + 1
  let [s] := cur | throw s!"{cur.length} model states"
  let bad := printed.filter fun (o, p) => entries s (Fin.ofNat 8 o) != p
  unless bad.isEmpty do
    throw s!"{bad.map fun (o, p) => s!"object {o}: jank {p}, model {entries s (Fin.ofNat 8 o)}"}"

/-- Fails unless the model prints what jank printed, for each persistent
object. -/
def checkProgram (name : String) (labels : List L) (printed : List (Nat × String)) : IO Unit :=
  match replay labels printed with
  | .ok () => IO.println s!"{name}: conforms ({labels.length} steps, {printed.length} maps)"
  | .error e => throw <| IO.userError s!"{name}: {e}"

-- `{}`, assoc k0, transient, assoc! of k0 in place: the source changes.
#eval checkProgram "source-changes"
  [.newEmpty 0 0, .pAssoc 0 0 0 1 1, .toTransient 1 2, .tAssoc 2 0 1 2, .persistentT 2 3]
  [(1, "[[0 1]]"), (3, "[[0 1]]")]

end ArrayMap.Replay
