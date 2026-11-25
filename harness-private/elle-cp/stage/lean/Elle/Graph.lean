import Elle.Basic
import Elle.Hash

/-!
# Relationships and graphs

`elle.BitRels` (BitRels.java) as a byte of bits, and the Bifurcan op digraphs of `elle.graph`
(graph.clj) as a vertex list and an edge list with a BitRels value per edge.

Bifurcan iterates vertices and successors in hash order (`Murmur3/hashLong` of the op index,
history.clj:267). That order is not replicated: an `Order` (a rank per vertex) stands for it, and
the searches take it as a decision, so a verdict that depends on it shows up.
-/

namespace Elle

/-- BitRels.java:17-25. -/
abbrev Rels := Nat
namespace Rels
def NONE : Rels := 0x00
def WW : Rels := 0x01
def WR : Rels := 0x02
def RW : Rels := 0x04
def WWP : Rels := 0x08
def WRP : Rels := 0x10
def RWP : Rels := 0x20
def PROCESS : Rels := 0x40
def REALTIME : Rels := 0x80
/-- BitRels.java:27. -/
def ANY_RW : Rels := RW ||| RWP
/-- BitRels.java:30: in ascending bit order. -/
def ALL : List Rels := [WW, WR, RW, WWP, WRP, RWP, PROCESS, REALTIME]
def NAMES : List String := ["ww", "wr", "rw", "wwp", "wrp", "rwp", "process", "realtime"]
def union (a b : Rels) : Rels := a ||| b
def inter (a b : Rels) : Rels := a &&& b
def diff (a b : Rels) : Rels := a &&& (0xFF ^^^ b)
def isAnyRW (r : Rels) : Bool := inter r ANY_RW != 0
/-- BitRels.java:83: true when any predicate bit is set (its comment says "purely"). -/
def isPredicate (r : Rels) : Bool := inter r (WWP ||| WRP ||| RWP) != 0
def names (r : Rels) : List String :=
  (ALL.zip NAMES).filterMap fun (b, n) => if inter r b != 0 then some n else none
/-- The keyword of a singleton rel (`.toClojure`, first element). -/
def name (r : Rels) : String := (names r).headD "none"
end Rels

/-- A directed graph over op indices with a BitRels value per edge. -/
structure Graph where
  verts : List Nat := []
  edges : List (Nat × Nat × Rels) := []
  deriving Inhabited, Repr

namespace Graph

def addVertex (g : Graph) (v : Nat) : Graph :=
  if g.verts.contains v then g else { g with verts := g.verts ++ [v] }

