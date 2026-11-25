import Elle.Basic

/-!
# The consistency-model lattice (elle/consistency_model.clj)

Anomalies and models are keywords, here strings without the colon. Graphs are adjacency lists
built as `g/map->dag` builds them (graph.clj:363): one edge per `[node succ]`.
-/

namespace Elle.Model

abbrev Dag := List (String × String)

def mapToDag (m : List (String × List String)) : Dag :=
  m.flatMap fun (k, vs) => vs.map fun v => (k, v)

def dagOut (g : Dag) (v : String) : List String := (g.filter (·.1 == v)).map (·.2)
def dagIn (g : Dag) (v : String) : List String := (g.filter (·.2 == v)).map (·.1)
def dagVerts (g : Dag) : List String := dedup (g.flatMap fun (a, b) => [a, b])

/-- `g/bfs` (graph.clj:283): every vertex reachable from `starts`, the starts included. -/
def bfs (next : String → List String) (starts : List String) : List String := Id.run do
  let mut seen : List String := []
  let mut queue := starts
  let mut fuel := 10000
  while !queue.isEmpty && fuel > 0 do
    fuel := fuel - 1
    match queue with
    | v :: q =>
      queue := q
      if !seen.contains v then
        seen := seen ++ [v]
        queue := queue ++ (next v).filter (!seen.contains ·)
    | [] => pure ()
  return seen

/-- consistency_model.clj:55-161. -/
def impliedAnomalies : Dag := mapToDag [
  ("G0", ["G1c", "G0-process"]),
  ("G0-process", ["G1c-process", "G0-realtime"]),
  ("G0-realtime", ["G1c-realtime"]),
  ("G1a", ["G1"]),
  ("G1b", ["G1"]),
  ("G1c", ["G1", "G1c-process"]),
  ("G1c-process", ["G1c-realtime", "G1-process"]),
  ("G1c-realtime", ["G1-realtime"]),
  ("G1", ["G1-process"]),
  ("G1-process", ["G1-realtime"]),
  ("G-single-item", ["G-single", "G-single-item-process", "G-nonadjacent-item"]),
  ("G-single-item-process", ["G-single-process", "G-single-item-realtime", "G-nonadjacent-item-process"]),
  ("G-single-item-realtime", ["G-single-realtime", "G-nonadjacent-item-realtime"]),
  ("G-single", ["G-nonadjacent", "GSIb", "G-single-process"]),
  ("G-single-process", ["G-nonadjacent-process", "G-single-realtime"]),
  ("G-single-realtime", ["G-nonadjacent-realtime"]),
  ("G-nonadjacent-item", ["G-nonadjacent", "G2-item", "G-nonadjacent-item-process"]),
  ("G-nonadjacent-item-process", ["G-nonadjacent-process", "G2-item-process", "G-nonadjacent-item-realtime"]),
  ("G-nonadjacent-item-realtime", ["G2-item-realtime", "G-nonadjacent-realtime"]),
  ("G-nonadjacent", ["G2", "G-nonadjacent-process"]),
  ("G-nonadjacent-process", ["G2-process", "G-nonadjacent-realtime"]),
  ("G-nonadjacent-realtime", ["G2-realtime"]),
  ("G2", ["G2-process"]),
  ("G2-item", ["G2", "G2-item-process"]),
  ("G2-item-process", ["G2-process", "G2-item-realtime"]),
  ("G2-item-realtime", ["G2-realtime"]),
  ("G2-process", ["G2-realtime"]),
  ("GSIa", ["GSI"]),
  ("GSIb", ["GSI"]),
  ("incompatible-order", ["G1a"]),
  ("future-read", ["G1c"]),
  ("dirty-update", ["G1a"]),
  ("lost-update", ["write-skew", "G2-item"]),
  ("write-skew", ["G2"])]

