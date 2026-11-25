/-!
# Hash orders, replicated

Two iteration orders decide which cycle Elle reports first and which read it takes as a key's
longest:

- Bifurcan's `Map` (a CHAMP trie, MapNodes.java) over ops hashed by `index-hash`
  (`Murmur3/hashLong` of the index, history.clj:267), mixed by `Map.keyHash` (Map.java:316):
  a node's own entries in bit order, then its subnodes in bit order.
- Clojure's `PersistentHashSet` (a HAMT) over read vectors hashed by `hasheq`
  (`Murmur3.hashOrdered`): entries and subnodes interleaved in bit order.
-/

namespace Elle.Hash

def mask32 : Nat := 0xFFFFFFFF

def u32 (n : Nat) : UInt32 := UInt32.ofNat (n % 4294967296)

def rotl (x : UInt32) (r : UInt32) : UInt32 := (x <<< r) ||| (x >>> (32 - r))

def C1 : UInt32 := 0xcc9e2d51
def C2 : UInt32 := 0x1b873593

def mixK1 (k : UInt32) : UInt32 := (rotl (k * C1) 15) * C2
def mixH1 (h k : UInt32) : UInt32 := (rotl (h ^^^ k) 13) * 5 + 0xe6546b64
def fmix (h : UInt32) (len : UInt32) : UInt32 :=
  let h := h ^^^ len
  let h := h ^^^ (h >>> 16)
  let h := h * 0x85ebca6b
  let h := h ^^^ (h >>> 13)
  let h := h * 0xc2b2ae35
  h ^^^ (h >>> 16)

/-- `clojure.lang.Murmur3/hashLong` of a long given as an integer. -/
def hashLong (i : Int) : UInt32 :=
  if i == 0 then 0 else
  let n : Nat := (i % 18446744073709551616).toNat
  let low := u32 n
  let high := u32 (n / 4294967296)
  let h := mixH1 0 (mixK1 low)
  let h := mixH1 h (mixK1 high)
  fmix h 8

/-- `Murmur3.hashOrdered` of a vector of longs (Clojure's `hasheq` of a vector). -/
def hashVector (l : List Int) : UInt32 :=
  let h := l.foldl (fun h x => 31 * h + hashLong x) (1 : UInt32)
  fmix (mixH1 0 (mixK1 h)) (u32 l.length)

/-- Bifurcan's `Map.keyHash` of an `index-hash` (an int widened to a long). -/
def bifurcanKeyHash (indexHash : UInt32) : UInt32 :=
  let h := indexHash
  -- (int) ((hash64 >> 32) ^ hash64) of a sign-extended int: h, or ~h when negative
  let h := if h ≥ 0x80000000 then ~~~h else h
  let h := h ^^^ ((h >>> 20) ^^^ (h >>> 12))
  h ^^^ ((h >>> 7) ^^^ (h >>> 4))

def chunk (h : UInt32) (shift : Nat) : Nat := ((h >>> (u32 shift)) &&& 31).toNat

/-- CHAMP order (MapNodes iterator): a node's entries by bit, then its subnodes by bit. -/
partial def champOrder {α : Type} (items : List (α × UInt32)) (shift : Nat := 0) : List α :=
  if shift ≥ 32 then items.map (·.1) else
  let cs := (List.range 32).map fun c => (c, items.filter fun (_, h) => chunk h shift == c)
  let entries := cs.filterMap fun (_, g) => match g with | [x] => some x.1 | _ => none
  let nodes := cs.flatMap fun (_, g) => if g.length ≥ 2 then champOrder g (shift + 5) else []
  entries ++ nodes

/-- HAMT order (Clojure's BitmapIndexedNode): entries and subnodes interleaved by bit. -/
partial def hamtOrder {α : Type} (items : List (α × UInt32)) (shift : Nat := 0) : List α :=
  if shift ≥ 32 then items.map (·.1) else
  (List.range 32).flatMap fun c =>
    let g := items.filter fun (_, h) => chunk h shift == c
    match g with
    | [] => []
    | [x] => [x.1]
    | _ => hamtOrder g (shift + 5)

/-- The order Bifurcan iterates a set of ops (by index) in. -/
def opsOrder (ops : List Nat) : List Nat :=
  champOrder (ops.map fun i => (i, bifurcanKeyHash (hashLong i)))

/-- The order Clojure iterates a hash set of read vectors in. -/
def vectorsOrder (vs : List (List Int)) : List (List Int) :=
  hamtOrder (vs.map fun v => (v, hashVector v))

end Elle.Hash
