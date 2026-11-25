import Elle.Basic

/-!
# Random closed-predicate histories

A deterministic generator (splitmix64, seeded by a number) of small histories in the shape of
`elle.closed-predicate/gen` (closed_predicate.clj:740): an `:init` op over some of the keys, then
transactions of `[:r k v]`, `[:rp pred {k v ..}]`, `[:w k v]`, `[:insert k v]` and `[:delete k]`
mops, run by 1 to 3 threads, each completing `:ok`, `:fail` or `:info`. Unlike Elle's generator, a
key may be mutated more than once.

Every write of a key gets a value no other write of that key has (Elle throws on a value written
twice, closed_predicate.clj:142); a second delete of a key by `:ok`/`:info` ops (`:elle/dead`
written twice) is let through now and then, so that the exception is exercised too.

Reads are filled in from an execution: the `:ok` and `:info` transactions take effect in the order
they complete (the checker's own version order), an `:info` one with probability 1/2. A
transaction reads, by mode:
- consistent: the state just before its own completion, plus its own earlier writes;
- mixed: each read either consistent, or the state at a random cut of the execution (the one
  before `:init` included), or garbage;
- chaos (about one history in ten): every read garbage: `nil`, any value ever written to the key,
  or a value nobody wrote; predicate rows from a random cut with a row dropped or added.
-/

namespace Grade.Gen

open Elle

abbrev G := StateM UInt64

/-- splitmix64. -/
def next : G UInt64 := modifyGet fun (s : UInt64) =>
  let s' : UInt64 := s + 0x9E3779B97F4A7C15
  let z : UInt64 := (s' ^^^ (s' >>> 30)) * 0xBF58476D1CE4E5B9
  let z : UInt64 := (z ^^^ (z >>> 27)) * 0x94D049BB133111EB
  ((z ^^^ (z >>> 31) : UInt64), s')

/-- A number in `[0, n)` (0 when `n = 0`). -/
def nat (n : Nat) : G Nat := do
  if n == 0 then return 0
  return (← next).toNat % n

/-- True with probability `num / den`. -/
def chance (num den : Nat) : G Bool := return (← nat den) < num

/-- An index into `ws`, drawn by weight. -/
def weighted (ws : List Nat) : G Nat := do
  let mut x ← nat (ws.foldl (· + ·) 0)
  let mut i := 0
  for w in ws do
    if x < w then return i
    x := x - w
    i := i + 1
  return 0

def pick {α : Type} [Inhabited α] (l : List α) : G α := return l[← nat l.length]!

/-- `eval-pred` on a stored value: unborn and dead (absent or `.dead`) never match. -/
def evalPred (p : Pred) : Val → Bool
  | .int i => match p with
    | .tru => true
    | .eq n => n == i
    | .mod m t => m != 0 && t == i % m
  | _ => false

/-- A database state: key -> `.int v` or `.dead`; an absent key is unborn. -/
abbrev State := List (Nat × Val)

def applyMop (st : State) (m : Mop) : State :=
  match m.f with
  | .w | .insert => amPut st m.k m.v
  | .delete => amPut st m.k .dead
  | _ => st

def readKey (st : State) (k : Nat) : Val :=
  match st.lookup k with
  | some (.int i) => .int i
  | _ => .nil

/-- The rows a predicate read returns: the live keys whose value matches, by key. -/
def rows (st : State) (p : Pred) (keys : Nat) : List (Nat × Val) :=
  (List.range keys).filterMap fun k => match st.lookup k with
    | some (.int i) => if evalPred p (.int i) then some (k, .int i) else none
    | _ => none

def genPred : G Pred := do
  match ← nat 3 with
  | 0 => return .tru
  | 1 => return .eq (Int.ofNat (← nat 4))
  | _ =>
    let m := 2 + (← nat 2)
    return .mod (Int.ofNat m) (Int.ofNat (← nat m))

structure Txn where
  status : OpType
  thread : Nat
  /-- As invoked: reads have `v := .nil`. -/
  mops : List Mop
  deriving Inhabited

/-- The transactions, values unique per write. -/
def genTxns (keys threads : Nat) : G (Array Txn) := do
  let n := 2 + (← nat 5)
  let mut nextV : Int := 2
  let mut deleted : List Nat := []
  let mut txs : Array Txn := #[]
  for _ in List.range n do
    let status := match ← weighted [8, 1, 1] with
      | 1 => OpType.fail
      | 2 => OpType.info
      | _ => OpType.ok
    let thread ← nat threads
    let m := 1 + (← nat 3)
    let mut mops : List Mop := []
    for _ in List.range m do
      let k ← nat keys
      match ← weighted [3, 2, 2, 1, 1] with
      | 0 => mops := mops ++ [{ f := .r, k, v := .nil }]
      | 1 =>
        let pred ← genPred
        mops := mops ++ [{ f := .rp, k := 0, v := .nil, pred }]
      | 2 =>
        mops := mops ++ [{ f := .w, k, v := .int nextV }]
        nextV := nextV + 1
      | 3 =>
        mops := mops ++ [{ f := .insert, k, v := .int nextV }]
        nextV := nextV + 1
      | _ =>
        if status != .fail && deleted.contains k && !(← chance 1 20) then
          mops := mops ++ [{ f := .w, k, v := .int nextV }]
          nextV := nextV + 1
        else
          mops := mops ++ [{ f := .delete, k, v := .nil }]
          if status != .fail && !deleted.contains k then deleted := deleted ++ [k]
    txs := txs.push { status, thread, mops }
  return txs

/-- Invocation and completion events `(txn, completes?)`: each thread runs its transactions in
order; at each step a random thread with work left invokes its next one or completes its open
one. -/
def schedule (txs : Array Txn) (threads : Nat) : G (List (Nat × Bool)) := do
  let mut queues : Array (List Nat) := (List.range threads).toArray.map fun t =>
    (List.range txs.size).filter fun i => txs[i]!.thread == t
  let mut open_ : Array (Option Nat) := Array.replicate threads none
  let mut evs : List (Nat × Bool) := []
  for _ in List.range (2 * txs.size) do
    let live := (List.range threads).filter fun t => open_[t]!.isSome || !queues[t]!.isEmpty
    if live.isEmpty then break
    let t ← pick live
    match open_[t]! with
    | some i =>
      evs := evs ++ [(i, true)]
      open_ := open_.set! t none
    | none =>
      match queues[t]! with
      | i :: rest =>
        evs := evs ++ [(i, false)]
        open_ := open_.set! t (some i)
        queues := queues.set! t rest
      | [] => pure ()
  return evs

/-- A garbage item read of `k`. -/
def garbageRead (written : List (Nat × List Int)) (k : Nat) : G Val := do
  match ← weighted [2, 4, 1] with
  | 0 => return .nil
  | 1 =>
    match (written.lookup k).getD [] with
    | [] => return .nil
    | vs => return .int (← pick vs)
  | _ => return .int (1000 + Int.ofNat (← nat 3))

/-- Garbage predicate rows: a random cut's rows with one row dropped or one row added. -/
def garbageRows (cuts : Array State) (written : List (Nat × List Int)) (p : Pred) (keys : Nat) :
    G (List (Nat × Val)) := do
  let st := cuts[← nat cuts.size]!
  let rs := rows st p keys
  if !rs.isEmpty && (← chance 1 2) then
    let drop ← nat rs.length
    return rs.eraseIdx drop
  let k ← nat keys
  match (written.lookup k).getD [] with
  | [] => return rs
  | vs =>
    let v ← pick vs
    let rs := (rs.filter (·.1 != k)) ++ [(k, .int v)]
    return rs.mergeSort fun a b => decide (a.1 ≤ b.1)

/-- The history for `seed`. -/
def history (seed : Nat) : History :=
  Id.run (go.run' ((UInt64.ofNat seed) * 0x9E3779B97F4A7C15 ^^^ 0xD1B54A32D192ED03))
where
  go : G History := do
    let keys := 2 + (← nat 3)
    let threads := 1 + (← nat 3)
    -- the :init op: about two keys in three, with 0 or 1
    let mut init : State := []
    for k in List.range keys do
      if ← chance 2 3 then init := init ++ [(k, .int (Int.ofNat (← nat 2)))]
    let txs ← genTxns keys threads
    let evs ← schedule txs threads
    -- which :info transactions take effect
    let mut effective : Array Bool := #[]
    for t in txs do
      effective := effective.push (t.status == .ok || (t.status == .info && (← chance 1 2)))
    -- states at each cut: before :init, after it, after each effective completion
    let mut st := init
    let mut cuts : Array State := #[[], init]
    let mut before : Array Nat := Array.replicate txs.size 1
    for (i, done) in evs do
      if done then
        before := before.set! i (cuts.size - 1)
        if effective[i]! then
          st := txs[i]!.mops.foldl applyMop st
          cuts := cuts.push st
    -- every value written to each key, init's and failed transactions' included
    let mut written : List (Nat × List Int) := init.filterMap fun (k, v) =>
      match v with | .int i => some (k, [i]) | _ => none
    for t in txs do
      for m in t.mops do
        if m.f == .w || m.f == .insert then
          if let .int i := m.v then written := amUpdate written m.k [] (· ++ [i])
    -- fill the :ok transactions' reads
    let chaos ← chance 1 10
    let mut filled : Array (List Mop) := #[]
    for i in List.range txs.size do
      let t := txs[i]!
      if t.status != .ok then
        filled := filled.push t.mops
        continue
      let mode ← if chaos then pure 2 else weighted [12, 8, 0]
      let mut own := cuts[before[i]!]!
      let mut out : List Mop := []
      for m in t.mops do
        match m.f with
        | .r =>
          let v ← match mode with
            | 0 => pure (readKey own m.k)
            | 1 => do
              match ← weighted [5, 4, 1] with
              | 0 => pure (readKey own m.k)
              | 1 => pure (readKey cuts[← nat cuts.size]! m.k)
              | _ => garbageRead written m.k
            | _ => garbageRead written m.k
          out := out ++ [{ m with v }]
        | .rp =>
          let rs ← match mode with
            | 0 => pure (rows own m.pred keys)
            | 1 => do
              match ← weighted [5, 4, 1] with
              | 0 => pure (rows own m.pred keys)
              | 1 => pure (rows cuts[← nat cuts.size]! m.pred keys)
              | _ => garbageRows cuts written m.pred keys
            | _ => garbageRows cuts written m.pred keys
          out := out ++ [{ m with v := .kmap rs }]
        | _ =>
          own := applyMop own m
          out := out ++ [m]
      filled := filled.push out
    -- the ops: :init by process 0, then the events; a thread that completes :info comes back as
    -- a fresh process, as Jepsen's do
    let initMops : List Mop := init.filterMap fun (k, v) =>
      match v with | .int i => some { f := .w, k, v := .int i } | _ => none
    let mut ops : Array Op := #[
      { index := 0, type := .invoke, process := 0, f := .init, value := initMops },
      { index := 1, type := .ok, process := 0, f := .init, value := initMops }]
    let mut crashes : Array Nat := Array.replicate threads 0
    for (i, done) in evs do
      let t := txs[i]!
      let p := 1 + t.thread + threads * crashes[t.thread]!
      if !done then
        ops := ops.push { index := ops.size, type := .invoke, process := p, value := t.mops }
      else
        ops := ops.push { index := ops.size, type := t.status, process := p, value := filled[i]! }
        if t.status == .info then crashes := crashes.set! t.thread (crashes[t.thread]! + 1)
    return ops

end Grade.Gen