/-- `g/link` with a relationship, unioned (graph.clj:156). -/
def link (g : Graph) (a b : Nat) (r : Rels) : Graph :=
  let g := (g.addVertex a).addVertex b
  if g.edges.any (fun (x, y, _) => x == a && y == b) then
    { g with edges := g.edges.map fun (x, y, r') => if x == a && y == b then (x, y, r' ||| r) else (x, y, r') }
  else { g with edges := g.edges ++ [(a, b, r)] }

/-- `g/unlink`: removes the edge, keeps the vertices (Bifurcan `unlink`). -/
def unlink (g : Graph) (a b : Nat) : Graph :=
  { g with edges := g.edges.filter fun (x, y, _) => !(x == a && y == b) }

def edge (g : Graph) (a b : Nat) : Rels :=
  match g.edges.find? (fun (x, y, _) => x == a && y == b) with
  | some (_, _, r) => r
  | none => 0

def hasEdge (g : Graph) (a b : Nat) : Bool := g.edges.any fun (x, y, _) => x == a && y == b

def size (g : Graph) : Nat := g.verts.length

/-- `g/digraph-union` (graph.clj:147): vertices and edges merged, rels unioned. -/
def union (a b : Graph) : Graph :=
  let g := b.verts.foldl addVertex a
  b.edges.foldl (fun g (x, y, r) => g.link x y r) g

/-- `g/project-rels` (graph.clj:258): a fresh graph of the edges whose rels meet `target`. -/
def project (target : Rels) (g : Graph) : Graph :=
  g.edges.foldl (fun g' (x, y, r) =>
    let r' := Rels.inter target r
    if r' == 0 then g' else g'.link x y r') {}

/-- `bg/select`: the subgraph induced by `s`. -/
def select (g : Graph) (s : List Nat) : Graph :=
  { verts := g.verts.filter s.contains,
    edges := g.edges.filter fun (x, y, _) => s.contains x && s.contains y }

/-- `g/link-all-to-all` (graph.clj:198). -/
def linkAllToAll (g : Graph) (xs ys : List Nat) (r : Rels) : Graph :=
  xs.foldl (fun g x => ys.foldl (fun g y => g.link x y r) g) g

/-- `g/remove-self-edges` (graph.clj:271). -/
def removeSelfEdges (g : Graph) (nodes : List Nat) : Graph := nodes.foldl (fun g n => g.unlink n n) g

/-- `g/sequential-composition` with an initial graph (graph.clj:399): x -> z when x -> y in a
and y -> z in b, linked with `BitRels/NONE`. -/
def seqComposition (a b : Graph) (init : Graph) : Graph :=
  a.edges.foldl (fun c (x, y, _) =>
    if b.verts.contains y then
      (b.edges.filter (·.1 == y)).foldl (fun c (_, z, _) => c.link x z Rels.NONE) c
    else c) init

/-- `g/sequential-extension` (graph.clj:424): a ∪ (a ; b). -/
def seqExtension (a b : Graph) : Graph := seqComposition a b a

end Graph

/-- An iteration order for sets of ops: by default Bifurcan's (`Hash.opsOrder`), which the
replica computes exactly; another order stands for a history whose ops were indexed otherwise. -/
structure Order where
  iter : List Nat → List Nat := Hash.opsOrder

def Order.ofRank (rank : Nat → Nat) : Order :=
  { iter := fun l => l.mergeSort fun a b => decide (rank a < rank b) || (rank a == rank b && decide (a ≤ b)) }

def Order.sort (o : Order) (l : List Nat) : List Nat := o.iter l

/-- Successors of `v` in iteration order. -/
def Graph.out (g : Graph) (o : Order) (v : Nat) : List Nat :=
  o.sort ((g.edges.filter (·.1 == v)).map (·.2.1))

def Graph.vertsIn (g : Graph) (o : Order) : List Nat := o.sort g.verts

/-! ## Tarjan's SCCs, as Bifurcan writes them (Graphs.java:469-545) -/

/-- `Graphs/stronglyConnectedComponents g includeSingletons`, iterative as written: a path, a
stack, an iterator per path element. Components come back sorted, for a canonical order. -/
def tarjan (g : Graph) (o : Order) (includeSingletons : Bool) : List (List Nat) := Id.run do
  -- state: vertex -> (index, lowlink, onStack)
  let mut st : List (Nat × (Nat × Nat × Bool)) := []
  let mut stack : List Nat := []        -- top at the head
  let mut path : List Nat := []         -- top at the head
  let mut branches : List (List Nat) := []  -- remaining iterators, top at the head
  let mut result : List (List Nat) := []
  let fuel := 4 * (g.verts.length + g.edges.length + 4) * (g.verts.length + 2)
  for seed in g.vertsIn o do
    if (st.lookup seed).isSome then continue
    branches := [seed] :: branches
    let mut go := true
    let mut f := fuel
    while go && f > 0 do
      f := f - 1
      match branches with
      | (w :: rest) :: bs =>
        branches := rest :: bs
        match st.lookup w with
        | none =>
          let i := st.length
          st := st ++ [(w, (i, i, true))]
          stack := w :: stack
          path := w :: path
          branches := g.out o w :: branches
        | some (wi, _, wOn) =>
          if wOn then
            match path with
            | v :: _ =>
              st := st.map fun (x, (i, l, on)) => if x == v then (x, (i, min l wi, on)) else (x, (i, l, on))
            | [] => pure ()
      | [] :: bs =>
        branches := bs
        match path with
        | w :: ps =>
          path := ps
          let (wi, wl, _) := (st.lookup w).getD (0, 0, false)
          match ps with
          | v :: _ =>
            st := st.map fun (x, (i, l, on)) => if x == v then (x, (i, min l wl, on)) else (x, (i, l, on))
          | [] => pure ()
          if wl == wi then
            if !includeSingletons && stack.head? == some w then
              stack := stack.drop 1
              st := st.map fun (x, (i, l, on)) => if x == w then (x, (i, l, false)) else (x, (i, l, on))
            else
              let mut group : List Nat := []
              let mut more := true
              while more do
                match stack with
                | x :: s =>
                  stack := s
                  group := x :: group
                  st := st.map fun (y, (i, l, on)) => if y == x then (y, (i, l, false)) else (y, (i, l, on))
                  if x == w then more := false
                | [] => more := false
              result := result ++ [sortNat group]
        | [] => pure ()
        if path.isEmpty then go := false
      | [] => go := false
  return result

/-- `g/strongly-connected-components` (graph.clj:373): components bigger than one vertex. -/
def sccs (g : Graph) (o : Order := {}) : List (List Nat) := tarjan g o false

/-! ## A specification for SCCs: mutual reachability -/

/-- Vertices reachable from `v` in one or more steps. -/
def reach (g : Graph) (v : Nat) : List Nat := Id.run do
  let mut seen : List Nat := []
  let mut frontier : List Nat := ((g.edges.filter (·.1 == v)).map (·.2.1))
  let mut fuel := g.verts.length + 2
  while !frontier.isEmpty && fuel > 0 do
    fuel := fuel - 1
    let new := frontier.filter (!seen.contains ·)
    seen := seen ++ dedup new
    frontier := dedup (new.flatMap fun x => (g.edges.filter (·.1 == x)).map (·.2.1))
  return seen

/-- The components of mutual reachability, each sorted, those of one vertex kept when asked. -/
def sccSpec (g : Graph) (includeSingletons : Bool) : List (List Nat) := Id.run do
  let rs := g.verts.map fun v => (v, reach g v)
  let mut done : List Nat := []
  let mut out : List (List Nat) := []
  for v in g.verts do
    if done.contains v then continue
    let rv := (rs.lookup v).getD []
    let comp := sortNat (v :: g.verts.filter fun u => u != v && rv.contains u && ((rs.lookup u).getD []).contains v)
    done := done ++ comp
    if comp.length > 1 || includeSingletons then out := out ++ [comp]
  return out

def canonSccs (l : List (List Nat)) : List (List Nat) :=
  (l.map sortNat).mergeSort fun a b => decide (a.headD 0 ≤ b.headD 0)

/-- Does the graph have a cycle (including a self-loop)? -/
def hasCycle (g : Graph) : Bool := g.verts.any fun v => (reach g v).contains v

end Elle
