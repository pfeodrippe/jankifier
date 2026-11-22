module
public import Veil

/-!
# jank's array maps and their transients, down to the storage

A blind model (see `PLAN.md`, phase 2, C3): T1, T2, T4 and T5 were written in
`PLAN.md` from the docstrings before this code was read. `Transients.lean`
only models which operations check `active`; this one follows the storage of
array maps (every map of up to 8 entries) in jank 0.1 (`f3d82d654`):

- `native_array_map` (`detail/native_array_map.hpp`) is a raw pointer to a
  GC-allocated array of key/value slots, a capacity and a length. Its copy
  constructor is `= default`: a copy shares the array.
- Persistent `assoc`/`dissoc` (`obj/persistent_array_map.cpp:70`, `:90`)
  `clone()` it (a new array) and change the copy.
- `transient` (`to_transient`, `:108`) makes a `transient_array_map` with a
  copy of `data`: the same array (`transient_array_map.cpp:24`).
- `assoc!` (`insert_or_assign`, `native_array_map.cpp:139`) overwrites the
  value in place when the key is there; else `insert_unique` appends in place
  when there's capacity left (`make_next_array`, `:16`), and otherwise
  allocates a new array.
- `dissoc!` (`erase`, `:168`) shifts the later slots down in place.
- `persistent!` (`to_persistent`, `transient_array_map.cpp:126`) moves `data`
  into the result: the result has the same array.

Each object also has its logical contents (a ghost: what the operations
should give); the properties compare what's in its slots with it. Maps stay
below 8 entries, so there's no promotion to a hash map.

`fixed` turns on a proposed fix of jank, to check it before it's written:

- `a1`: `transient` clones the array (`to_transient` copies `data` with
  `clone()`, as persistent `assoc` does), so a transient never writes into
  the map it came from; `persistent!` can still move the array into its
  result, since the next `transient` of the result clones it again.
-/

veil module ArrayMap

type obj
type buf
type key
type val
type slot
/- The proposed fixes (see above). -/
enum fix_t = { a1 }
/- Slots are numbered from 0 (`slotIdx`), `slotNext` is the next one; `maxCap`
slots per array. -/
immutable function slotIdx : slot → Nat
immutable function slotNext : slot → slot
immutable individual maxCap : Nat
immutable relation allowTransients : Bool
immutable individual focus : Nat
immutable relation fixed : fix_t → Bool
/- Defaults for the initial (unused) memory. -/
immutable individual buf0 : buf
immutable individual key0 : key
immutable individual val0 : val

/- Objects: in use, persistent (else a transient), active (a transient before
`persistent!`), made by `persistent!`; each one's array, length and capacity
(in slots). -/
relation used : obj → Bool
relation persistentObj : obj → Bool
relation active : obj → Bool
relation madeByPersistent : obj → Bool
function bufOf : obj → buf
function len : obj → Nat
function cap : obj → Nat
/- Arrays: allocated, and their slots. -/
relation bufUsed : buf → Bool
function cellKey : buf → slot → key
function cellVal : buf → slot → val
/- What each object should hold. -/
relation logical : obj → key → val → Bool

#gen_state

after_init {
  used O := false
  persistentObj O := false
  active O := false
  madeByPersistent O := false
  bufOf O := buf0
  cellKey B S := key0
  cellVal B S := val0
  len O := 0
  cap O := 0
  bufUsed B := false
  logical O K V := false
}

/- What `o`'s slots hold, and whether a key is in two of them. -/
ghost relation has (o : obj) (k : key) (v : val) :=
  ∃ S, slotIdx S < len o ∧ cellKey (bufOf o) S = k ∧ cellVal (bufOf o) S = v
ghost relation noDup (o : obj) :=
  ∀ S T, slotIdx S < len o ∧ slotIdx T < len o ∧ cellKey (bufOf o) S = cellKey (bufOf o) T → S = T
ghost relation right (o : obj) := (∀ K V, has o K V ↔ logical o K V) ∧ noDup o

/-! ## Persistent maps -/

/- `{}`: an empty map, with its own (empty) array. -/
action newEmpty (o : obj) (b : buf) {
  require ¬ used o ∧ ¬ bufUsed b
  used o := true
  persistentObj o := true
  bufOf o := b
  bufUsed b := true
  len o := 0
  cap o := 0
}

/- `(assoc p k v)`: `clone()` into a new array `b`, then `insert_or_assign`
there. -/
action pAssoc (p : obj) (k : key) (v : val) (q : obj) (b : buf) {
  require used p ∧ persistentObj p ∧ ¬ used q ∧ ¬ bufUsed b ∧ len p < maxCap
  used q := true
  persistentObj q := true
  bufUsed b := true
  bufOf q := b
  if ∃ S, slotIdx S < len p ∧ cellKey (bufOf p) S = k then
    cellKey b S := cellKey (bufOf p) S
    cellVal b S := if slotIdx S < len p ∧ cellKey (bufOf p) S = k ∧
        (∀ R, slotIdx R < slotIdx S → cellKey (bufOf p) R ≠ k)
      then v else cellVal (bufOf p) S
    len q := len p
    cap q := cap p
  else
    cellKey b S := if slotIdx S = len p then k else cellKey (bufOf p) S
    cellVal b S := if slotIdx S = len p then v else cellVal (bufOf p) S
    len q := len p + 1
    cap q := if cap p < len p + 1 then len p + 1 else cap p
  logical q K V := decide ((K = k ∧ V = v) ∨ (K ≠ k ∧ logical p K V))
}

