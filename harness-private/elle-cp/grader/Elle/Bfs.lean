import Elle.Graph

/-!
# Cycle search (elle/bfs.clj, elle/BFSPath.java)

A path's state machine as BFSPath.java writes it, and the breadth-first search of bfs.clj:
shells of paths from each vertex, loops checked at the start of each shell, a loop with a tail
trimmed and searched again in the subgraph of its loop.
-/

namespace Elle

inductive RWMode where
  | none | single | nonadjacentFree | nonadjacentTaken
  deriving Repr, DecidableEq, Inhabited

/-- A cycle-anomaly spec (txn.clj:543-568). `required` is a list of BitRels sets. -/
structure Spec where
  rels : Rels
  nonadjacent : Option Rels := none
  single : Option Rels := none
  multiple : Option Rels := none
  required : List Rels := []
  type : Option String := none
  deriving Repr, Inhabited

structure BFSPath where
  legal : Rels
  /-- Up to four wanted BitRels, as the packed int's bytes (BFSPath.java:85). -/
  want : List Rels
  wantRW : Nat
  rwMode : RWMode
  lastIndex : Int
  indexSet : List Nat
  ops : List Nat
  deriving Repr, Inhabited

namespace BFSPath

/-- BFSPath.java:58. -/
def wantMask (p : BFSPath) : Rels := p.want.foldl (· ||| ·) 0
def wantZero (p : BFSPath) : Bool := p.want.all (· == 0)

/-- BFSPath.java:68: zero the first wanted set that meets `rel`. -/
def checkOff (want : List Rels) (rel : Rels) : List Rels :=
  match want.findIdx? (fun w => Rels.inter w rel != 0) with
  | some i => want.set i 0
  | none => want

/-- BFSPath.java:117. -/
def isValid (p : BFSPath) : Bool := p.wantZero && p.wantRW == 0 && p.rwMode != .nonadjacentTaken

/-- BFSPath.java:124. -/
def isLoop (p : BFSPath) : Bool := p.lastIndex ≥ 0 && p.indexSet.contains p.lastIndex.toNat

/-- BFSPath.java:130. -/
def start (p : BFSPath) (i : Nat) : BFSPath := { p with lastIndex := i, ops := p.ops ++ [i] }

/-- BFSPath.java:135-200. -/
def stepRel (p : BFSPath) (rel : Rels) (i : Nat) : Option BFSPath :=
  let isRw := Rels.isAnyRW rel
  let idx := if p.lastIndex ≥ 0 then p.indexSet ++ [p.lastIndex.toNat] else p.indexSet
  if Rels.inter rel p.legal != 0 then
    let wantRW := if isRw then (if p.wantRW == 0 then 0 else p.wantRW - 1) else p.wantRW
    let mode := match p.rwMode with
      | .nonadjacentTaken => .nonadjacentFree
      | m => m
    some { p with want := checkOff p.want rel, wantRW, rwMode := mode, lastIndex := i,
                  indexSet := idx, ops := p.ops ++ [i] }
  else if isRw then
    match p.rwMode with
    | .none => none
    | .single => some { p with want := checkOff p.want rel, wantRW := 0, rwMode := .none,
                               lastIndex := i, indexSet := idx, ops := p.ops ++ [i] }
    | .nonadjacentFree =>
      let wantRW := if p.wantRW == 0 then 0 else p.wantRW - 1
      some { p with want := checkOff p.want rel, wantRW, rwMode := .nonadjacentTaken,
                    lastIndex := i, indexSet := idx, ops := p.ops ++ [i] }
    | .nonadjacentTaken => none
  else none

/-- BFSPath.java:204-292. -/
def step (p : BFSPath) (edge : Rels) (i : Nat) : List BFSPath := Id.run do
  let rwMask : Rels :=
    if 0 < p.wantRW || p.rwMode == .single || p.rwMode == .nonadjacentFree then Rels.ANY_RW else 0
  let wantMask := Rels.diff p.wantMask rwMask
  let legalMask := Rels.diff (Rels.diff p.legal rwMask) wantMask
  let mut paths : List BFSPath := []
  let rwRels := Rels.inter edge rwMask
  if rwRels != 0 then
    for b in Rels.ALL do
      let rel := Rels.inter rwRels b
      if rel != 0 then
        if let some q := p.stepRel rel i then paths := paths ++ [q]
  if 0 < p.wantRW && p.ops.length == 1 then return paths
  let wantRels := Rels.inter edge wantMask
  if wantRels != 0 then
    for b in Rels.ALL do
      let rel := Rels.inter wantRels b
      if rel != 0 then
        if let some q := p.stepRel rel i then paths := paths ++ [q]
  if !p.wantZero && p.ops.length == 1 then return paths
  let legalRels := Rels.inter edge legalMask
  if legalRels != 0 then
    for b in Rels.ALL do
      let rel := Rels.inter legalRels b
      if rel != 0 then
        if let some q := p.stepRel rel i then
          return paths ++ [q]
  return paths

end BFSPath

/-- `spec->path` (bfs.clj:32). -/
def specToPath (s : Spec) : BFSPath :=
  let wantRW := if s.single.isSome then 1 else if s.multiple.isSome then 2 else 0
  let mode := match s.nonadjacent with
    | none => if (s.single.map Rels.isAnyRW).getD false then RWMode.single else RWMode.none
    | some _ => RWMode.nonadjacentFree
  { legal := s.rels, want := (dedup s.required).take 4, wantRW, rwMode := mode,
    lastIndex := -1, indexSet := [], ops := [] }

/-- `tail?` (bfs.clj:27). -/
def BFSPath.tail (p : BFSPath) : Bool := p.lastIndex != (p.ops.headD 0 : Int)

/-- `expand-paths` (bfs.clj:73). -/
def expandPaths (g : Graph) (o : Order) (paths : List BFSPath) : List BFSPath :=
  paths.flatMap fun p =>
    match p.ops.getLast? with
    | none => []
    | some v => (g.out o v).flatMap fun v' => p.step (g.edge v v') v'

mutual
/-- `search-from-op` (bfs.clj:122): shells of paths from `op`; at each shell's start, a valid loop
without a tail is the cycle, a valid loop with a tail is trimmed, other loops are dropped. -/
partial def searchFromOp (g : Graph) (o : Order) (init : BFSPath) (op : Nat) : Option (List Nat) := Id.run do
  let mut paths : List BFSPath := [init.start op]
  let mut fuel := g.verts.length + 2
  while !paths.isEmpty && fuel > 0 do
    fuel := fuel - 1
    let mut kept : List BFSPath := []
    for p in paths do
      if p.isLoop then
        if p.isValid then
          if !p.tail then return some p.ops
          else
            match trimLoop g o init p with
            | some c => return some c
            | none => pure ()
      else kept := kept ++ [p]
    paths := expandPaths g o kept
  return none

/-- `trim-loop` (bfs.clj:96): the loop from the first visit of its pin, searched again in the
subgraph of its vertices. -/
partial def trimLoop (g : Graph) (o : Order) (init : BFSPath) (p : BFSPath) : Option (List Nat) :=
  let pin := p.ops.getLast?.getD 0
  let pinIndex := (p.ops.findIdx? (· == pin)).getD 0
  let trimmed := p.ops.drop pinIndex
  let g' := g.select trimmed
  trimmed.findSome? fun v => searchFromOp g' o init v
end

/-- `bfs/search` (bfs.clj:157). -/
def bfsSearch (g : Graph) (o : Order) (s : Spec) : Option (List Nat) :=
  let init := specToPath s
  (g.vertsIn o).findSome? fun v => searchFromOp g o init v

end Elle
