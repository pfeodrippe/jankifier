import JankSpecs.ModuleCache

/-!
# Replaying jank's behaviour through the module cache model

`conformance/module_cache/run.py` runs scenarios on the real jank and writes
what it observed as traces of `ModuleCache`'s actions, each step with what jank
showed. `checkTrace` follows a trace through every state the model can be in,
keeping the successors whose action and observation match; the trace conforms
if that never runs out.

The instance is the model checking one: `lib` (0) and `app` (1, requires
`lib`), directories `a` (0), `b` (1) and the build directory (2), two
processes.
-/

namespace ModuleCache.Replay

open ModuleCache

abbrev Mod := Fin 2
abbrev Dir := Fin 3
abbrev Proc := Fin 2
abbrev L := Label Mod Dir Proc mode_t_IndT outcome_IndT
abbrev St := State (FieldConcreteType Mod Dir Proc mode_t_IndT outcome_IndT)

def theory : Theory Mod Dir Proc mode_t_IndT outcome_IndT :=
  ⟨fun m d => decide (m = 1 ∧ d = 0), 2, 0⟩

def sys :=
  letI : Veil.LogSwitch := ⟨false⟩
  enumerableTransitionSystem Mod Dir Proc mode_t_IndT outcome_IndT theory

/-- What a step shows: nothing (file and process actions), a module's `LOAD`
line (the directory and version of its source, whether it was compiled ahead
of time, and the version of `lib`'s macro it saw, 0 for `lib` itself), or a
load error. -/
inductive Obs where
  | none
  | loaded (dir : Dir) (ver : Nat) (aot : Bool) (libVer : Nat)
  | failed (o : outcome_IndT)
  deriving Repr

def libVerSeen (s : St) : Nat :=
  (s.lastDepVer : Std.ExtTreeMap Mod Nat).getD 0 0

def obsOf (s : St) : Obs :=
  if s.lastOutcome == .fromSrc || s.lastOutcome == .fromObj then
    .loaded s.lastDir s.lastVer s.lastAot (libVerSeen s)
  else .failed s.lastOutcome

def obsOk : Obs → St → Bool
  | .none, _ => true
  | o, s => reprStr (obsOf s) == reprStr o

def replay (steps : List (L × Obs)) : Except String Unit := do
  let mut current : List St := sys.initStates
  let mut i := 0
  for (l, o) in steps do
    let moves := current.flatMap fun s =>
      (sys.tr theory s).successes.filter fun (l', _) => reprStr l' == reprStr l
    if moves.isEmpty then
      throw s!"step {i}: the model doesn't allow {reprStr l} here"
    let next := moves.filterMap fun (_, s') => if obsOk o s' then some s' else none
    if next.isEmpty then
      let allowed := (moves.map fun (_, s') => reprStr (obsOf s')).eraseDups
      throw s!"step {i}: {reprStr l} showed {reprStr o}, the model allows {allowed}"
    current := next
    i := i + 1

def checkTrace (name : String) (steps : List (L × Obs)) : IO Unit :=
  match replay steps with
  | .ok () => IO.println s!"{name}: conforms ({steps.length} steps)"
  | .error e => throw <| IO.userError s!"{name}: {e}"

-- A trace from the experiments in `PLAN.md`: compile, edit `lib`, run.
#eval checkTrace "plan-experiment" [
  (.editSrc 0 0, .none), (.editSrc 0 1, .none),
  (.startCompile 0, .none), (.load 0 0, .loaded 0 1 true 0), (.load 0 1, .loaded 0 2 true 1),
  (.stop 0, .none),
  (.editSrc 0 0, .none),
  (.startRun 1, .none), (.load 1 0, .loaded 0 3 false 0), (.load 1 1, .loaded 0 2 true 1)]

-- A wrong observation is rejected.
#eval show IO Unit from do
  match replay [(.editSrc 0 0, .none), (.startRun 0, .none), (.load 0 0, .loaded 0 1 true 0)] with
  | .ok () => throw <| IO.userError "a wrong observation was accepted"
  | .error _ => pure ()

end ModuleCache.Replay