/-- consistency_model.clj:163-178. -/
def severityGraph : Dag := mapToDag [
  ("G0", ["G1c"]), ("G0-process", ["G1c-process"]), ("G0-realtime", ["G1c-realtime"]),
  ("G1c", ["G-single", "G2-item"]),
  ("G1c-process", ["G-single-process", "G2-item-process"]),
  ("G1c-realtime", ["G-single-realtime", "G2-item-realtime"]),
  ("G2", ["G0-process"]),
  ("G2-process", ["G0-realtime"])]

/-- consistency_model.clj:180: anomalies which would imply any of these, these included. -/
def allAnomaliesImplying (as : List String) : List String :=
  if as.isEmpty then [] else bfs (dagIn impliedAnomalies) as

/-- consistency_model.clj:187. -/
def allImpliedAnomalies (as : List String) : List String :=
  if as.isEmpty then [] else bfs (dagOut impliedAnomalies) as

/-- consistency_model.clj:194-230. -/
def canonicalModelNames : List (String × String) := [
  ("consistent-view", "PL-2+"), ("conflict-serializable", "PL-3"), ("cursor-stability", "PL-CS"),
  ("forward-consistent-view", "PL-FCV"), ("monotonic-snapshot-read", "PL-MSR"),
  ("monotonic-view", "PL-2L"), ("read-committed", "PL-2"), ("read-uncommitted", "PL-1"),
  ("repeatable-read", "PL-2.99"), ("serializable", "PL-3"), ("snapshot-isolation", "PL-SI"),
  ("strict-serializable", "PL-SS"), ("strong-serializable", "PL-SS"),
  ("update-serializable", "PL-3U"),
  ("strong-session-read-uncommitted", "strong-session-PL-1"),
  ("strong-session-read-committed", "strong-session-PL-2"),
  ("strong-read-uncommitted", "strong-PL-1"), ("strong-read-committed", "strong-PL-2")]

/-- consistency_model.clj:232: the inverse map; `:PL-3` names `:serializable`. Clojure's `into {}`
keeps the last pair for a repeated key. -/
def friendlyModelName (m : String) : String :=
  if m == "PL-3" then "serializable" else
  match (canonicalModelNames.reverse.find? (·.2 == m)) with
  | some (f, _) => f
  | none => m

def canonicalModelName (m : String) : String := (canonicalModelNames.lookup m).getD m

/-- consistency_model.clj:251-344, then `map-vertices canonical-model-name`. -/
def models : Dag := (mapToDag [
  ("causal-cerone", ["read-atomic"]),
  ("consistent-view", ["cursor-stability", "monotonic-view"]),
  ("conflict-serializable", ["view-serializable"]),
  ("cursor-stability", ["read-committed", "PL-2"]),
  ("forward-consistent-view", ["consistent-view"]),
  ("PL-2", ["PL-1"]),
  ("PL-3", ["repeatable-read", "update-serializable"]),
  ("update-serializable", ["forward-consistent-view"]),
  ("monotonic-atomic-view", ["read-committed"]),
  ("monotonic-view", ["PL-2"]),
  ("monotonic-snapshot-read", ["PL-2"]),
  ("parallel-snapshot-isolation", ["causal-cerone", "update-atomic"]),
  ("prefix", ["causal-cerone"]),
  ("read-atomic", ["monotonic-atomic-view"]),
  ("read-committed", ["read-uncommitted"]),
  ("repeatable-read", ["cursor-stability", "monotonic-atomic-view"]),
  ("update-atomic", ["read-atomic"]),
  ("serializable", ["repeatable-read", "snapshot-isolation", "view-serializable"]),
  ("session-serializable", ["1SR"]),
  ("snapshot-isolation", ["forward-consistent-view", "monotonic-atomic-view",
                          "monotonic-snapshot-read", "parallel-snapshot-isolation", "prefix"]),
  ("strict-serializable", ["PL-3", "serializable", "linearizable", "snapshot-isolation",
                           "strong-snapshot-isolation", "strong-session-serializable"]),
  ("strong-session-PL-1", ["PL-1"]),
  ("strong-session-PL-2", ["PL-2", "strong-session-PL-1"]),
  ("strong-PL-1", ["strong-session-PL-1"]),
  ("strong-PL-2", ["strong-session-PL-2", "strong-PL-1"]),
  ("strong-session-serializable", ["serializable", "strong-session-snapshot-isolation"]),
  ("strong-session-snapshot-isolation", ["snapshot-isolation", "strong-session-PL-2"]),
  ("strong-serializable", ["session-serializable"]),
  ("strong-snapshot-isolation", ["strong-session-snapshot-isolation", "strong-PL-2"]),
  ("linearizable", ["sequential"]),
  ("sequential", ["causal"]),
  ("causal", ["writes-follow-reads", "PRAM"]),
  ("PRAM", ["monotonic-reads", "monotonic-writes", "read-your-writes"])]).map
  fun (a, b) => (canonicalModelName a, canonicalModelName b)

