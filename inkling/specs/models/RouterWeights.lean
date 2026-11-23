/-!
# The router's weights add up to the route scale

`native/cpu.cpp`, `experts`: the chosen experts' weights are
`p_j * (route_scale / Σ p)`, with `p_j = sigmoid(logit_j)` (the softmax of
`log sigmoid` over the chosen ones, scaled). In exact arithmetic they add up to
the route scale, whatever the `p`s, as long as their sum isn't zero (in ℝ,
`sigmoid` is positive). Over any field (Lean core's `Lean.Grind.Field`; ℝ is
in Mathlib, which the Lake project these files are checked with doesn't have).
-/

namespace RouterWeights

open Lean.Grind

variable {α : Type} [Field α]

def sum : List α → α
  | [] => 0
  | x :: xs => x + sum xs

def weights (rs : α) (ps : List α) : List α :=
  ps.map fun p => p * (rs / sum ps)

theorem sum_scaled (c : α) : ∀ ps : List α, sum (ps.map fun p => p * c) = sum ps * c := by
  intro ps
  induction ps with
  | nil => simp [sum]; grind
  | cons p ps ih => simp only [List.map_cons, sum]; rw [ih]; grind

/-- The weights add up to the route scale. -/
theorem weights_sum (rs : α) (ps : List α) (h : sum ps ≠ 0) : sum (weights rs ps) = rs := by
  unfold weights
  rw [sum_scaled]
  grind

/-- Normalized by the route scale, they add up to 1. -/
theorem normalized_sum (rs : α) (ps : List α) (h : sum ps ≠ 0) (hrs : rs ≠ 0) :
    sum ((weights rs ps).map fun w => w / rs) = 1 := by
  rw [show ((weights rs ps).map fun w => w / rs) = (weights rs ps).map (fun w => w * (1 / rs)) by
    congr 1; funext w; grind]
  rw [sum_scaled, weights_sum rs ps h]
  grind

end RouterWeights

#print axioms RouterWeights.weights_sum
#print axioms RouterWeights.normalized_sum
