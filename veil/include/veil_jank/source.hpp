#pragma once

/* Lean code that veil.core elaborates into its sessions: Veil's model checker, executable
 * systems and invariant checks, called as Lean functions so that their results are Lean values
 * (`ModelCheckingResult`, the model's states, `VerificationResults`), which lean-sys reads as
 * jank data. Built from Veil's public API, as Veil's own commands build them
 * (Veil/Frontend/DSL/Module/Elaborators/Core.lean). */

namespace veil_jank
{
  inline constexpr char const *lean_source = R"lean(
namespace JankVeil
open Lean Elab Term Meta Command

def executableModule (m : Ident) : TermElabM Veil.ExecutableModule := do
  let some em ← Veil.getExecutableModule? m.getId
    | throwErrorAt m "{m.getId} has no executable definitions: add #gen_executable to it"
  return em

/-- The arguments of the module's definitions that the instantiation sets, read from
`veilInst`. -/
def instArgs (em : Veil.ExecutableModule) : Array Ident :=
  em.instantiationFields.map fun f => mkIdent (`veilInst ++ f)

def inModule (em : Veil.ExecutableModule) (n : Name) : Ident :=
  mkIdent (em.name ++ n)

/-- `x` with the module's namespace as the current one, so that the names in an instantiation
or a theory resolve in it first, whatever module is open in the session. -/
def inModuleNamespace (em : Veil.ExecutableModule) (x : TermElabM α) : TermElabM α :=
  withTheReader Core.Context (fun ctx => { ctx with currNamespace := em.name }) x

/-- The states of `sys` reachable from its initial states (all of them, or those with no
successor, where a run ends), searched breadth first. -/
def reachableStates {ρ σ κ : Type} [BEq σ] [Hashable σ] [Inhabited σ] {th : ρ}
    (sys : Veil.EnumerableTransitionSystem ρ (List ρ) σ (List σ) Int κ (Veil.Transitions κ Int σ) th)
    (thv : ρ) (terminalOnly : Bool) : Array σ := Id.run do
  let mut seen : Std.HashSet σ := {}
  let mut todo := sys.initStates.toArray
  let mut result := #[]
  while todo.size > 0 do
    let s := todo.back!
    todo := todo.pop
    if seen.contains s then continue
    seen := seen.insert s
    let nexts := ((sys.tr thv s).successes.map (·.2)).toArray
    if !terminalOnly || nexts.isEmpty then
      result := result.push s
    todo := todo ++ nexts
  return result

/-- `veil_system% M inst th`: module `M`'s executable transition system for instantiation `inst`
and theory `th`. -/
syntax (name := system) "veil_system% " ident ppSpace term:max ppSpace term:max : term

@[term_elab system] def elabSystem : TermElab := fun stx expected? => do
  let `(veil_system% $m:ident $inst $th) := stx | throwUnsupportedSyntax
  let em ← executableModule m
  let args := instArgs em
  inModuleNamespace em <| elabTerm (← `(open Veil $(mkIdent em.name):ident in
                let $(mkIdent `veilInst) := __veil_instantiation_of% $m $inst
                letI : Veil.LogSwitch := ⟨false⟩
                $(inModule em `enumerableTransitionSystem) $args*
                  ($th : $(inModule em `Theory) $args*))) expected?

/-- Whether each of `props` holds in state `st`, by name. `_init`, the system's initial states,
gives the type of the states. -/
def checks {ρ σ : Type} (th : ρ) (_init : List σ) (props : List (Veil.ModelChecker.SafetyProperty ρ σ))
    (st : σ) : List (String × Bool) :=
  props.map fun p => (p.name.toString, p.holdsOn th st)

