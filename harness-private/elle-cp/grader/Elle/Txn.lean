import Elle.Core
import Elle.Bfs

/-!
# elle.txn: cycle analysis over transactional workloads (txn.clj)
-/

namespace Elle

/-- Options of `elle.list-append/check` and `elle.rw-register/check`. -/
structure Opts where
  /-- `:consistency-models`; `none` is the default `[:strict-serializable]` (txn.clj:668). -/
  models : Option (List String) := none
  /-- `:anomalies`. -/
  anomalies : List String := []
  /-- rw-register's `:wfr-keys?`. -/
  wfrKeys : Bool := false
  /-- rw-register's `:sequential-keys?` (rw_register.clj:663). -/
  sequentialKeys : Bool := false
  /-- rw-register's `:linearizable-keys?` (rw_register.clj:669). -/
  linearizableKeys : Bool := false
  /-- rw-register's `:transaction-order`: completion index -> its place in a total order
  (rw_register.clj:655, 925-932). -/
  txnOrder : Option (List (Nat × Int)) := none
  /-- The service's `with-redefs [elle/realtime-graph realtime-per-key-graph]`
  (elle_service.clj:217): every use of the real-time graph takes the per-key one. -/
  perKey : Bool := false
  /-- Where `util/timeout` fires in `cycle-cases-in-scc` (txn.clj:856), per SCC (its place in
  `sccs`): a cut point (see `cutState`); absent: the search finishes. -/
  cuts : List (Nat × Nat) := []
  /-- Round 2's D3 fix: the process order reaches an `:info` op (an edge into it, never out of
  it) for models that prohibit G1a; the real-time order likewise, and only then. -/
  fixD3 : Bool := false
  /-- Round 2's D13 fix: rw-register indexes `:info` ops' external writes (wr edges out of them,
  ww and rw edges into them, never ww out), and a version written only by `:info` ops is
  stepped over (its predecessors linked to its successors). -/
  fixD13 : Bool := false
  /-- The deployed service's closed-predicate fixes (service-5fc908e/src/elle/closed_predicate.clj:
  D9's `:w`, D10's `versions-after` paren and D11's `version<`). -/
  cpFixed : Bool := false
  /-- The deployed service's `keys-of` (elle_service.clj:194-202, D19's fix): an init's keys are
  its map's keys, and a predicate read reads every key. -/
  perKeyFixed : Bool := false
  /-- Round 3's fixes (scratch/r3/fix-dN): D1 unread appends after a read of the same key, D2
  process and real-time graphs together, D4 failed appends stepped over, D5 `:info` appends
  unindexed for models allowing G1a, D6 every external read and fuzzy reads, D7 rw-register
  future reads, D8 garbage reads, D12 tie order by first read, D20 item anti-dependencies in
  mixed cycles, D21 predicate rows as item reads, D22 explainers read `:ok` ops only. -/
  fixD1 : Bool := false
  fixD2 : Bool := false
  fixD4 : Bool := false
  fixD5 : Bool := false
  fixD6 : Bool := false
  fixD7 : Bool := false
  fixD8 : Bool := false
  fixD12 : Bool := false
  fixD20 : Bool := false
  fixD21 : Bool := false
  fixD22 : Bool := false
  deriving Repr, Inhabited

/-- An anomaly case. -/
inductive Case where
  /-- An explained cycle: its ops (first repeated last) and steps. -/
  | cycle (ops : List Nat) (steps : List Step)
  /-- A cycle-exists case: the SCC (op indices). -/
  | exists_ (subgraph : String) (scc : List Nat)
  /-- Any other case: the ops it names. -/
  | other (ops : List Nat)
  /-- `:empty-transaction-graph true`. -/
  | flag
  deriving Repr, Inhabited

abbrev Anomalies := List (String × List Case)

def addCases (m : Anomalies) (k : String) (cs : List Case) : Anomalies :=
  if cs.isEmpty then m else amUpdate m k [] (· ++ cs)

/-! ## Write indices (txn.clj:91-189) -/

