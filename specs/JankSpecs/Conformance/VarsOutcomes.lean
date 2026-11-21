import JankSpecs.Blind.Vars
import JankSpecs.Blind.Require
import JankSpecs.Conformance.Outcomes

/-!
# The vars and `require` models' outcomes

For the programs `conformance/blind/vars.py` runs on jank, every outcome the
models allow, from every run to its end:

- three futures `(alter-var-root #'x inc)` from 0: the root;
- two futures `(with-redefs [y 50] ...)` of a var whose root is 3: the root
  afterwards;
- two futures `(defonce d (do (swap! evals inc) 7))`: how many times the
  expression ran, and the root;
- one `(alter-var-root #'z (fn [v] (alter-var-root #'z inc) (inc v)))`:
  whether it returns;
- two futures `(require 'lib)` at once: how many times the lib's body ran.
-/

namespace Vars.Outcomes

open JankSpecs.Outcomes

def varsTheory (n : Nat) (p : Vars.prog_t_IndT) (root : Nat) (bound : Bool) :
    Vars.Theory (Fin n) Vars.prog_t_IndT Vars.pc_t_IndT :=
  { prog := fun _ => p, initRoot := root, initBound := bound, focus := 0 }

def varsOutcomes (n : Nat) [NeZero n] (p : Vars.prog_t_IndT) (root : Nat) (bound : Bool)
    (obs : Vars.State (Vars.FieldConcreteType (Fin n) Vars.prog_t_IndT Vars.pc_t_IndT) → String) :
    List String :=
  let th := varsTheory n p root bound
  let sys :=
    letI : Veil.LogSwitch := ⟨false⟩
    Vars.enumerableTransitionSystem (Fin n) Vars.prog_t_IndT Vars.pc_t_IndT th
  outcomes sys.initStates (fun s => (sys.tr th s).successes.map (·.2)) reprStr obs

def stuck {n : Nat} (s : Vars.State (Vars.FieldConcreteType (Fin n) Vars.prog_t_IndT Vars.pc_t_IndT)) :
    Bool :=
  (s.pc : Std.ExtTreeMap (Fin n) Vars.pc_t_IndT).toList.any (·.2 == .stuck)

def alterOutcomes := varsOutcomes 3 .alter 0 true fun s => s!"root={s.root}"
def redefsOutcomes := varsOutcomes 2 .redefs 3 true fun s => s!"root={s.root}"
def defonceOutcomes := varsOutcomes 2 .defonce 0 false fun s => s!"evals={s.evals} root={s.root}"
def nestedOutcomes := varsOutcomes 1 .alterNested 0 true fun s =>
  if stuck s then "stuck" else s!"returned root={s.root}"

end Vars.Outcomes

namespace Require.Outcomes

open Require JankSpecs.Outcomes

def requireOutcomes : List String :=
  let th : Theory (Fin 2) pc_t_IndT := { forms := 4, focus := 0 }
  let sys :=
    letI : Veil.LogSwitch := ⟨false⟩
    enumerableTransitionSystem (Fin 2) pc_t_IndT th
  outcomes sys.initStates (fun s => (sys.tr th s).successes.map (·.2)) reprStr
    fun s => s!"runs={s.runs}"

end Require.Outcomes

open Vars.Outcomes Require.Outcomes in
#eval (alterOutcomes, redefsOutcomes, defonceOutcomes, nestedOutcomes, requireOutcomes)