/-- consistency_model.clj:363: models implied by any of `ms`, `ms` included. -/
def allImpliedModels (ms : List String) : List String :=
  bfs (dagOut models) (ms.map canonicalModelName)

/-- consistency_model.clj:370: models which imply any of `ms`, `ms` included. -/
def allImpossibleModels (ms : List String) : List String :=
  bfs (dagIn models) (ms.map canonicalModelName)

/-- consistency_model.clj:408-520. -/
def directProscribed : Dag := (mapToDag [
  ("causal-cerone", ["internal", "G1a"]),
  ("cursor-stability", ["G1", "G-cursor", "lost-update"]),
  ("monotonic-view", ["G1", "G-monotonic"]),
  ("monotonic-snapshot-read", ["G1", "G-MSR"]),
  ("consistent-view", ["G1", "G-single"]),
  ("forward-consistent-view", ["G1", "G-SIb"]),
  ("parallel-snapshot-isolation", ["internal", "G1a"]),
  ("PL-3", ["G1", "G2", "predicate-read-miss", "PL-3-cycle-exists"]),
  ("PL-2", ["G1", "PL-2-cycle-exists"]),
  ("PL-1", ["G0", "duplicate-elements", "cyclic-versions", "PL-1-cycle-exists"]),
  ("prefix", ["internal", "G1a"]),
  ("serializable", ["internal"]),
  ("snapshot-isolation", ["internal", "G1", "G-SI", "G-nonadjacent", "PL-SI-cycle-exists"]),
  ("read-atomic", ["internal", "G1a", "future-read"]),
  ("repeatable-read", ["G1", "G2-item", "PL-2.99-cycle-exists", "lost-update"]),
  ("update-atomic", ["lost-update"]),
  ("strict-serializable", ["G1", "G1c-realtime", "G2-realtime", "PL-SS-cycle-exists"]),
  ("strong-session-PL-1", ["strong-session-PL-1-cycle-exists", "G0-process"]),
  ("strong-session-PL-2", ["strong-session-PL-2-cycle-exists", "G1c-process"]),
  ("strong-PL-1", ["strong-PL-1-cycle-exists", "G0-realtime"]),
  ("strong-PL-2", ["strong-PL-2-cycle-exists", "G1c-realtime"]),
  ("strong-session-snapshot-isolation", ["internal", "G1-process", "G-nonadjacent-process",
                                         "strong-session-snapshot-isolation-cycle-exists"]),
  ("strong-snapshot-isolation", ["internal", "G1-realtime", "G-nonadjacent-realtime",
                                 "strong-snapshot-isolation-cycle-exists"]),
  ("strong-session-serializable", ["G1-process", "G2-process",
                                   "strong-session-serializable-cycle-exists"]),
  ("update-serializable", ["G1", "G-update"])]).map fun (a, b) => (canonicalModelName a, b)

def sortedSet (l : List String) : List String := (dedup l).mergeSort fun a b => decide (a ≤ b)

