module
public import Veil

/-!
# The router's choice of experts

`native/cpu.cpp`, `experts`: per token, each expert's score is
`sigmoid(logit) + bias`, a banned expert's (`model::banned_experts`, set by
`ban-experts!`) is `-inf`, and the `k` experts first in the order "higher
score, or equal score and lower index" are chosen (`std::partial_sort` with
that comparator; `kernels.metal`'s `route` takes the experts whose rank in the
same order is below `k`). The weights are `sigmoid(logit)` of the chosen ones,
normalized and multiplied by the route scale (`RouterWeights.lean` proves that
they add up to the route scale).

The order is the theory: `before e f` says that `e` comes before `f`. It is a
strict total order (the comparator on scores that aren't NaN, with indices
breaking ties), and a banned expert comes after every allowed one (`-inf` is
below any finite score). The choice is modelled as `k` picks, each of the
expert first in the order among those not chosen yet: the same experts, in
the same order, as the sorted prefix (and as the ranks below `k`).

Properties: an expert is chosen once at most; the chosen ones come before
every other; a banned expert is chosen only when every allowed one is.

That last one is all that holds: `ban-experts!` doesn't limit how many
experts are banned, so with more than `experts - k` banned some of the `k`
chosen are banned, with a weight like any other (`banned_never_chosen`, which
says a banned expert is never chosen, fails; a model check gives a
counterexample with 3 experts, 1 allowed and `k = 2`: `inkling-specs.router`
loads the model with that property added).
-/

set_option veil.smt.trust false

veil module Router

type expert

immutable individual k : Nat
immutable relation before : expert → expert → Bool
immutable relation banned : expert → Bool

/- The chosen experts, and the expert at each position of the choice. -/
relation chosen : expert → Bool
function slotExpert : Nat → expert
individual count : Nat

#gen_state

assumption [irreflexive] ¬ before E E
assumption [transitive] before E F → before F G → before E G
assumption [total] E ≠ F → before E F ∨ before F E
assumption [banned_last] banned F → ¬ banned E → before E F

after_init {
  chosen E := false
  count := 0
}

/- The next expert: not chosen yet, and before every other not chosen yet. -/
action choose (e : expert) {
  require count < k ∧ ¬ chosen e ∧ ∀ f, ¬ chosen f → f ≠ e → before e f
  chosen e := true
  slotExpert count := e
  count := count + 1
}

/-! Properties -/

/- The positions of the choice hold different experts, the chosen ones. -/
safety [positions_distinct] ∀ i, ∀ j, i < count → j < count → slotExpert i = slotExpert j → i = j
safety [chosen_at] chosen E ↔ ∃ i, i < count ∧ slotExpert i = E
/- The chosen experts come before every other, -/
safety [best] chosen E → ¬ chosen F → before E F
/- and a banned one is chosen only when every allowed one is. -/
safety [banned_only_when_needed] chosen E → banned E → ¬ banned F → chosen F

/-! Auxiliary invariants -/

invariant [count_bound] count ≤ k
/- The choice is in order. -/
invariant [ordered] ∀ i, ∀ j, i < j → j < count → before (slotExpert i) (slotExpert j)

#gen_spec

#gen_executable

#check_invariants

end Router
