import JankSpecs.Tutorial.TinyAtom

/-!
# `TinyAtom`, callable from jank

The executable `TinyAtom` model (`Tutorial/TinyAtom.lean`, two threads),
exported as C functions on strings for `lean-sys` (`specs/native/`).

A trace is the labels of its steps, separated by `;`, as `"load 0;cas 0"`.
`jank_specs_tiny_atom_enabled` replays it and returns the labels of the steps
enabled after it; `jank_specs_tiny_atom_state` returns the state after it, as an
EDN map. Either returns `error: ...` if a step isn't enabled.

Built as a shared library with `lake build +JankSpecs.Native.TinyAtom:dynlib`.
-/

namespace TinyAtom.Native

open TinyAtom

abbrev Th := Fin 2
abbrev L := Label Th pc_t_IndT
abbrev St := State (FieldConcreteType Th pc_t_IndT)

def theory : Theory Th pc_t_IndT := {}

def sys :=
  letI : Veil.LogSwitch := ⟨false⟩
  enumerableTransitionSystem Th pc_t_IndT theory

def labelName : L → String
  | .load t => s!"load {t.val}"
  | .cas t => s!"cas {t.val}"

def pcName : pc_t_IndT → String
  | .idle => ":idle"
  | .loaded => ":loaded"
  | .done => ":done"

def next (s : St) : List (L × St) :=
  (sys.tr theory s).successes

/-- The state after the steps, or why a step can't be taken. -/
def replay (steps : String) : Except String St := do
  let [s] := sys.initStates | throw "expected one initial state"
  ((steps.splitOn ";").filter (· ≠ "")).foldlM (init := s) fun s name =>
    match (next s).find? (labelName ·.1 == name) with
    | some (_, s') => pure s'
    | none => throw s!"{name} isn't enabled"

/-- The state as an EDN map. -/
def describe (s : St) : String :=
  let threads := List.finRange 2
  let pc := threads.map fun t => pcName ((s.pc : Std.ExtTreeMap Th pc_t_IndT).getD t .idle)
  let seen := threads.map fun t => toString ((s.seen : Std.ExtTreeMap Th Nat).getD t 0)
  s!"\{:value {s.value} :swaps {s.swaps} :max-returned {s.maxReturned} :stale {s.stale} " ++
    s!":pc [{" ".intercalate pc}] :seen [{" ".intercalate seen}]}"

@[export jank_specs_tiny_atom_enabled]
def enabled (steps : String) : String :=
  match replay steps with
  | .ok s => ";".intercalate ((next s).map (labelName ·.1))
  | .error e => s!"error: {e}"

@[export jank_specs_tiny_atom_state]
def state (steps : String) : String :=
  match replay steps with
  | .ok s => describe s
  | .error e => s!"error: {e}"

-- The trace of `tutorial.jank`, replayed here.
#eval (enabled "", state "load 1;load 0;cas 1;cas 0", enabled "load 1;load 0;cas 1;cas 0")

end TinyAtom.Native