/- `(dissoc p k)`: `clone()` into a new array `b`, then `erase` there. -/
action pDissoc (p : obj) (k : key) (q : obj) (b : buf) {
  require used p ∧ persistentObj p ∧ ¬ used q ∧ ¬ bufUsed b
  used q := true
  persistentObj q := true
  bufUsed b := true
  bufOf q := b
  cellVal b S := if (∃ R, slotIdx R ≤ slotIdx S ∧ slotIdx R < len p ∧ cellKey (bufOf p) R = k) ∧
      slotIdx S + 1 < len p
    then cellVal (bufOf p) (slotNext S) else cellVal (bufOf p) S
  cellKey b S := if (∃ R, slotIdx R ≤ slotIdx S ∧ slotIdx R < len p ∧ cellKey (bufOf p) R = k) ∧
      slotIdx S + 1 < len p
    then cellKey (bufOf p) (slotNext S) else cellKey (bufOf p) S
  if ∃ R, slotIdx R < len p ∧ cellKey (bufOf p) R = k then
    len q := len p - 1
  else
    len q := len p
  cap q := cap p
  logical q K V := decide (K ≠ k ∧ logical p K V)
}

/-! ## Transients -/

/- `(transient p)`: a copy of `data`, the same array. -/
action toTransient (p : obj) (t : obj) {
  require ¬ fixed a1
  require allowTransients ∧ used p ∧ persistentObj p ∧ ¬ used t
  used t := true
  active t := true
  bufOf t := bufOf p
  len t := len p
  cap t := cap p
  logical t K V := logical p K V
}

/- `(transient p)` with the fix `a1`: a clone of `data`, in a new array `b`. -/
action toTransientCopy (p : obj) (t : obj) (b : buf) {
  require fixed a1
  require allowTransients ∧ used p ∧ persistentObj p ∧ ¬ used t ∧ ¬ bufUsed b
  used t := true
  active t := true
  bufUsed b := true
  cellKey b S := cellKey (bufOf p) S
  cellVal b S := cellVal (bufOf p) S
  bufOf t := b
  len t := len p
  cap t := cap p
  logical t K V := logical p K V
}

/- `(assoc! t k v)`: `insert_or_assign`, in `t`'s array, or (with no
capacity left) in a new array `b`. -/
action tAssoc (t : obj) (k : key) (v : val) (b : buf) {
  require used t ∧ active t ∧ len t < maxCap ∧ ¬ bufUsed b
  if ∃ S, slotIdx S < len t ∧ cellKey (bufOf t) S = k then
    -- The key is there: its value is overwritten in place.
    cellVal B S := if B = bufOf t ∧ slotIdx S < len t ∧ cellKey B S = k ∧
        (∀ R, slotIdx R < slotIdx S → cellKey B R ≠ k)
      then v else cellVal B S
  else
    if len t < cap t then
      -- Capacity left: appended in place.
      cellKey B S := if B = bufOf t ∧ slotIdx S = len t then k else cellKey B S
      cellVal B S := if B = bufOf t ∧ slotIdx S = len t then v else cellVal B S
      len t := len t + 1
    else
      -- A new array, with the old slots and the new one.
      bufUsed b := true
      cellKey b S := if slotIdx S = len t then k else cellKey (bufOf t) S
      cellVal b S := if slotIdx S = len t then v else cellVal (bufOf t) S
      bufOf t := b
      len t := len t + 1
      cap t := len t
  logical t K V := decide ((K = k ∧ V = v) ∨ (K ≠ k ∧ logical t K V))
}

/- `(dissoc! t k)`: `erase`, shifting the later slots down in place. -/
action tDissoc (t : obj) (k : key) {
  require used t ∧ active t
  if ∃ R, slotIdx R < len t ∧ cellKey (bufOf t) R = k then
    cellVal B S := if B = bufOf t ∧
        (∃ R, slotIdx R ≤ slotIdx S ∧ slotIdx R < len t ∧ cellKey B R = k) ∧ slotIdx S + 1 < len t
      then cellVal B (slotNext S) else cellVal B S
    cellKey B S := if B = bufOf t ∧
        (∃ R, slotIdx R ≤ slotIdx S ∧ slotIdx R < len t ∧ cellKey B R = k) ∧ slotIdx S + 1 < len t
      then cellKey B (slotNext S) else cellKey B S
    len t := len t - 1
  logical t K V := decide (K ≠ k ∧ logical t K V)
}

/- `(persistent! t)`: the result gets `t`'s array (moved). -/
action persistentT (t : obj) (q : obj) {
  require used t ∧ active t ∧ ¬ used q
  active t := false
  used q := true
  persistentObj q := true
  madeByPersistent q := true
  bufOf q := bufOf t
  len q := len t
  cap q := cap t
  logical q K V := logical t K V
}

