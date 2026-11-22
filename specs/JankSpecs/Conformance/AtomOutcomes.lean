import JankSpecs.Concurrency.Atom
import JankSpecs.Conformance.Outcomes

/-!
# The atom model's outcomes

For the programs the atom conformance check ran on jank (now
`jank-specs.conformance/check-atoms`, which explores the model in process),
every outcome the model allows: the final value and the watch's calls, oldest first, as
`value|old>new,old>new,...`, and for `compare-and-set!`, whether it succeeded.
-/

namespace Atom.Outcomes

open Atom JankSpecs.Outcomes

abbrev Slot := Fin 6

def theory2 : Theory (Fin 2) Slot pc_t_IndT fix_t_IndT :=
  { swaps := fun _ => 2, casAfter := fun _ => false, resetAfter := fun _ => false,
    resetTo := fun _ => 0, focus := 0, firstSlot := 0, slotAfter := fun i => i + 1,
    fixed := fun _ => false }
def theory1 : Theory (Fin 1) Slot pc_t_IndT fix_t_IndT :=
  { swaps := fun _ => 1, casAfter := fun _ => true, resetAfter := fun _ => false,
    resetTo := fun _ => 0, focus := 0, firstSlot := 0, slotAfter := fun i => i + 1,
    fixed := fun _ => false }

def sys2 :=
  letI : Veil.LogSwitch := ⟨false⟩
  enumerableTransitionSystem (Fin 2) Slot pc_t_IndT fix_t_IndT theory2

def sys1 :=
  letI : Veil.LogSwitch := ⟨false⟩
  enumerableTransitionSystem (Fin 1) Slot pc_t_IndT fix_t_IndT theory1

/-- The watch's calls, oldest first: the slots before `nextSlot`. -/
def showLog (s : State (FieldConcreteType (Fin 2) Slot pc_t_IndT fix_t_IndT)) : String :=
  let used := (List.finRange 6).filter (· < s.nextSlot)
  ",".intercalate (used.map fun i =>
    s!"{(s.watchOld : Std.ExtTreeMap Slot Nat).getD i 0}>{(s.watchNew : Std.ExtTreeMap Slot Nat).getD i 0}")

/-- Two threads with two `swap!`s each: the final value and the watch's
calls. -/
def swapOutcomes : List String :=
  outcomes sys2.initStates (fun s => (sys2.tr theory2 s).successes.map (·.2))
    reprStr (fun s => s!"{s.value}|{showLog s}")

/-- One thread: `swap!` then `compare-and-set!`: whether it succeeded. -/
def casOutcomes : List String :=
  outcomes sys1.initStates (fun s => (sys1.tr theory1 s).successes.map (·.2))
    reprStr (fun s => s!"cas={s.value == 11}")

#eval swapOutcomes
#eval casOutcomes

end Atom.Outcomes
