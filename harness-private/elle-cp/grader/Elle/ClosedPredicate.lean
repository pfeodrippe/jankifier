import Elle.Txn

/-!
# elle.closed-predicate (closed_predicate.clj)

An `:init` op (here `f := .init`, its map as `[:w k v]` mops) creates the universe; transactions
insert, write, delete, read keys and read predicates (`[:rp pred {k v ..}]`, the read map as
`Val.kmap`). Versions are the writes in history order (closed_predicate.clj:191).
-/

namespace Elle.ClosedPredicate

open Elle

/-- `xor` (closed_predicate.clj:113). -/
def xor' (a b : Bool) : Bool := if a then !b else b

/-- `ext-writes-txn` (closed_predicate.clj:120). -/
def extWritesTxn (txn : List Mop) : List (Nat × Val) :=
  txn.foldl (fun ext m => match m.f with
    | .w | .insert => amPut ext m.k m.v
    | .delete => amPut ext m.k .dead
    | _ => ext) []

/-- `ext-writes-op` (closed_predicate.clj:134). -/
def extWritesOp (o : Op) : List (Nat × Val) :=
  if o.f == .init then o.value.map fun m => (m.k, m.v) else extWritesTxn o.value

/-- `ext-writes` (closed_predicate.clj:142); `none`: one value written twice (Elle throws). -/
def extWrites (h : List Op) : Option (List (Nat × List (Val × Nat))) :=
  (possible h).foldlM (fun ws o => (extWritesOp o).foldlM (fun ws (k, v) =>
    let kw := (ws.lookup k).getD []
    if (kw.lookup v).isSome then none else some (amPut ws k (amPut kw v o.index))) ws) []

/-- `all-versions` (closed_predicate.clj:191): `:init` replaces the map; a key's first write
adds an unborn version before it. -/
def allVersions (h : List Op) : List (Nat × List Val) :=
  (possible h).foldl (fun vs o =>
    if o.f == .init then o.value.map fun m => (m.k, [m.v])
    else o.value.foldl (fun vs m =>
      let conj (v : Val) := amPut vs m.k (((vs.lookup m.k).getD [.unborn]) ++ [v])
      match m.f with
      | .insert | .w => conj m.v
      | .delete => conj .dead
      | _ => vs) vs) []

def versionsOf (av : List (Nat × List Val)) (k : Nat) : List Val := (av.lookup k).getD []

/-- `version-before` (closed_predicate.clj:222): the version before the first match; with no
match, `loopr` returns its accumulator, the last version. -/
def versionBefore (vs : List Val) (target : Val) : Option Val := Id.run do
  let mut preceding : Option Val := none
  for v in vs do
    if v == target then return preceding
    preceding := some v
  return preceding

/-- `version-after` (closed_predicate.clj:235). `target = none` is `nil`. -/
def versionAfter (vs : List Val) (target : Option Val) : Option Val :=
  if target == some .unborn then
    match vs with
    | v0 :: v1 :: _ => if v0 == .unborn then some v1 else some v0
    | [v0] => if v0 == .unborn then none else some v0
    | [] => none
  else Id.run do
    let mut preceding : Option Val := none
    for v in vs do
      if preceding == target then return some v
      preceding := some v
    return none

/-- `versions-after` (closed_predicate.clj:263), as written: its unborn branch's value is
discarded, so the loop below answers for unborn too. -/
def versionsAfter (vs : List Val) (target : Val) : List Val := Id.run do
  let mut i := 0
  while i + 1 < vs.length do
    if vs[i]! == target then return vs.drop (i + 1)
    i := i + 1
  return []

/-- `versions-after` as its comment and unborn branch intend. -/
def versionsAfterIntended (vs : List Val) (target : Val) : List Val :=
  if target == .unborn then (if vs.head? == some .unborn then vs.drop 1 else vs)
  else versionsAfter vs target

/-- `version<` (closed_predicate.clj:285), as written: when the loop ends, `loopr` returns its
accumulator `found-a?`, so the answer is true whenever `a` is a version, wherever `b` is. -/
def versionLt (vs : List Val) (a b : Val) : Bool := Id.run do
  let mut found := false
  for v in vs do
    if found then
      if v == b then return true
    else if v == a then found := true
  return found

/-- `version<` fixed (round 2): `:elle/unborn` precedes every version (versions-after's docstring,
closed_predicate.clj:266: "Every version follows :elle/unborn"), and `b` must follow `a`. -/
def versionLtFixed (vs : List Val) (a b : Val) : Bool :=
  if a == .unborn then b != .unborn && vs.any (· == b) else Id.run do
    let mut found := false
    for v in vs do
      if found then
        if v == b then return true
      else if v == a then found := true
    return false

