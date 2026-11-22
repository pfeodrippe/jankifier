module
public import Veil

/-!
# The key/value ring of a visit's cache

A model of where the engine keeps each position's keys and values, and of what
a token's attention reads (`native/cpu.cpp`: `new_session`, `attention`,
`reset`, `copy`; `native/metal.mm` and `native/kernels.metal`: `kv_store`,
`attention`; `include/inkling/inkling.hpp`: `visit_cache`).

- A visit's cache has `nslots` slots. Position `p` is written to slot
  `p % nslots` (`visit_cache::slot`). A local visit (sliding window) has
  `nslots = min(context, window + max_chunk)`; a global one has
  `nslots = context`.
- `eval` splits its tokens into chunks of at most `max_chunk`, and a forward
  pass takes one chunk: in each visit it first writes the keys and values of
  every token of the chunk, then each token attends to the positions
  `[max(0, p - window + 1), p]` (all of `[0, p]` in a global visit), reading
  slot `j % nslots` for position `j`.
- `reset` sets the position to 0 and leaves the slots as they are.
- `copy` copies the first `min(nslots, pos)` slots of the source and its
  position.

Here `slotOf` is the map from positions to slots, kept abstract: the proofs
below use only that two positions less than `nslots` apart have different
slots, and that the positions below `nslots` are at their own index.
`RingLemmas.lean` proves both for `p % nslots`, and that the engine's number of
slots is enough (`enough`). `window = 0` is a global visit.

What a slot holds is the position whose data was written there last, and
whether that data belongs to the session's current sequence (`fresh`): `reset`
and the slots `copy` leaves alone hold bytes of another sequence.
-/

set_option veil.smt.trust false

veil module Ring

type slot
type sess
enum phase_t = { idle, writing, attending }

immutable individual window : Nat
immutable individual maxChunk : Nat
immutable individual context : Nat
immutable individual nslots : Nat
immutable function slotOf : Nat → slot
/- A slot's index in the cache (`copy` takes the first slots). -/
immutable function idx : slot → Nat

function pos : sess → Nat
function phase : sess → phase_t
/- In a forward pass: how many of the chunk's tokens have their keys and
values written, and how many have attended. -/
function chunkLen : sess → Nat
function att : sess → Nat
/- Ghost: `pos + chunkLen` in a pass, `pos` otherwise. -/
function wpos : sess → Nat
function holds : sess → slot → Nat
relation fresh : sess → slot → Bool

#gen_state

/- Two positions less than `nslots` apart are in different slots. -/
assumption [apart] ∀ a, a < context → ∀ b, b < context → (a < b ∧ b < a + nslots → slotOf a ≠ slotOf b)
/- The positions below `nslots` are at their own index, and indices are below
`nslots`. -/
assumption [low] ∀ a, a < context → (a < nslots → idx (slotOf a) = a)
assumption [idx_bound] idx L < nslots
/- Enough slots: all of the context, or the window and a chunk but one. -/
assumption [enough] context ≤ nslots ∨ (0 < window ∧ window + maxChunk ≤ nslots + 1)
assumption [chunks] 0 < maxChunk

after_init {
  pos S := 0
  phase S := idle
  chunkLen S := 0
  att S := 0
  wpos S := 0
  holds S L := 0
  fresh S L := false
}

/- A forward pass of a chunk starts (`eval` checked that it fits). -/
action begin (s : sess) {
  require phase s = idle ∧ pos s < context
  phase s := writing
  chunkLen s := 0
  att s := 0
}

/- The keys and values of the chunk's next token go to its slot. -/
action write (s : sess) {
  require phase s = writing ∧ chunkLen s < maxChunk ∧ pos s + chunkLen s < context
  let p := pos s + chunkLen s
  holds s L := if L = slotOf p then p else holds s L
  fresh s L := if L = slotOf p then true else fresh s L
  chunkLen s := chunkLen s + 1
  wpos s := p + 1
}

/- All the chunk's tokens are written: its tokens attend, in any order here
(the model takes them first to last; nothing is written in between). -/
action startAttend (s : sess) {
  require phase s = writing ∧ 0 < chunkLen s
  phase s := attending
}

action attend (s : sess) {
  require phase s = attending ∧ att s < chunkLen s
  att s := att s + 1
}

action finish (s : sess) {
  require phase s = attending ∧ att s = chunkLen s
  pos s := pos s + chunkLen s
  chunkLen s := 0
  att s := 0
  phase s := idle
}

/- `reset`: position 0; the slots keep their bytes, which now belong to no
sequence. -/
action reset (s : sess) {
  require phase s = idle
  pos s := 0
  wpos s := 0
  fresh s L := false
}

/- `copy(d, s)`: the first `min(nslots, pos s)` slots and the position. The
other slots of `d` keep bytes of its earlier sequence. -/
action copy (d : sess) (s : sess) {
  require d ≠ s ∧ phase d = idle ∧ phase s = idle
  let rows := if nslots ≤ pos s then nslots else pos s
  holds d L := if idx L < rows then holds s L else holds d L
  fresh d L := decide (idx L < rows ∧ fresh s L)
  pos d := pos s
  wpos d := pos s
}

/- When the token at position `pos + att` attends, every position of its
window is in its slot, with this sequence's data. -/
safety [window_held]
  phase S = attending ∧ att S < chunkLen S →
    ∀ j, j < context → ((window = 0 ∨ pos S + att S < j + window) ∧ j ≤ pos S + att S →
      fresh S (slotOf j) ∧ holds S (slotOf j) = j)

/-! Auxiliary invariants. -/

invariant [wpos_def] wpos S = pos S + chunkLen S
invariant [in_context] wpos S ≤ context
invariant [idle_empty] phase S = idle → chunkLen S = 0 ∧ att S = 0
invariant [chunk_bound] chunkLen S ≤ maxChunk ∧ att S ≤ chunkLen S
/- What a fresh slot holds was written, and is that position's slot. -/
invariant [held_written] fresh S L → holds S L < wpos S ∧ slotOf (holds S L) = L
/- The last `nslots` positions written are in their slots. -/
invariant [recent_held]
  ∀ j, j < context → (j < wpos S ∧ wpos S ≤ j + nslots → fresh S (slotOf j) ∧ holds S (slotOf j) = j)

#gen_spec

-- For the checks driven from jank (veil/model-check, veil/system).
#gen_executable

#check_invariants

/-! ## Model checking

Slots are `Fin n` and `slotOf p = p % n`. A local visit with a window of 3 and
chunks of up to 2 has `min(context, 3 + 2) = 5` slots; the context of 12 lets
the ring wrap twice. -/

-- The engine's rule: window + max_chunk slots.
#model_check { slot := Fin 5, sess := Fin 1 }
  { window := 3, maxChunk := 2, context := 12, nslots := 5,
    slotOf := fun p => ⟨p % 5, Nat.mod_lt _ (by decide)⟩, idx := fun l => l.val }

-- One slot less still works (window + max_chunk - 1).
#model_check { slot := Fin 4, sess := Fin 1 }
  { window := 3, maxChunk := 2, context := 12, nslots := 4,
    slotOf := fun p => ⟨p % 4, Nat.mod_lt _ (by decide)⟩, idx := fun l => l.val }

end Ring