/-- `failed-write-indices` (txn.clj:111): key -> value -> index of the failed op writing it. -/
def failedWriteIndices (write? : F → Bool) (h : List Op) : List (Nat × List (Val × Nat)) :=
  h.foldl (fun failed o =>
    if o.isFail then
      o.value.foldl (fun f m => if write? m.f then amUpdate f m.k [] (fun vs => amPut vs m.v o.index) else f) failed
    else failed) []

/-- `intermediate-write-indices` (txn.clj:162), over every op, invocations included. -/
def intermediateWriteIndices (write? : F → Bool) (h : List Op) : List (Nat × List (Val × Nat)) :=
  h.foldl (fun im o =>
    (o.value.foldl (fun (im, final) m =>
      if write? m.f then
        match final.lookup m.k with
        | some e => (amUpdate im m.k [] (fun vs => amPut vs e o.index), amPut final m.k m.v)
        | none => (im, amPut final m.k m.v)
      else (im, final)) (im, ([] : List (Nat × Val)))).1) []

/-- `lost-update-cases` (txn.clj:191): ok txns which read a key's value (their first read) and
then wrote that key, grouped by key and value; groups of two or more. -/
def lostUpdateCases (write? : F → Bool) (h : List Op) : List (Nat × Val × List Nat) := Id.run do
  let mut txns : List (Nat × List (Val × List Nat)) := []
  for o in h do
    if o.type != .ok then continue
    let mut reads : List (Nat × Val) := []
    let mut writes : List Nat := []
    for m in o.value do
      let rv := reads.lookup m.k
      if write? m.f && !writes.contains m.k then
        match rv with
        | none => pure ()
        | some v =>
          txns := amUpdate txns m.k [] (fun vm => amUpdate vm v [] (· ++ [o.index]))
          writes := writes ++ [m.k]
      else
        if rv.isNone then reads := amPut reads m.k m.v
  let mut cases := []
  for (k, vm) in txns do
    for (v, ts) in vm do
      if 2 ≤ ts.length then cases := cases ++ [(k, v, ts)]
  return cases

/-! ## Cycle existence (txn.clj:299-473) -/

inductive Sub where
  | rels (r : Rels)
  | ext (a b : Sub)
  deriving Repr, Inhabited

structure ExistsSpec where
  model : String
  sub : Sub
  name : String

open Rels in
/-- txn.clj:301-353. -/
def cycleExistsSpecs : List ExistsSpec := [
  ⟨"PL-1", .rels (WW ||| WWP), "[:union :ww :wwp]"⟩,
  ⟨"PL-2", .rels (WW ||| WWP ||| WR ||| WRP), "[:union :ww :wwp :wr :wrp]"⟩,
  ⟨"PL-SI", .ext (.rels (WW ||| WWP ||| WR ||| WRP)) (.rels (RW ||| RWP)), "[:extension ..]"⟩,
  ⟨"PL-2.99", .rels (WW ||| WWP ||| WR ||| WRP ||| RW), "[:union :ww :wwp :wr :wrp :rw]"⟩,
  ⟨"PL-3", .rels (WW ||| WWP ||| WR ||| WRP ||| RW ||| RWP), "[:union .. :rwp]"⟩,
  ⟨"strong-session-PL-1", .rels (WW ||| WWP ||| PROCESS), "[:union :ww :wwp :process]"⟩,
  ⟨"strong-session-PL-2", .rels (WW ||| WWP ||| WR ||| WRP ||| PROCESS), "[.. :process]"⟩,
  ⟨"strong-session-snapshot-isolation",
    .ext (.rels (WW ||| WWP ||| WR ||| WRP ||| PROCESS)) (.rels (RW ||| RWP)), "[:extension .. :process]"⟩,
  ⟨"strong-session-serializable", .rels (WW ||| WWP ||| WR ||| WRP ||| RW ||| RWP ||| PROCESS), "[.. :process]"⟩,
  ⟨"strong-PL-1", .rels (WW ||| WWP ||| REALTIME), "[:union :ww :wwp :realtime]"⟩,
  ⟨"strong-PL-2", .rels (WW ||| WWP ||| WR ||| WRP ||| REALTIME), "[.. :realtime]"⟩,
  ⟨"strong-snapshot-isolation",
    .ext (.rels (WW ||| WWP ||| WR ||| WRP ||| REALTIME)) (.rels (RW ||| RWP)), "[:extension .. :realtime]"⟩,
  ⟨"PL-SS", .rels (WW ||| WWP ||| WR ||| WRP ||| RW ||| RWP ||| REALTIME), "[.. :realtime]"⟩]