/-- consistency_model.clj:554, as written. -/
def anomaliesProhibitedBySlow (ms : List String) : List String :=
  sortedSet (allAnomaliesImplying ((allImpliedModels ms).flatMap (dagOut directProscribed)))

/-- consistency_model.clj:568, as written. -/
def anomaliesToImpossibleModelsSlow (as : List String) : List String :=
  sortedSet (allImpossibleModels ((allImpliedAnomalies as).flatMap (dagIn directProscribed)))

/-- Every model name Elle knows (`all-models`, consistency_model.clj:346). -/
def allModelNames : List String :=
  sortedSet (dagVerts models ++ canonicalModelNames.map (·.1) ++ canonicalModelNames.map (·.2))

/-- Every anomaly name in the graphs. -/
def allAnomalyNames : List String :=
  sortedSet (dagVerts impliedAnomalies ++ dagVerts severityGraph ++ directProscribed.map (·.2))

/-- The two functions distribute over unions of their arguments (each is a reachability set,
then a union), so they are tabled per name, once. -/
def prohibitedTable : List (String × List String) :=
  allModelNames.map fun m => (m, anomaliesProhibitedBySlow [m])

def impossibleTable : List (String × List String) :=
  allAnomalyNames.map fun a => (a, anomaliesToImpossibleModelsSlow [a])

def anomaliesProhibitedBy (ms : List String) : List String :=
  sortedSet (ms.flatMap fun m =>
    (prohibitedTable.lookup (canonicalModelName m)).getD (anomaliesProhibitedBySlow [m]))

def anomaliesToImpossibleModels (as : List String) : List String :=
  sortedSet (as.flatMap fun a => (impossibleTable.lookup a).getD (anomaliesToImpossibleModelsSlow [a]))

/-- consistency_model.clj:377-406: `most-models` with `g/out`. -/
def weakestModels (ms : List String) : List String :=
  let ms := ms.map canonicalModelName
  ms.foldl (fun acc m =>
    let acc' := acc.filter (· != m)
    if (bfs (dagOut models) [m]).any acc'.contains then acc' else acc) (dedup ms)

/-- consistency_model.clj:588: `{:not .. :also-not ..}`, friendly names. -/
def friendlyBoundary (as : List String) : List String × List String :=
  let impossible := anomaliesToImpossibleModels as
  let isNot := weakestModels impossible
  (sortedSet (isNot.map friendlyModelName),
   sortedSet ((impossible.filter (!isNot.contains ·)).map friendlyModelName))

/-- `topo-depths` (graph.clj:508) of the merged implied and severity graphs, then depth 0 for
every directly proscribed anomaly (consistency_model.clj:522-536). -/
def anomalyDepths : List (String × Nat) := Id.run do
  let g : Dag := dedup (impliedAnomalies ++ severityGraph)
  let mut verts := dagVerts g
  let mut edges := g
  let mut depth := 0
  let mut out : List (String × Nat) := []
  let mut fuel := 1000
  while !verts.isEmpty && fuel > 0 do
    fuel := fuel - 1
    let top := verts.filter fun v => !(edges.any (·.2 == v))
    if top.isEmpty then break
    out := out ++ top.map (·, depth)
    verts := verts.filter (!top.contains ·)
    edges := edges.filter fun (a, _) => !top.contains a
    depth := depth + 1
  let zeros := dedup (directProscribed.map (·.2))
  for a in zeros do
    if (out.lookup a).isNone then out := out ++ [(a, 0)]
  return out

/-- consistency_model.clj:538: by depth (unknown first, as Clojure compares nil low), then name. -/
def anomalyLt (a b : String) : Bool :=
  let da := anomalyDepths.lookup a
  let db := anomalyDepths.lookup b
  match da, db with
  | none, some _ => true
  | some _, none => false
  | some x, some y => x < y || (x == y && decide (a < b))
  | none, none => decide (a < b)

end Elle.Model
