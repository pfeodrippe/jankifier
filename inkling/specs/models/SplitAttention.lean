module
public import Veil

/-!
# The split attention's reads and records

`att_split` and `att_merge` (`native/kernels.metal`, dispatched in
`native/metal.mm` when `split_attention` is on): one token at position `p0` of
a global visit attends to the keys `0 .. p0` (`n = p0 + 1` of them). They are
split in `splits` chunks; chunk `s` covers `[s * chunk, min((s + 1) * chunk,
n))`, and a threadgroup per chunk takes it with 8 simdgroups, simdgroup `g`
reading the keys `begin + g, begin + g + 8, ...` below the chunk's end
(`for(j = begin + sg; j < end; j += NSG)`). When all of them are done (the
threadgroup's barrier) the chunk's record (its max, sum and weighted values)
is written; `att_merge` runs after `att_split` (the encoder runs its
dispatches in order) and adds every chunk's record to the result.

A key's place is its chunk `owner k`, the simdgroup `sgOf k` that reads it
and its rank `pos k` in that simdgroup's loop: `kord k = c * chunk + g + 8 *
pos`, below the chunk's end; simdgroup `g` of chunk `c` reads `len c g` keys.
The model's assumptions about them are facts of that arithmetic, proved of the
engine's `chunk = ceil(keys / splits)` in `SoftmaxMerge.lean`
(`chunk_owner`, `chunk_disjoint`, `chunk_inside`, `strided_repr`,
`strided_unique`, `strided_len`; `engine_chunks`: there are at least 2 chunks
and none is empty). In particular the key at a simdgroup's next address is
the key whose place is its next one, which is how `readKey` names it. That file also proves, without this model, that the chunks are exactly
the keys in order (`chunks_cover`), that the simdgroups' strided shares are a
permutation of a chunk's keys (`shares_perm`), and what the merged records
compute (`split_attention_exact`).

A key is read from slot `slotOf (kord k)`; for a global visit the ring has
`context` slots and `Ring.lean` proves that every position up to the token's
is in its slot (`window_held` with `window = 0`).
-/

set_option veil.smt.trust false

veil module SplitAttention

/- Positions of the cache (keys), chunks and a threadgroup's simdgroups. -/
type key
type chunk
type sgroup
enum phase_t = { splitting, merging, finished }

immutable individual n : Nat
immutable individual splits : Nat
immutable individual context : Nat
immutable function kord : key → Nat
immutable function cord : chunk → Nat
/- How many keys simdgroup g of chunk c reads. -/
immutable function len : chunk → sgroup → Nat
/- A key's chunk, the simdgroup that reads it, and its place in that
simdgroup's loop. -/
immutable function owner : key → chunk
immutable function sgOf : key → sgroup
immutable function pos : key → Nat
immutable function slotOf : Nat → Nat

individual phase : phase_t
/- att_split: how many keys simdgroup g of chunk c has read. -/
function steps : chunk → sgroup → Nat
/- Ghost: how many times each key was read, each chunk's record written and
added by att_merge. -/
function reads : key → Nat
function written : chunk → Nat
function added : chunk → Nat
/- att_merge's loop over the chunks, by number. -/
individual cursor : Nat
/- Ghost: the last key read and the slot it was read from. -/
individual lastKey : Nat
individual lastSlot : Nat

#gen_state

/- Numbers identify keys and chunks; the chunks are 0 .. splits - 1. -/
assumption [key_ords] kord K = kord L → K = L
assumption [chunk_ords] cord C = cord D → C = D
assumption [chunk_range] cord C < splits
assumption [chunks_all] ∀ i, i < splits → ∃ c, cord c = i
assumption [keys_in_context] n ≤ context
/- Every key below n has a place among its simdgroup's len, and two keys below
n don't share a place. -/
assumption [owners] kord K < n → pos K < len (owner K) (sgOf K)
assumption [places_unique] kord K < n → kord L < n → owner K = owner L → sgOf K = sgOf L → pos K = pos L → K = L

after_init {
  phase := splitting
  steps C G := 0
  reads K := 0
  written C := 0
  added C := 0
  cursor := 0
  lastKey := 0
  lastSlot := slotOf 0
}

/- `for(j = begin + sg; j < end; j += NSG)`: simdgroup g of chunk c reads the
key at its next place (the key at `begin + g + 8 * steps`, below the chunk's
end and so below p0 + 1). -/
action readKey (c : chunk) (g : sgroup) (k : key) {
  require phase = splitting ∧ kord k < n ∧ owner k = c ∧ sgOf k = g ∧ pos k = steps c g
  reads K := if K = k then reads K + 1 else reads K
  lastKey := kord k
  lastSlot := slotOf (kord k)
  steps c g := steps c g + 1
}

/- After the threadgroup's barrier: every simdgroup's loop ended (its next
address is past the chunk's end: steps ≥ len), and the chunk's record is
written. -/
action writeRecord (c : chunk) {
  require phase = splitting ∧ written c = 0 ∧ ∀ g, len c g ≤ steps c g
  written c := 1
}

/- att_merge starts once att_split is done. -/
action startMerge {
  require phase = splitting ∧ ∀ c, written c = 1
  phase := merging
  cursor := 0
}

/- `for(s = 0; s < splits; ++s)`: chunk s's record is added. -/
action addRecord (c : chunk) {
  require phase = merging ∧ cursor < splits ∧ cord c = cursor
  added C := if C = c then added C + 1 else added C
  cursor := cursor + 1
}

action finish {
  require phase = merging ∧ cursor = splits
  phase := finished
}

/-! Properties -/

/- Every key is read at most once and only below n (nothing past p0), from
its slot, a position of the token's context. -/
safety [read_once] reads K ≤ 1
safety [read_up_to_p0] 0 < reads K → kord K < n
safety [read_in_ring] lastSlot = slotOf lastKey ∧ lastKey ≤ context
/- When att_merge starts, every key below n has been read. -/
safety [all_read] phase ≠ splitting → kord K < n → reads K = 1
/- Each record is written once, and added once, after it was written. -/
safety [written_once] written C ≤ 1
safety [added_after_written] 0 < added C → written C = 1
safety [added_once] added C ≤ 1
safety [all_added] phase = finished → added C = 1

/-! Auxiliary invariants -/

/- A key was read iff its simdgroup is past its place, and a simdgroup reads
no more than its keys. -/
invariant [read_past] 0 < reads K → kord K < n ∧ pos K < steps (owner K) (sgOf K)
invariant [past_read] kord K < n → pos K < steps (owner K) (sgOf K) → reads K = 1
invariant [reads_bound] reads K ≤ 1
invariant [steps_len] steps C G ≤ len C G
invariant [reads_outside] n ≤ kord K → reads K = 0
invariant [record_done] written C = 1 → ∀ g, len C g ≤ steps C g
invariant [merging_written] phase ≠ splitting → written C = 1
invariant [written_bound] written C ≤ 1
invariant [splitting_none_added] phase = splitting → added C = 0
invariant [added_cursor] phase ≠ splitting → (added C = 1 ↔ cord C < cursor) ∧ added C ≤ 1
invariant [cursor_bound] cursor ≤ splits
invariant [finished_cursor] phase = finished → cursor = splits
invariant [last_key] lastKey ≤ n

#gen_spec

#check_invariants

end SplitAttention