def ExistsSpec.type (s : ExistsSpec) : String := s.model ++ "-cycle-exists"
def ExistsSpec.friendly (s : ExistsSpec) : String := Model.friendlyModelName s.model

/-- `cycle-exists-subgraph` (txn.clj:355). -/
def existsSubgraph (g : Graph) : Sub → Graph
  | .rels r => g.project r
  | .ext a b => Graph.seqExtension (existsSubgraph g a) (existsSubgraph g b)

/-- `nontrivial-scc?` (txn.clj:402). -/
def nontrivialScc (g : Graph) (scc : List Nat) : Bool :=
  match scc with
  | [] => false
  | [v] => g.hasEdge v v
  | _ => true

/-- `cycle-exists-cases` (txn.clj:414): the weakest models whose subgraph has a cycle. -/
def cycleExistsCases (g : Graph) : List (String × String × List Nat) := Id.run do
  let mut errs := []
  let mut redundant : List String := []
  for s in cycleExistsSpecs do
    if redundant.contains s.model then continue
    let sg := existsSubgraph g s.sub
    let cs := ((tarjan sg {} true).filter (nontrivialScc sg)).mergeSort fun a b => decide (a.length ≤ b.length)
    match cs with
    | [] => pure ()
    | c :: _ =>
      errs := errs ++ [(s.type, s.friendly, c)]
      redundant := redundant ++ Model.allImpossibleModels [s.model]
  return errs

/-- `remove-redundant-cycle-exists` (txn.clj:448). -/
def removeRedundantCycleExists (m : Anomalies) : Anomalies :=
  let others := (m.map (·.1)).filter fun t => !t.endsWith "-cycle-exists"
  let impossible := Model.anomaliesToImpossibleModels others
  let omitT := (cycleExistsSpecs.filter fun s => impossible.contains s.model).map (·.type)
  m.filter fun (k, _) => !omitT.contains k

/-! ## Explaining and classifying cycles (txn.clj:477-541) -/

/-- `elle.txn/cycle-explainer`: the type of a cycle from its steps' types. `none`: Elle throws
"Don't know how to classify". -/
def classify (steps : List Step) (d20 : Bool := false) : Option String :=
  let n (t : String) := (steps.filter (·.type == t)).length
  let realtime := n "realtime"
  let process := n "process"
  let rwc := n "rw" + n "rwp"
  let predicate := steps.any (·.predicate) || 0 < n "rwp"
  let types := steps.map (·.type)
  let rwAdj := match types.getLast? with
    | none => false
    | some l =>
      let ts := l :: types
      (ts.zip (ts.drop 1)).any fun (a, b) => (a == "rw" || a == "rwp") && (b == "rw" || b == "rwp")
  let dd : Option String :=
    if rwc == 1 then some (if predicate then "G-single" else "G-single-item")
    else if 1 < rwc then
      -- D20's fix: Adya's G2-item is a cycle with one or more item anti-dependencies, whatever
      -- else it holds; Elle named any cycle with a predicate edge G2
      let item := if d20 then 0 < n "rw" else !predicate
      some (if rwAdj then (if item then "G2-item" else "G2")
            else (if item then "G-nonadjacent-item" else "G-nonadjacent"))
    else if 0 < n "wr" + n "wrp" then some "G1c"
    else if 0 < n "ww" + n "wwp" then some "G0"
    else none
  let sub := if 0 < realtime then "-realtime" else if 0 < process then "-process" else ""
  dd.map (· ++ sub)

