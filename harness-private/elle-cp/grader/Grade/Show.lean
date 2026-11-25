import Elle.Txn

/-!
# Printing histories (as EDN) and outcomes, and the keys outcomes are compared by
-/

namespace Grade.Show

open Elle

def ednPred : Pred → String
  | .tru => ":true"
  | .eq n => s!"[:= {n}]"
  | .mod m t => s!"[:mod {m} {t}]"

partial def ednVal : Val → String
  | .nil => "nil"
  | .int i => toString i
  | .list l => "[" ++ " ".intercalate (l.map toString) ++ "]"
  | .kmap l => "{" ++ ", ".intercalate (l.map fun (k, v) => s!"{k} {ednVal v}") ++ "}"
  | .unborn => ":elle/unborn"
  | .dead => ":elle/dead"

def ednMop (m : Mop) : String :=
  match m.f with
  | .r => s!"[:r {m.k} {ednVal m.v}]"
  | .rp => s!"[:rp {ednPred m.pred} {ednVal m.v}]"
  | .insert => s!"[:insert {m.k} {ednVal m.v}]"
  | .w => s!"[:w {m.k} {ednVal m.v}]"
  | .delete => s!"[:delete {m.k}]"
  | .append => s!"[:append {m.k} {ednVal m.v}]"

def ednType : OpType → String
  | .invoke => ":invoke" | .ok => ":ok" | .fail => ":fail" | .info => ":info"

def ednOp (o : Op) : String :=
  if o.f == .init then
    let m := ", ".intercalate (o.value.map fun m => s!"{m.k} {ednVal m.v}")
    s!"\{:index {o.index}, :process {o.process}, :type {ednType o.type}, :f :init, :value \{{m}}}"
  else
    let v := " ".intercalate (o.value.map ednMop)
    s!"\{:index {o.index}, :process {o.process}, :type {ednType o.type}, :f :txn, :value [{v}]}"

def ednHistory (h : History) : String := "[" ++ "\n ".intercalate (h.toList.map ednOp) ++ "]"

def stepStr (s : Step) : String :=
  s.type ++ (match s.key with | some k => s!"/{k}" | none => "") ++ (if s.predicate then "(p)" else "")

def caseStr : Case → String
  | .cycle ops steps => s!"cycle {ops} steps [{" ".intercalate (steps.map stepStr)}]"
  | .exists_ _ scc => s!"scc {scc}"
  | .other ops => s!"ops {ops}"
  | .flag => "true"

def sortedAnomalies (m : Anomalies) : Anomalies := m.mergeSort fun a b => decide (a.1 ≤ b.1)

/-- An outcome, one line per anomaly type. -/
def outcomeStr : Outcome → String
  | .thrown e => s!"thrown: {e}"
  | .result r =>
    let head := s!"valid {r.valid.str}, anomaly types {r.anomalyTypes}"
    let lines := (sortedAnomalies r.anomalies).map fun (k, cs) =>
      s!"\n    {k}: " ++ "; ".intercalate (cs.map caseStr)
    head ++ String.join lines

/-- The verdict: `:valid?` and the anomaly types, or that it threw. -/
def verdictKey : Outcome → String
  | .thrown _ => "thrown"
  | .result r => s!"{r.valid.str} {r.anomalyTypes}"

/-- The verdict and every case (cycles with their steps), the anomaly map by type. An exception's
message is not compared. -/
def detailKey : Outcome → String
  | .thrown _ => "thrown"
  | .result r => s!"{r.valid.str} {r.anomalyTypes} " ++
      toString (repr (sortedAnomalies r.anomalies)) ++ s!" {r.boundary}"

end Grade.Show
