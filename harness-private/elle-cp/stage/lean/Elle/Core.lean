import Elle.Graph
import Elle.Model

/-!
# elle.core: analyzers, explainers, process and real-time orders

An analyzer (core.clj:72-80) yields a graph over completion ops and an explainer for its edges.
Explainers compose (`CombinedExplainer`, core.clj:149): the first explainer that explains a pair
wins.
-/

namespace Elle

/-- One step of an explained cycle: its `:type` and, for data steps, the key. -/
structure Step where
  type : String
  key : Option Nat := none
  predicate : Bool := false
  unread : Bool := false
  deriving Repr, Inhabited, BEq

/-- An analysis: `{:graph g :explainer e :anomalies a}`. -/
structure Analysis where
  graph : Graph
  explain : Nat → Nat → Option Step
  anomalies : List (String × List String) := []

instance : Inhabited Analysis := ⟨{ graph := {}, explain := fun _ _ => none }⟩

/-- `combine` (core.clj:179): graphs unioned (starting from an empty op digraph), explainers
tried in order, anomaly maps merged (`reduce merge`: later keys win). -/
def combine (as : List Analysis) : Analysis :=
  { graph := as.foldl (fun g a => g.union a.graph) {},
    explain := fun a b => as.findSome? fun an => an.explain a b,
    anomalies := as.foldl (fun m a => a.anomalies.foldl (fun m (k, v) => amPut m k v) m) [] }

/-- `process-graph` (core.clj:286): each process's consecutive `:ok` ops linked. -/
def processGraph (h : History) : Analysis := Id.run do
  let mut g : Graph := {}
  let mut last : List (Nat × Nat) := []
  for o in h do
    if o.isOk then
      match last.lookup o.process with
      | some l => g := g.link l o.index Rels.PROCESS
      | none => pure ()
      last := amPut last o.process o.index
  let explain := fun (a b : Nat) =>
    match h[a]?, h[b]? with
    | some oa, some ob =>
      if oa.process == ob.process && oa.index < ob.index then some { type := "process" } else none
    | _, _ => none
  return { graph := g, explain }

/-- `realtime-graph` (core.clj:371): a buffer of completed `:ok` ops; each invocation links the
buffer to its completion; each `:ok` drops the ops that already reach it. -/
def realtimeGraph (h : History) : Analysis := Id.run do
  let pairs := pairIndex h
  let mut oksBuf : List Nat := []
  let mut g : Graph := {}
  for o in h do
    match o.type with
    | .invoke =>
      match completion h pairs o with
      | some c => g := oksBuf.foldl (fun g a => g.link a c.index Rels.REALTIME) g
      | none => pure ()
    | .ok =>
      let implied := (g.edges.filter (·.2.1 == o.index)).map (·.1)
      oksBuf := (oksBuf.filter (!implied.contains ·)) ++ (if oksBuf.contains o.index then [] else [o.index])
    | _ => pure ()
  let explain := fun (a' b' : Nat) =>
    match h[a']?, h[b']? with
    | some oa, some ob =>
      match invocation h pairs ob with
      | some b => if oa.index < b.index then some { type := "realtime" } else none
      | none => none
    | _, _ => none
  return { graph := g, explain }

/-- `monotonic-key-order` and `monotonic-key-graph` (core.clj:241-271): ops are maps of keys to
values; ops with successive values of a key are linked all to all (with `ww`). -/
def monotonicKeyGraph (h : History) (vals : Nat → List (Nat × Int)) : Analysis := Id.run do
  let os := (oks h.toList).map (·.index)
  let ks := dedup (os.flatMap fun o => (vals o).map (·.1))
  let mut g : Graph := {}
  for k in ks do
    let withK := os.filterMap fun o => ((vals o).lookup k).map (o, ·)
    let vs := (dedup (withK.map (·.2))).mergeSort fun a b => decide (a ≤ b)
    for (v1, v2) in vs.zip (vs.drop 1) do
      let o1 := (withK.filter (·.2 == v1)).map (·.1)
      let o2 := (withK.filter (·.2 == v2)).map (·.1)
      g := g.linkAllToAll o1 o2 Rels.WW
  let explain := fun (a b : Nat) =>
    let va := vals a
    let vb := vals b
    va.findSome? fun (k, x) => match vb.lookup k with
      | some y => if x < y then some { type := "monotonic", key := some k } else none
      | none => none
  return { graph := g, explain }

/-- `elle.core/check` (core.clj:573): valid iff the analysis graph has no SCC. -/
def coreCheck (a : Analysis) : Bool := (sccs a.graph).isEmpty

end Elle