/-- `explain-cycle`: steps for each consecutive pair. `none` when a pair is unexplained (Elle
throws IllegalStateException). -/
def explainCycle (a : Analysis) (cycle : List Nat) : Option (List Step) :=
  (cycle.zip (cycle.drop 1)).mapM fun (x, y) => a.explain x y

open Rels in
/-- `base-cycle-anomaly-specs` (txn.clj:543-608). -/
def baseCycleSpecs : List (String × Spec) := [
  ("G0", { rels := WW ||| WWP }),
  ("G1c", { rels := WW ||| WWP ||| WR ||| WRP, required := [WR ||| WRP] }),
  ("G-single-item", { rels := WW ||| WWP ||| WR ||| WRP, single := some RW, type := some "G-single-item" }),
  ("G-single", { rels := WW ||| WWP ||| WR ||| WRP, single := some (RW ||| RWP), type := some "G-single" }),
  ("G-nonadjacent-item", { rels := WW ||| WWP ||| WR ||| WRP, nonadjacent := some RW, multiple := some RW,
                           type := some "G-nonadjacent-item" }),
  ("G-nonadjacent", { rels := WW ||| WWP ||| WR ||| WRP, nonadjacent := some (RW ||| RWP),
                      multiple := some (RW ||| RWP), type := some "G-nonadjacent" }),
  ("G2-item", { rels := WW ||| WWP ||| WR ||| WRP ||| RW, multiple := some RW, type := some "G2-item" }),
  ("G2", { rels := WW ||| WWP ||| WR ||| WRP ||| RW ||| RWP, multiple := some (RW ||| RWP), type := some "G2" })]

/-- D20's fix: the item searches also take predicate anti-dependencies, as long as one item
anti-dependency is in the cycle. -/
def baseCycleSpecsFx (d20 : Bool) : List (String × Spec) :=
  if !d20 then baseCycleSpecs else baseCycleSpecs.map fun (n, s) =>
    if n == "G-nonadjacent-item" then
      (n, { s with nonadjacent := some (Rels.RW ||| Rels.RWP), multiple := some (Rels.RW ||| Rels.RWP),
                   required := [Rels.RW] })
    else if n == "G2-item" then
      (n, { s with rels := Rels.WW ||| Rels.WWP ||| Rels.WR ||| Rels.WRP ||| Rels.RW ||| Rels.RWP,
                   multiple := some (Rels.RW ||| Rels.RWP), required := [Rels.RW] })
    else (n, s)

/-- `cycle-anomaly-spec-variant` (txn.clj:610). -/
def specVariant (variant : String) (p : String × Spec) : String × Spec :=
  let rel := if variant == "realtime" then Rels.REALTIME else Rels.PROCESS
  let s := p.2
  let s' := { s with rels := s.rels ||| rel, required := s.required ++ [rel],
                     type := s.type.map fun _ => p.1 ++ "-" ++ variant }
  (p.1 ++ "-" ++ variant, s')

/-- `cycle-anomaly-specs` (txn.clj:630): a sorted map by `anomaly-depth-compare`. -/
def cycleSpecsFx (d20 : Bool) : List (String × Spec) :=
  ((baseCycleSpecsFx d20).flatMap fun p => [p, specVariant "process" p, specVariant "realtime" p]).mergeSort
    fun a b => Model.anomalyLt a.1 b.1 || a.1 == b.1

def cycleSpecs : List (String × Spec) := cycleSpecsFx false

def cycleTypes : List String := cycleSpecs.map (·.1)
def processAnomalyTypes : List String := cycleTypes.filter (·.endsWith "-process")
def realtimeAnomalyTypes : List String := cycleTypes.filter (·.endsWith "-realtime")
def unknownAnomalyTypes : List String := ["empty-transaction-graph", "cycle-search-timeout"]

def Opts.modelList (o : Opts) : List String := o.models.getD ["strict-serializable"]

/-- `prohibited-anomaly-types` (txn.clj:656). -/
def prohibitedAnomalyTypes (o : Opts) : List String :=
  dedup (Model.allAnomaliesImplying o.anomalies ++ Model.anomaliesProhibitedBy o.modelList)

/-- `reportable-anomaly-types` (txn.clj:670). -/
def reportableAnomalyTypes (o : Opts) : List String := dedup (prohibitedAnomalyTypes o ++ unknownAnomalyTypes)

/-- Which extra graph `additional-graphs` (txn.clj:676) picks. -/
inductive Extra where | none | process | realtime
  /-- The service's per-key real-time graph in place of `elle/realtime-graph`. -/
  | realtimePerKey
  /-- D3's fix: process edges into `:info` ops too (models prohibiting G1a). -/
  | processInfo
  /-- D3's fix: real-time edges never into `:info` ops (models allowing G1a). -/
  | realtimeNoInfo
  /-- The deployed service's per-key graph (D19's `keys-of`). -/
  | realtimePerKeyFixed
  /-- D2's fix: the process graph, then the real-time graph (each as D3's fix picks it). -/
  | processRealtime (intoInfo noInfo : Bool)
  deriving Repr, DecidableEq

