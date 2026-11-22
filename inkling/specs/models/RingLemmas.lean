/-!
# The ring's arithmetic

`Ring.lean` proves its properties from assumptions about `slotOf` (the slot of
a position) and about the number of slots. These theorems, checked by Lean's
kernel, show that the engine's choices satisfy them for every size:
`slotOf p = p % nslots` (`visit_cache::slot`), a slot's index is itself, and
`nslots = min(context, window + max_chunk)` for a local visit (`new_session`),
`nslots = context` for a global one.
-/

set_option linter.unusedVariables false

namespace RingLemmas

/-- `apart`: two positions less than `n` apart have different slots. -/
theorem apart (n a b : Nat) (hab : a < b) (hb : b < a + n) : a % n ≠ b % n := by
  intro h
  have hz : (b - a) % n = 0 := Nat.sub_mod_eq_zero_of_mod_eq h.symm
  have hlt : b - a < n := by omega
  rw [Nat.mod_eq_of_lt hlt] at hz
  omega

/-- `low`: a position below `n` is at its own index. -/
theorem low (n a : Nat) (h : a < n) : a % n = a := Nat.mod_eq_of_lt h

/-- `idx_bound`: a slot's index is below `n`. -/
theorem idx_bound (n p : Nat) (hn : 0 < n) : p % n < n := Nat.mod_lt p hn

/-- `enough`, for a local visit: `min(context, window + max_chunk)` slots. -/
theorem enough_local (context window maxChunk : Nat) (hw : 0 < window) :
    context ≤ min context (window + maxChunk)
      ∨ (0 < window ∧ window + maxChunk ≤ min context (window + maxChunk) + 1) := by
  omega

/-- `enough`, for a global visit: `context` slots. -/
theorem enough_global (context : Nat) : context ≤ context := Nat.le_refl _

/-- The statement of `Ring`'s `window_held` for the concrete ring, as a
function of what was written: after positions `0 .. wpos - 1` were written in
order, each to slot `p % n`, the slot of a position `j` among the last `n`
holds `j`: no later position written has the same slot. -/
theorem last_writer (n j i wpos : Nat) (hj : j < wpos) (hw : wpos ≤ j + n)
    (hi : i < wpos) (hji : j ≤ i) (hslot : i % n = j % n) : i = j := by
  rcases Nat.lt_or_ge j i with h | h
  · exact absurd hslot.symm (apart n j i h (by omega))
  · omega

/-- With the engine's number of slots, every position a token attends to is
among the last `nslots` written when it attends: the token at `pos + t` of a
chunk of `len ≤ maxChunk` tokens, all written (`wpos = pos + len`), and a
position `j` of its window. -/
theorem window_recent (context window maxChunk pos len t j : Nat)
    (hw : 0 < window) (hlen : len ≤ maxChunk) (ht : t < len) (hfit : pos + len ≤ context)
    (hj : pos + t < j + window) (_hjp : j ≤ pos + t) :
    pos + len ≤ j + min context (window + maxChunk) := by
  omega

end RingLemmas

#print axioms RingLemmas.apart
#print axioms RingLemmas.last_writer
#print axioms RingLemmas.window_recent
