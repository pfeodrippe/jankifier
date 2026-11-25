/-!
# Histories, as jepsen.history 0.1.9 and jepsen.txn 0.1.3 hold them

An operation (`jepsen.history/Op`, history.clj:259) is a record of `index`, `time`, `type`,
`process`, `f`, `value`. Graph vertices are operations compared by index
(`index=`/`index-hash`, history.clj:252-268), so a vertex here is the operation's index.

Values follow Clojure's `=`: `nil`, an integer, or a vector of integers (a list-append read),
or a map (closed-predicate init and predicate reads, and core's monotonic-key ops).
-/

namespace Elle

/-- A Clojure value as Elle's workloads use them. -/
inductive Val where
  | nil
  | int (i : Int)
  | list (l : List Int)
  /-- A map of keys to values: `{k v ...}` (closed-predicate `:rp` reads and `:init`). -/
  | kmap (m : List (Nat × Val))
  /-- `:elle/unborn` and `:elle/dead` (closed_predicate.clj:94). -/
  | unborn
  | dead
  deriving Repr, Inhabited

mutual
def Val.beq : Val → Val → Bool
  | .nil, .nil => true
  | .int a, .int b => a == b
  | .list a, .list b => a == b
  | .kmap a, .kmap b => Val.beqMap a b
  | .unborn, .unborn => true
  | .dead, .dead => true
  | _, _ => false
def Val.beqMap : List (Nat × Val) → List (Nat × Val) → Bool
  | [], [] => true
  | (k, v) :: r, (k', v') :: r' => k == k' && Val.beq v v' && Val.beqMap r r'
  | _, _ => false
end

instance : BEq Val := ⟨Val.beq⟩

/-- Micro-operation functions. -/
inductive F where
  | r | append | w | insert | delete | rp
  deriving Repr, BEq, Inhabited, DecidableEq

/-- A closed-predicate predicate (closed_predicate.clj:41-50): `:true`, `[:= n]`, `[:mod m t]`. -/
inductive Pred where
  | tru
  | eq (n : Int)
  | mod (m : Int) (t : Int)
  deriving Repr, BEq, Inhabited, DecidableEq

/-- A micro-op `[f k v]`. For `:rp`, `pred` holds the predicate and `v` the read map. -/
structure Mop where
  f : F
  k : Nat
  v : Val
  pred : Pred := .tru
  deriving Repr, Inhabited, BEq

inductive OpType where
  | invoke | ok | fail | info
  deriving Repr, BEq, Inhabited, DecidableEq

/-- An operation's `:f`. -/
inductive Fn where
  | txn | init
  deriving Repr, BEq, Inhabited, DecidableEq

structure Op where
  index : Nat
  time : Int := -1
  type : OpType
  process : Nat
  f : Fn := .txn
  value : List Mop
  deriving Repr, Inhabited

/-- A history: its operations in order, `index` = position. -/
abbrev History := Array Op

def Op.isOk (o : Op) : Bool := o.type == .ok
def Op.isInfo (o : Op) : Bool := o.type == .info
def Op.isFail (o : Op) : Bool := o.type == .fail
def Op.isInvoke (o : Op) : Bool := o.type == .invoke

/-- `h/possible` (history.clj:1217): `:ok` or `:info` ops. -/
def possible (h : List Op) : List Op := h.filter fun o => o.isOk || o.isInfo
/-- `h/oks` (history.clj:1202). -/
def oks (h : List Op) : List Op := h.filter Op.isOk

/-- The pair index (`pair-index-fold`, history.clj:421): an invocation is paired with the next
completion of its process. Returns (index, partner index) pairs. -/
def pairIndex (h : History) : List (Nat × Nat) := Id.run do
  let mut running : List (Nat × Nat) := []   -- process -> invoke index
  let mut pairs : List (Nat × Nat) := []
  for o in h do
    if o.isInvoke then
      running := (o.process, o.index) :: running.filter (·.1 != o.process)
    else
      match running.lookup o.process with
      | some i =>
        pairs := (i, o.index) :: (o.index, i) :: pairs
        running := running.filter (·.1 != o.process)
      | none => pure ()
  return pairs

/-- `h/completion` (history.clj:572). -/
def completion (h : History) (pairs : List (Nat × Nat)) (inv : Op) : Option Op :=
  (pairs.lookup inv.index).bind fun i => h[i]?

/-- `h/invocation` (history.clj:578). -/
def invocation (h : History) (pairs : List (Nat × Nat)) (cmp : Op) : Option Op :=
  (pairs.lookup cmp.index).bind fun i => h[i]?

/-- Association-list helpers (Clojure maps). Updates keep the first position of a key. -/
def amGet {α β : Type} [BEq α] (m : List (α × β)) (k : α) : Option β := m.lookup k

def amPut {α β : Type} [BEq α] (m : List (α × β)) (k : α) (v : β) : List (α × β) :=
  if m.any (·.1 == k) then m.map fun (k', v') => if k' == k then (k', v) else (k', v')
  else m ++ [(k, v)]

def amUpdate {α β : Type} [BEq α] (m : List (α × β)) (k : α) (d : β) (f : β → β) : List (α × β) :=
  amPut m k (f ((amGet m k).getD d))

/-- `jepsen.txn/ext-reads` (txn.clj:51): the first mop on each key, when it is a read. -/
def extReads (txn : List Mop) : List (Nat × Val) := Id.run do
  let mut ext : List (Nat × Val) := []
  let mut ignore : List Nat := []
  for m in txn do
    if !(m.f != .r || ignore.contains m.k) then ext := amPut ext m.k m.v
    ignore := if ignore.contains m.k then ignore else ignore ++ [m.k]
  return ext

/-- `jepsen.txn/ext-writes` (txn.clj:66): the last non-read mop on each key. -/
def extWrites (txn : List Mop) : List (Nat × Val) := Id.run do
  let mut ext : List (Nat × Val) := []
  for m in txn do
    if m.f != .r then ext := amPut ext m.k m.v
  return ext

def dedup {α : Type} [BEq α] (l : List α) : List α :=
  l.foldl (fun acc x => if acc.contains x then acc else acc ++ [x]) []

def sortNat (l : List Nat) : List Nat := l.mergeSort (fun a b => decide (a ≤ b))

/-- The last element of a list. -/
def List.lastOpt {α : Type} : List α → Option α
  | [] => none
  | l => l.getLast?

end Elle