/-- D2's fix: the models prohibit some process anomaly but not its real-time variant, so a
process cycle found as its real-time variant would pass. -/
def needsProcessToo (o : Opts) : Bool :=
  let prohibited := prohibitedAnomalyTypes o
  processAnomalyTypes.any fun t =>
    prohibited.contains t && !prohibited.contains (String.ofList (t.toList.take (t.length - "process".length)) ++ "realtime")

def additionalGraphs (o : Opts) : Extra :=
  let ats := reportableAnomalyTypes o
  let g1a := (prohibitedAnomalyTypes o).contains "G1a"
  if realtimeAnomalyTypes.any ats.contains then
    (if o.perKey then (if o.perKeyFixed then .realtimePerKeyFixed else .realtimePerKey)
     else if o.fixD2 && needsProcessToo o then .processRealtime (o.fixD3 && g1a) (o.fixD3 && !g1a)
     else if o.fixD3 && !g1a then .realtimeNoInfo else .realtime)
  else if processAnomalyTypes.any ats.contains then (if o.fixD3 && g1a then .processInfo else .process)
  else .none

def extraAnalysesOf (e : Extra) (h : History) : List Analysis :=
  match e with
  | .realtime => [realtimeGraph h]
  | .realtimePerKey => [realtimePerKeyGraph h]
  | .process => [processGraph h]
  | .processInfo => [processGraph h true]
  | .realtimeNoInfo => [realtimeGraph h true]
  | .realtimePerKeyFixed => [realtimePerKeyGraph h true]
  | .processRealtime i n => [combine [processGraph h i, realtimeGraph h n]]
  | .none => []

def extraAnalyses (o : Opts) (h : History) : List Analysis := extraAnalysesOf (additionalGraphs o) h

/-- `cycle-in-scc-of-type` (txn.clj:758): search, explain, keep only a matching type. An
unexplained pair (`explain-cycle-pair-data`, core.clj:445) or an unclassified cycle
(txn.clj:526) throws, as in Elle. -/
def cycleInSccOfType (g : Graph) (o : Order) (a : Analysis) (p : String × Spec) (d20 : Bool := false) :
    Except String (Option (List Nat × List Step × String)) :=
  let s := p.2
  let rels := s.rels ||| (s.nonadjacent.getD 0) ||| (s.required.foldl (· ||| ·) 0) |||
              (s.single.getD 0) ||| (s.multiple.getD 0)
  match bfsSearch (g.project rels) o s with
  | none => .ok none
  | some c =>
    match explainCycle a c with
    | none => .error s!"IllegalStateException: Explainer was unable to explain the relationship (cycle {c})"
    | some steps =>
      match classify steps d20 with
      | none => .error "IllegalStateException: Don't know how to classify"
      | some t =>
        match s.type with
        | some want => .ok (if want == t then some (c, steps, t) else none)
        | none => .ok (some (c, steps, t))

