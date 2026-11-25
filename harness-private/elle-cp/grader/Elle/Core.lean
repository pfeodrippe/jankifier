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
  /-- D1's fix: a `ww` step from a reader of a key's last observed version, itself an unread
  appender of the key, to another unread appender: `ww` in every interpretation where the
  reader's append came first, and a G-single through the reader in every other. -/
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
def processGraph (h : History) (intoInfo : Bool := false) : Analysis := Id.run do
  let mut g : Graph := {}
  let mut last : List (Nat × Nat) := []
  for o in h do
    if intoInfo && o.isInfo then
      -- D3's fix: the process's last acknowledged op precedes its indeterminate one
      match last.lookup o.process with
      | some l => g := g.link l o.index Rels.PROCESS
      | none => pure ()
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
def realtimeGraph (h : History) (noInfo : Bool := false) : Analysis := Id.run do
  let pairs := pairIndex h
  let mut oksBuf : List Nat := []
  let mut g : Graph := {}
  for o in h do
    match o.type with
    | .invoke =>
      match completion h pairs o with
      | some c =>
        if !(noInfo && c.isInfo) then g := oksBuf.foldl (fun g a => g.link a c.index Rels.REALTIME) g
        -- `realtime-graph-without-info` unlinks these edges after the fact: Bifurcan keeps their
        -- vertices (round 3: without them a graph could be empty, `:empty-transaction-graph`)
        else g := oksBuf.foldl (fun g a => (g.addVertex a).addVertex c.index) g
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

/-- The service's `keys-of` (elle_service.clj:180): `(into #{} (map second) (:value op))`. A
txn's mops give their keys, except `[:rp predicate rows]`, whose second element is the predicate;
an `:init` op's value is a map, whose entries' second elements are its values. As strings, so a
key, a value and a predicate compare as Clojure compares them. -/
def svcKeysOf (o : Op) : List String :=
  dedup (o.value.map fun m =>
    if o.f == .init then (match m.v with | .int i => toString i | _ => "nil")
    else if m.f == .rp then s!"pred:{repr m.pred}"
    else toString m.k)

/-- The deployed service's `keys-of` (service-5fc908e/src/elle_service.clj:194-202, D19's fix):
an init's keys are its map's keys; a predicate read reads every key (`::all`). -/
def svcKeysOfFixed (o : Op) : List String :=
  dedup (o.value.map fun m =>
    if o.f == .init then toString m.k
    else if m.f == .rp then "::all"
    else toString m.k)

/-- The service's `realtime-per-key-graph` (elle_service.clj:183; deployed: 204-226): per key,
the completed `:ok` ops no later completion implies yet; an invocation links the buffers of its
keys to its completion. Its explainer is Elle's `RealtimeExplainer`. `fixed`: the deployed
service's, whose sources are every key's buffer for a predicate read, and the op's keys' and the
predicate reads' (`::all`) otherwise (elle_service.clj:213-218). -/
def realtimePerKeyGraph (h : History) (fixed : Bool := false) : Analysis := Id.run do
  let pairs := pairIndex h
  let keysOf := if fixed then svcKeysOfFixed else svcKeysOf
  let mut pending : List (String × List Nat) := []
  let mut g : Graph := {}
  for o in h do
    match o.type with
    | .invoke =>
      match completion h pairs o with
      | some c =>
        let ks := keysOf o
        let sources := if !fixed then ks
          else if ks.contains "::all" then pending.map (·.1) else ks ++ ["::all"]
        for k in sources do
          g := ((pending.lookup k).getD []).foldl (fun g a => g.link a c.index Rels.REALTIME) g
      | none => pure ()
    | .ok =>
      let implied := (g.edges.filter (·.2.1 == o.index)).map (·.1)
      for k in keysOf o do
        pending := amUpdate pending k [] fun ops =>
          [o.index] ++ (ops.filter fun x => x != o.index && !implied.contains x)
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