/-- `resolve-version` (closed_predicate.clj:301): `none` is `nil` (can't tell). -/
def resolveVersion (av : List (Nat × List Val)) (k : Nat) (v : Val) : Option Val :=
  if v == .nil then
    let vs := versionsOf av k
    let unborn := vs.head? == some .unborn
    let dead := vs.getLast? == some .dead
    if unborn && dead then none else if unborn then some .unborn else if dead then some .dead
    else some .unborn
  else some v

/-- `eval-pred` (closed_predicate.clj:321). -/
def evalPred (p : Pred) (v : Val) : Bool :=
  match v with
  | .unborn | .dead => false
  | .int i => match p with
    | .tru => true
    | .eq g => g == i
    | .mod m t => m != 0 && t == i % m
  | _ => match p with | .tru => true | _ => false

def readMap (m : Mop) : List (Nat × Val) := match m.v with | .kmap l => l | _ => []

/-- `pred-read-miss-cases` (closed_predicate.clj:342). -/
def predReadMissCases (av : List (Nat × List Val)) (h : List Op) : List Nat :=
  (oks h).flatMap fun o => (o.value.filter (·.f == .rp)).flatMap fun m =>
    av.filterMap fun (k, vs) =>
      if (readMap m).any (·.1 == k) then none
      else if vs.all (evalPred m.pred) then some o.index else none

/-- `version-set` (closed_predicate.clj:371). -/
def versionSet (av : List (Nat × List Val)) (m : Mop) : List (Nat × Val) :=
  av.foldl (fun vset (k, vs) =>
    if vset.any (·.1 == k) then vset
    else match vs.filter (fun v => !evalPred m.pred v) with
      | [] => vset ++ [(k, .unborn)]
      | [c] => vset ++ [(k, c)]
      | _ => vset) (readMap m)

def ewGet (ew : List (Nat × List (Val × Nat))) (k : Nat) (v : Val) : Option Nat :=
  (ew.lookup k).bind (·.lookup v)

structure Analysis' where
  av : List (Nat × List Val)
  ew : List (Nat × List (Val × Nat))
  /-- The intended `versions-after` (for a counterfactual run), or the one written. -/
  fixedVersionsAfter : Bool := false
  /-- `ww-graph`'s case over `(:insert :w :delete)` (counterfactual) or `(:insert :write :delete)`. -/
  fixedWrite : Bool := false
  /-- The RW explainer's `version<` fixed (`versionLtFixed`). -/
  fixedVersionLt : Bool := false
  /-- D21's fix: a predicate read's rows are item reads too. -/
  rowItems : Bool := false
  /-- D22's fix: the explainers' item paths read an `:ok` op's reads only. -/
  okReadsOnly : Bool := false

/-- An op's item reads: its `:r` mops, and with D21's fix its predicate reads' rows. -/
def itemReads (o : Op) (rows : Bool) : List (Nat × Val) :=
  o.value.flatMap fun m =>
    if m.f == .r then [(m.k, m.v)] else if rows && m.f == .rp then readMap m else []

/-- `rw-graph`, `wr-graph`, `ww-graph` and their explainers (closed_predicate.clj:423-678). -/
def graph (a : Analysis') (h : History) : Analysis := Id.run do
  let hl := h.toList
  let vsAfter := if a.fixedVersionsAfter then versionsAfterIntended else versionsAfter
  let mut grw : Graph := {}
  let mut gwr : Graph := {}
  let mut gww : Graph := {}
  for o in oks hl do
    for m in o.value do
      let items : List (Nat × Val) :=
        if m.f == .r then [(m.k, m.v)] else if a.rowItems && m.f == .rp then readMap m else []
      for (k, rv) in items do
        let v := resolveVersion a.av k rv
        if let some v' := versionAfter (versionsOf a.av k) v then
          if let some w := ewGet a.ew k v' then
            if w != o.index then grw := grw.link o.index w Rels.RW
        if let some v := v then
          if let some w := ewGet a.ew k v then
            if w != o.index then gwr := gwr.link w o.index Rels.WR
      match m.f with
      | .r => pure ()
      | .rp =>
        for (k, v) in versionSet a.av m do
          for v' in vsAfter (versionsOf a.av k) v do
            if xor' (evalPred m.pred v) (evalPred m.pred v') then
              if let some w := ewGet a.ew k v' then
                if w != o.index then grw := grw.link o.index w Rels.RWP
          if v != .unborn then
            if let some w := ewGet a.ew k v then
              if w != o.index then gwr := gwr.link w o.index Rels.WRP
      | _ => pure ()
  for o in possible hl do
    if o.f == .init then continue
    for m in o.value do
      let isWrite := m.f == .insert || m.f == .delete || (a.fixedWrite && m.f == .w)
      if isWrite then
        let v' := if m.f == .delete then Val.dead else m.v
        if let some v := versionBefore (versionsOf a.av m.k) v' then
          if let some w := ewGet a.ew m.k v then
            if w != o.index then gww := gww.link w o.index Rels.WW
  let op (i : Nat) : Option Op := h[i]?
  -- `version-sets` (closed_predicate.clj:413) caches the version sets of `:ok` transactions'
  -- predicate reads, by mop; the explainers look a mop up there, so an `:info` op's predicate
  -- read (rows `nil`) has none.
  let cached (m : Mop) : Bool := (oks hl).any fun o => o.f == .txn && o.value.any (· == m)
  let explainRw (x y : Nat) : Option Step := do
    let ox ← op x
    let oy ← op y
    let bw := extWritesOp oy
    let reads := if a.okReadsOnly && !ox.isOk then [] else itemReads ox a.rowItems
    let item := reads.findSome? fun (k, rv) =>
      let v := resolveVersion a.av k rv
      match versionAfter (versionsOf a.av k) v with
      | some v' => if bw.lookup k == some v' then some ({ type := "rw", key := some k } : Step) else none
      | none => none
    match item with
    | some s => some s
    | none => (ox.value.filter (fun m => m.f == .rp && cached m)).findSome? fun m =>
        let vset := versionSet a.av m
        bw.findSome? fun (k, v') => match vset.lookup k with
          | some v => if (if a.fixedVersionLt then versionLtFixed else versionLt) (versionsOf a.av k) v v' && xor' (evalPred m.pred v) (evalPred m.pred v')
                      then some { type := "rwp", key := some k, predicate := true } else none
          | none => none
  let explainWr (x y : Nat) : Option Step := do
    let ox ← op x
    let oy ← op y
    let ws := extWritesOp ox
    let reads := if a.okReadsOnly && !oy.isOk then [] else itemReads oy a.rowItems
    let item := reads.findSome? fun (k, rv) =>
      match resolveVersion a.av k rv with
      | some v => if ws.lookup k == some v then some ({ type := "wr", key := some k } : Step) else none
      -- `(= v (get writes k))` with v nil and k unwritten is true in Clojure
      | none => if (ws.lookup k).isNone then some ({ type := "wr", key := some k } : Step) else none
    match item with
    | some s => some s
    | none => (oy.value.filter (fun m => m.f == .rp && cached m)).findSome? fun m =>
        (versionSet a.av m).findSome? fun (k, v) =>
          if ws.lookup k == some v then some { type := "wrp", key := some k } else none
  let explainWw (x y : Nat) : Option Step := do
    let ox ← op x
    let oy ← op y
    let aw := extWritesOp ox
    (extWritesOp oy).findSome? fun (k, v') =>
      match versionBefore (versionsOf a.av k) v' with
      | some v => if aw.lookup k == some v then some { type := "ww", key := some k } else none
      | none => none
  return combine [{ graph := gww, explain := explainWw }, { graph := gwr, explain := explainWr },
                  { graph := grw, explain := explainRw }] |> fun c =>
    -- `graph` combines ww, wr, rw (closed_predicate.clj:680); the explainers in that order.
    c

/-- `elle.closed-predicate/check` (closed_predicate.clj:689) up to `result-map`. -/
def analyze (h : History) (extra : Extra) (o : Order := {}) (fixedVersionsAfter fixedWrite : Bool := false)
    (cuts : List (Nat × Nat) := []) (fixedVersionLt : Bool := false) (rowItems okReadsOnly d20 : Bool := false) :
    Except String Anomalies := do
  let hl := h.toList
  let av := allVersions hl
  let some ew := extWrites hl | throw "multiple-writes-of-same-value"
  let miss := predReadMissCases av hl
  let an := combine ([graph { av, ew, fixedVersionsAfter, fixedWrite, fixedVersionLt, rowItems, okReadsOnly } h] ++
    extraAnalysesOf extra h)
  let m ← cyclesE an o cuts d20
  return addCases m "predicate-read-miss" (miss.map fun i => Case.other [i])

/-- The analysis with the options' fixes: the deployed ones (`cpFixed`: D9, D10, D11) and
round 3's (D20, D21, D22). -/
def analyzeOpts (opts : Opts) (h : History) (extra : Extra) (o : Order := {}) : Except String Anomalies :=
  analyze h extra o opts.cpFixed opts.cpFixed opts.cuts opts.cpFixed opts.fixD21 opts.fixD22 opts.fixD20

def check (opts : Opts) (h : History) (fixedVersionsAfter fixedWrite : Bool := false)
    (fixedVersionLt : Bool := false) : Outcome :=
  match analyze h (additionalGraphs opts) {} (fixedVersionsAfter || opts.cpFixed) (fixedWrite || opts.cpFixed)
      opts.cuts (fixedVersionLt || opts.cpFixed) opts.fixD21 opts.fixD22 opts.fixD20 with
  | .error e => .thrown e
  | .ok m => .result (resultMap opts m)

end Elle.ClosedPredicate