/-- `cycle-exists-cases->impossible-cycle-anomalies` (txn.clj:797). -/
def impossibleCycleAnomalies (cases : List (String × String × List Nat)) : List String :=
  let impossible := Model.allImpossibleModels (cases.map (·.2.1))
  let possible := (cycleExistsSpecs.map (·.model)).filter (!impossible.contains ·)
  let prohibited := Model.anomaliesProhibitedBy possible
  cycleTypes.filter prohibited.contains

/-- The searches of `cycle-cases-in-scc`'s reduce (txn.clj:876-891), in order: each type as it is
pushed on the `types` atom, and its result (pushed on `cycles` when found). A search that throws
ends the list with its error. -/
def sccSearches (g : Graph) (o : Order) (a : Analysis) (d20 : Bool := false) :
    List (String × Except String (Option (List Nat × List Step × String))) := Id.run do
  let ex := cycleExistsCases g
  -- D20's fix: PL-2.99's cycle-exists subgraph has no predicate anti-dependencies, while a G2-item
  -- (or G-nonadjacent-item) cycle may hold some beside an item one: its absence rules neither out
  let mut redundant := (impossibleCycleAnomalies ex).filter fun t =>
    !(d20 && (t.startsWith "G2-item" || t.startsWith "G-nonadjacent-item"))
  let mut out := []
  for p in cycleSpecsFx d20 do
    if redundant.contains p.1 then continue
    let r := cycleInSccOfType g o a p d20
    out := out ++ [(p.1, r)]
    match r with
    | .ok (some _) => redundant := redundant ++ Model.allImpliedAnomalies [p.1]
    | .ok none => pure ()
    | .error _ => return out
  return out

/-- `g/fallback-cycle` (graph.clj:490): a DFS from the first vertex along first successors until a
successor is already on the path. -/
def fallbackCycle (g : Graph) (o : Order) : List Nat := Id.run do
  let some start := (g.vertsIn o).head? | return []
  let mut path : List Nat := [start]
  let mut seen : List (Nat × Nat) := [(start, 0)]
  let mut fuel := g.verts.length + 2
  while fuel > 0 do
    fuel := fuel - 1
    let vs := g.out o (path.getLastD start)
    match vs.findSome? (seen.lookup ·) with
    | some i => return path.drop i ++ [path.getD i start]
    | none =>
      match vs.find? (fun v => (seen.lookup v).isNone) with
      | some v =>
        seen := seen ++ [(v, path.length)]
        path := path ++ [v]
      | none => return []
  return []

/-- What `util/timeout` (util.clj:29) leaves when it fires at cut point `c` of the searches:
`c = 0` before the first type is pushed; `c = 2j - 1` with j types pushed and the j-th still
searching; `c = 2j` with the j-th search done (its cycle pushed if found). -/
def cutState (searches : List (String × Except String (Option (List Nat × List Step × String))))
    (c : Nat) : List String × List (List Nat × List Step × String) :=
  let j := (c + 1) / 2
  let pushed := searches.take j
  let done := if c % 2 == 0 then pushed else pushed.take (j - 1)
  (pushed.map (·.1), done.filterMap fun (_, r) => match r with | .ok (some x) => some x | _ => none)

/-- How many cut points the searches have (`cutState` takes 0 to this). -/
def cutPoints (searches : List (String × Except String (Option (List Nat × List Step × String)))) : Nat :=
  2 * searches.length