/-! ## Properties

T1, T2, T4 and T5 are from `PLAN.md`, written before the code was read. -/

/- T1: no operation on a transient changes the map it was made from (or any
other persistent map not made by `persistent!`). -/
safety [t1_source_unchanged]
  focus = 1 → (used P ∧ persistentObj P ∧ ¬ madeByPersistent P → right P)
/- T4: a map returned by `persistent!` isn't changed later. -/
safety [t4_result_unchanged]
  focus = 4 → (used P ∧ madeByPersistent P → right P)
/- T2, T5: a transient holds what its operations give, whatever other
transients do. -/
safety [t2_t5_transient_right]
  focus = 5 → (used T ∧ active T → right T)

#gen_spec

/-! ## Model checking

Four objects, five arrays, two keys, two values, three slots. -/

-- Persistent maps alone: every map always holds what it should.
#model_check { obj := Fin 4, buf := Fin 5, key := Fin 2, val := Fin 2, slot := Fin 3 }
  { slotIdx := fun s => s.val, slotNext := fun s => s + 1, maxCap := 3,
    allowTransients := false, focus := 1, buf0 := 0, key0 := 0, val0 := 0,
    fixed := fun _ => false }

-- T1, T4, T5 with transients.
#guard_msgs (drop error) in
#model_check { obj := Fin 4, buf := Fin 5, key := Fin 2, val := Fin 2, slot := Fin 3 }
  { slotIdx := fun s => s.val, slotNext := fun s => s + 1, maxCap := 3,
    allowTransients := true, focus := 1, buf0 := 0, key0 := 0, val0 := 0,
    fixed := fun _ => false } (sequential := true)
set_option veil.violationIsError false in
#model_check { obj := Fin 4, buf := Fin 5, key := Fin 2, val := Fin 2, slot := Fin 3 }
  { slotIdx := fun s => s.val, slotNext := fun s => s + 1, maxCap := 3,
    allowTransients := true, focus := 1, buf0 := 0, key0 := 0, val0 := 0,
    fixed := fun _ => false } (sequential := true)

#guard_msgs (drop error) in
#model_check { obj := Fin 4, buf := Fin 5, key := Fin 2, val := Fin 2, slot := Fin 3 }
  { slotIdx := fun s => s.val, slotNext := fun s => s + 1, maxCap := 3,
    allowTransients := true, focus := 4, buf0 := 0, key0 := 0, val0 := 0,
    fixed := fun _ => false } (sequential := true)
set_option veil.violationIsError false in
#model_check { obj := Fin 4, buf := Fin 5, key := Fin 2, val := Fin 2, slot := Fin 3 }
  { slotIdx := fun s => s.val, slotNext := fun s => s + 1, maxCap := 3,
    allowTransients := true, focus := 4, buf0 := 0, key0 := 0, val0 := 0,
    fixed := fun _ => false } (sequential := true)

#guard_msgs (drop error) in
#model_check { obj := Fin 4, buf := Fin 5, key := Fin 2, val := Fin 2, slot := Fin 3 }
  { slotIdx := fun s => s.val, slotNext := fun s => s + 1, maxCap := 3,
    allowTransients := true, focus := 5, buf0 := 0, key0 := 0, val0 := 0,
    fixed := fun _ => false } (sequential := true)
set_option veil.violationIsError false in
#model_check { obj := Fin 4, buf := Fin 5, key := Fin 2, val := Fin 2, slot := Fin 3 }
  { slotIdx := fun s => s.val, slotNext := fun s => s + 1, maxCap := 3,
    allowTransients := true, focus := 5, buf0 := 0, key0 := 0, val0 := 0,
    fixed := fun _ => false } (sequential := true)

/- T1, T4 and T5 with the fix `a1`: no violation, up to depth 6 (their
counterexamples above take 4, 6 and 5 steps; the whole state space with
transients is too large: over 10 million states at depth 6). -/
#model_check { obj := Fin 4, buf := Fin 5, key := Fin 2, val := Fin 2, slot := Fin 3 }
  { slotIdx := fun s => s.val, slotNext := fun s => s + 1, maxCap := 3,
    allowTransients := true, focus := 1, buf0 := 0, key0 := 0, val0 := 0,
    fixed := fun _ => true } (maxDepth := 6)
#model_check { obj := Fin 4, buf := Fin 5, key := Fin 2, val := Fin 2, slot := Fin 3 }
  { slotIdx := fun s => s.val, slotNext := fun s => s + 1, maxCap := 3,
    allowTransients := true, focus := 4, buf0 := 0, key0 := 0, val0 := 0,
    fixed := fun _ => true } (maxDepth := 6)
#model_check { obj := Fin 4, buf := Fin 5, key := Fin 2, val := Fin 2, slot := Fin 3 }
  { slotIdx := fun s => s.val, slotNext := fun s => s + 1, maxCap := 3,
    allowTransients := true, focus := 5, buf0 := 0, key0 := 0, val0 := 0,
    fixed := fun _ => true } (maxDepth := 6)

#gen_executable

end ArrayMap