def safetyProperty (em : Veil.ExecutableModule) (n : Name) : TermElabM Term :=
  `(Veil.ModelChecker.SafetyProperty.mk (name := $(quote n))
      (property := fun th st => $(inModule em n) th st))

/-- `veil_properties% M inst th`: a function from a state of the system to whether each of
`M`'s invariants and safety properties holds in it, by name. -/
syntax (name := properties) "veil_properties% " ident ppSpace term:max ppSpace term:max : term

@[term_elab properties] def elabProperties : TermElab := fun stx expected? => do
  let `(veil_properties% $m:ident $inst $th) := stx | throwUnsupportedSyntax
  let em ← executableModule m
  let args := instArgs em
  let props ← em.invariants.mapM (safetyProperty em)
  inModuleNamespace em <| elabTerm (← `(open Veil $(mkIdent em.name):ident in
                veil_dsimp_field_reads% (
                  let $(mkIdent `veilInst) := __veil_instantiation_of% $m $inst
                  let $(mkIdent `veilTh) : $(inModule em `Theory) $args* := $th
                  JankVeil.checks $(mkIdent `veilTh)
                    (letI : Veil.LogSwitch := ⟨false⟩
                     ($(inModule em `enumerableTransitionSystem) $args* $(mkIdent `veilTh)).initStates)
                    [$props,*]))) expected?

/-- `#model_check`'s search parameters for `em`: its assumptions, invariants (when `safety`),
termination property and state constraints, stopping at the first violation, or at depth `depth`
when it isn't 0. -/
def searchParams (em : Veil.ExecutableModule) (depth : Nat) (safety : Bool := true) :
    TermElabM Term := do
  let prop := safetyProperty em
  let assumption (n : Name) : TermElabM Term :=
    `(Veil.ModelChecker.TheoryProperty.mk (name := $(quote n))
        (property := fun th => $(inModule em n) th))
  let assumptions ← em.assumptions.mapM assumption
  let invariants ← if safety then em.invariants.mapM prop else pure #[]
  let terminating ← match (if safety then em.terminations[0]? else none) with
    | some t => prop t
    | none => `(default)
  let constraints ← em.stateConstraints.mapM prop
  let bound : Term := ⟨Syntax.mkNumLit (toString depth)⟩
  let early ← if depth > 0 then
      `([.foundViolatingState, .assertionFailed, .deadlockOccurred, .reachedDepthBound $bound])
    else
      `([.foundViolatingState, .assertionFailed, .deadlockOccurred])
  `(({ assumptions := [$assumptions,*], invariants := [$invariants,*],
       terminating := $terminating, stateConstraints := [$constraints,*],
       earlyTerminationConditions := $early } : Veil.ModelChecker.SearchParameters _ _))

/-- `body` with `veilInst` (the instantiation `inst` of module `m`) and `veilTh` (theory `th`)
bound, and the module's scoped instances open, as Veil's commands elaborate their calls. -/
def withExecution (em : Veil.ExecutableModule) (m : Ident) (inst th body : Term) :
    TermElabM Term :=
  `(open Veil $(mkIdent em.name):ident in
      veil_dsimp_field_reads% (
        let $(mkIdent `veilInst) := __veil_instantiation_of% $m $inst
        let $(mkIdent `veilTh) : $(inModule em `Theory) $(instArgs em)* := $th
        $body))

def systemTerm (em : Veil.ExecutableModule) : TermElabM Term :=
  `((letI : Veil.LogSwitch := ⟨false⟩
     $(inModule em `enumerableTransitionSystem) $(instArgs em)* $(mkIdent `veilTh)))

/-- `veil_find_reachable% M inst th depth tasks`: Veil's model checker on `M` (an `IO` action),
with its search parameters as `#model_check` builds them (`searchParams`), `Nat`
fingerprints, and `tasks` parallel sub-tasks (0: sequential). -/
syntax (name := findReachable) "veil_find_reachable% " ident ppSpace term:max ppSpace term:max
  ppSpace num ppSpace num : term

@[term_elab findReachable] def elabFindReachable : TermElab := fun stx expected? => do
  let `(veil_find_reachable% $m:ident $inst $th $depth:num $tasks:num) := stx
    | throwUnsupportedSyntax
  let em ← executableModule m
  let params ← searchParams em depth.getNat
  let parallel ← if tasks.getNat == 0 then `(none)
    else `(some { numSubTasks := $tasks, thresholdToParallel := 20 })
  let th' := mkIdent `veilTh
  let sys ← systemTerm em
  inModuleNamespace em <| elabTerm (← withExecution em m inst th (← `((do
      let tk ← IO.CancelToken.new
      Veil.ModelChecker.Concrete.findReachable (σₕ := Nat) (ShardOf := TreeMapShard Nat)
        $sys
        (fun _ => letI : Veil.LogSwitch := ⟨true⟩; $(inModule em `pickSource) $(instArgs em)* $th')
        $params $parallel 0 tk : IO _)))) expected?

/-- `veil_simulate% M inst th traces steps seed`: Veil's simulator on `M` (an `IO` action):
`traces` random runs of up to `steps` steps, checking the invariants in each state; a
`seed` of 0 picks one. -/
syntax (name := simulate) "veil_simulate% " ident ppSpace term:max ppSpace term:max
  ppSpace num ppSpace num ppSpace num : term

@[term_elab simulate] def elabSimulate : TermElab := fun stx expected? => do
  let `(veil_simulate% $m:ident $inst $th $traces:num $steps:num $seed:num) := stx
    | throwUnsupportedSyntax
  let em ← executableModule m
  let params ← searchParams em 0
  let sys ← systemTerm em
  inModuleNamespace em <| elabTerm (← withExecution em m inst th (← `((do
      let tk ← IO.CancelToken.new
      Veil.ModelChecker.Simulation.simulateWithProgress $sys $params
        $(mkIdent `veilTh) { numTraces := $traces, maxSteps := $steps, seed := $seed } 0 tk
        : IO _)))) expected?

/-- `veil_check_temporal% M inst th p route`: Veil's liveness model checker on `M`'s temporal
property `p` (its `p.ast`), on the system restricted by the state constraints, by `route`
(`fair`, `crossing`, `patOnly`, `prune` or `dijkstra`). A `Lasso.EmptinessResult` of states:
no run violates `p`, or a stem and a loop of states that do. -/
syntax (name := checkTemporal) "veil_check_temporal% " ident ppSpace term:max ppSpace term:max
  ppSpace ident ppSpace ident : term

@[term_elab checkTemporal] def elabCheckTemporal : TermElab := fun stx expected? => do
  let `(veil_check_temporal% $m:ident $inst $th $p:ident $route:ident) := stx
    | throwUnsupportedSyntax
  let em ← executableModule m
  let params ← searchParams em 0 (safety := false)
  let args := instArgs em
  let dispatcher ← `($(inModule em `FieldConcreteType) $args*)
  let property ← `($(inModule em (p.getId ++ `ast)) ($(inModule em `Theory) $args*)
      ($(inModule em `State) $dispatcher) $args* $dispatcher)
  let sys ← systemTerm em
  inModuleNamespace em <| elabTerm (← withExecution em m inst th (← `(
      Veil.LivenessMC.checkRoute $(mkIdent (`Veil.LivenessMC.Route ++ route.getId))
        (Veil.ModelChecker.restrictSystemByStateConstraints $sys $params
          $(mkIdent `veilTh))
        $property))) expected?

/-- A verification condition, as `checkInvariants` returns it: its status, the action and the
property it is about, the condition it is another formulation of (`_tr` conditions, tried when
that one isn't proven), and the first counterexample a solver found, as Veil shows it (the
pre-state, the action's label, the post-state). (`action` is a keyword in Veil.) -/
structure VC where
  id : Nat
  name : Name
  status : Option Veil.VCStatus
  actionName : Option Name
  propertyName : Option Name
  alternativeFor : Option Nat
  counterexample : Option Json

def counterexample (vc : Veil.VCResult Veil.VCMetadata Veil.SmtResult) : Option Json := Id.run do
  for d in vc.timing.dischargers do
    if let .finished (.disproven (some (.sat cexs)) _) := d.status then
      for c in cexs do
        if let some m := c then
          return some m.structuredJson
  return none

def summary (vc : Veil.VCResult Veil.VCMetadata Veil.SmtResult) : VC :=
  let (actionName, propertyName) := match vc.metadata with
    | .induction m => (some m.action, some m.property)
    | _ => (none, none)
  { id := vc.id, name := vc.name, status := vc.status, actionName, propertyName,
    alternativeFor := vc.alternativeFor, counterexample := counterexample vc }

/-- `#check_invariants` on the open module, returning its verification conditions. -/
def checkInvariants : CommandElabM (Array VC) := do
  let mod ← Veil.getCurrentModule (errMsg := "no Veil module is open")
  let _ ← mod.ensureVerificationSpec Syntax.missing
  return (← Veil.Verifier.waitFilteredSync Veil.VCMetadata.isInduction).vcs.map summary

end JankVeil
)lean";
}
