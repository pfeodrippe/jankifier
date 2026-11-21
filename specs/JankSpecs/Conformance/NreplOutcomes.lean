import JankSpecs.Nrepl
import JankSpecs.Conformance.Outcomes

/-!
# The nREPL model's outcomes

For a script of four requests (which connection sends each, what it is, in
which session), every outcome the model allows, as
`conformance/nrepl/run.py` observes jank: per request, its response (for an
eval: the requests whose prints are in its `:out`, its value, whether `done`
came with `eval-error`; for an unknown op, whether it was reported as one) or
`none` if it got none; the prints which went to the server's own stdout;
whether stdout works afterwards; and whether every response carried its
request's `id` and `session`.
-/

namespace Nrepl.Outcomes

open Nrepl JankSpecs.Outcomes

abbrev Conn := Fin 2
abbrev Req := Fin 4
abbrev Sess := Fin 2
abbrev St := State (FieldConcreteType Conn Req Sess kind_t_IndT phase_t_IndT)

def theory (conns : List Nat) (kinds : List kind_t_IndT) (sessions : List Nat) :
    Theory Conn Req Sess kind_t_IndT phase_t_IndT :=
  ⟨fun r => Fin.ofNat 2 (conns.getD r.val 0),
   fun r => kinds.getD r.val .otherOp,
   fun r => Fin.ofNat 2 (sessions.getD r.val 0),
   0⟩

def sys (th : Theory Conn Req Sess kind_t_IndT phase_t_IndT) :=
  letI : Veil.LogSwitch := ⟨false⟩
  enumerableTransitionSystem Conn Req Sess kind_t_IndT phase_t_IndT th

def isEvalKind : kind_t_IndT → Bool
  | .evalOk | .evalPrint | .evalThrow | .evalStar1 | .evalBad => true
  | _ => false

def showVal : Option Req → String
  | some r => toString r.val
  | none => "nil"

def reqs4 : List Req := List.finRange 4

def obs (th : Theory Conn Req Sess kind_t_IndT phase_t_IndT) (s : St) : String :=
  let rels (f : _) (x : Req) (y : Req) : Bool := (f : Std.ExtTreeSet (Req × Req)).contains (x, y)
  let set1 (f : _) (x : Req) : Bool := (f : Std.ExtTreeSet Req).contains x
  let restored := reqs4.all fun q => !set1 s.stdoutTo q
  let answered (r : Req) := (s.phase : Std.ExtTreeMap Req phase_t_IndT).getD r .queued == .answered
  let reqs := reqs4.map fun r =>
    if answered r then
      if isEvalKind (th.reqKind r) then
        let outs := reqs4.filter fun x => rels s.printedIn x r
        let v := reqs4.find? fun q => rels s.valueIs r q
        s!"r{r.val}:out={outs.map (·.val)},value={showVal v},errdone={set1 s.errDoneTogether r}"
      else if th.reqKind r == .unknownOp && set1 s.unknownReported r then s!"r{r.val}:unknown-op"
      else s!"r{r.val}:ok"
    else s!"r{r.val}:none"
  -- The harness's last eval flushes the buffer to wherever stdout points.
  let term := (reqs4.filter fun x =>
    set1 s.printedTerminal x || (set1 s.buffered x && restored)).map (·.val)
  let late := if restored then "visible" else "hidden"
  let tagged := reqs4.all fun r => !answered r || set1 s.tagged r
  s!"{" ".intercalate reqs} term={term} late={late} tagged={tagged}"

def nreplOutcomes (conns : List Nat) (kinds : List kind_t_IndT) (sessions : List Nat) :
    List String :=
  let th := theory conns kinds sessions
  outcomes (sys th).initStates (fun s => ((sys th).tr th s).successes.map (·.2)) reprStr (obs th)

#eval nreplOutcomes [0, 0, 1, 1] [.evalPrint, .evalStar1, .evalPrint, .evalThrow] [0, 1, 0, 1]

end Nrepl.Outcomes