/-- `cycle-cases-in-scc` (txn.clj:839), with `util/timeout` firing at `cut` (none: never). On a
timeout: a `:cycle-search-timeout` case, the fallback cycle explained (txn.clj:729-756; both of
its branches take `g/fallback-cycle` of the whole SCC), the cycle-exists cases and the cycles found
so far (txn.clj:867-874). -/
def cycleCasesInSccE (g : Graph) (o : Order) (a : Analysis) (cut : Option Nat := none) (d20 : Bool := false) :
    Except String Anomalies := do
  let ex := cycleExistsCases g
  let exCases := ex.map fun (t, _, scc) => (t, Case.exists_ t scc)
  let searches := sccSearches g o a d20
  match cut with
  | none =>
    let mut found : List (String × Case) := []
    for (_, r) in searches do
      match r with
      | .error e => throw e
      | .ok (some (c, steps, t)) => found := found ++ [(t, Case.cycle c steps)]
      | .ok none => pure ()
    return (exCases ++ found).foldl (fun m (t, c) => addCases m t [c]) []
  | some c =>
    let c := min c (cutPoints searches)
    -- An exception thrown before the cut point reaches the caller (util.clj:35).
    let j := (c + 1) / 2
    for (_, r) in searches.take (if c % 2 == 0 then j else j - 1) do
      if let .error e := r then throw e
    let (types, cycs) := cutState searches c
    let fc := fallbackCycle g o
    let some steps := explainCycle a fc
      | throw s!"IllegalStateException: Explainer was unable to explain the relationship (fallback cycle {fc})"
    let some ft := classify steps d20 | throw "IllegalStateException: Don't know how to classify"
    let foundTypes := cycs.map (·.2.2)
    let notContain := (types.dropLast).filter (!foundTypes.contains ·)
    let timeoutCase := Case.other (notContain.length :: [types.length])
    let all := [("cycle-search-timeout", timeoutCase), (ft, Case.cycle fc steps)] ++ exCases ++
      cycs.map fun (cy, st, t) => (t, Case.cycle cy st)
    return all.foldl (fun m (t, cse) => addCases m t [cse]) []

/-- `cycle-cases-in-scc` without a timeout. -/
def cycleCasesInScc (g : Graph) (o : Order) (a : Analysis) : Anomalies :=
  match cycleCasesInSccE g o a with
  | .ok m => m
  | .error _ => []

/-- `cycles` (txn.clj:928): `cuts` gives the cut point of each SCC's search (by its place in
`sccs`). -/
def cyclesE (a : Analysis) (o : Order) (cuts : List (Nat × Nat) := []) (d20 : Bool := false) : Except String Anomalies := do
  let mut m : Anomalies := a.anomalies.map fun (k, _) => (k, [Case.flag])
  if a.graph.size == 0 then m := amPut m "empty-transaction-graph" [Case.flag]
  let mut i := 0
  for scc in sccs a.graph o do
    let g := a.graph.select scc
    for (t, cs) in ← cycleCasesInSccE g o a (cuts.lookup i) d20 do
      m := addCases m t cs
    i := i + 1
  return m

/-- `cycles` (txn.clj:928), errors dropped (round 1's form). -/
def cycles (a : Analysis) (o : Order) : Anomalies :=
  match cyclesE a o with
  | .ok m => m
  | .error _ => a.anomalies.map fun (k, _) => (k, [Case.flag])

inductive Valid where
  | true_ | false_ | unknown
  deriving Repr, DecidableEq, Inhabited

def Valid.str : Valid → String
  | .true_ => "true" | .false_ => "false" | .unknown => ":unknown"

structure Result where
  valid : Valid
  anomalyTypes : List String := []
  anomalies : Anomalies := []
  /-- `:not` and `:also-not`. -/
  boundary : List String × List String := ([], [])
  deriving Repr, Inhabited

/-- `result-map` (txn.clj:1003). -/
def resultMap (o : Opts) (m : Anomalies) (withBoundary : Bool := false) : Result :=
  let prohibited := prohibitedAnomalyTypes o
  let reportableTs := reportableAnomalyTypes o
  let bad := m.filter fun (k, _) => prohibited.contains k
  let reportable := removeRedundantCycleExists (m.filter fun (k, _) => reportableTs.contains k)
  if reportable.isEmpty then { valid := .true_ }
  else
    { valid := if !bad.isEmpty then .false_ else .unknown,
      anomalyTypes := Model.sortedSet (reportable.map (·.1)),
      anomalies := reportable,
      boundary := if withBoundary then Model.friendlyBoundary (m.map (·.1)) else ([], []) }

/-- A checker's outcome: a result, or an exception (`throw+`, an assertion). -/
inductive Outcome where
  | result (r : Result)
  | thrown (what : String)
  deriving Repr, Inhabited

def Outcome.valid : Outcome → Option Valid
  | .result r => some r.valid
  | .thrown _ => none

end Elle
