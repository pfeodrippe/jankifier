/-!
# The attention kernels' softmax, exactly

What `attention` and `att_split`/`att_merge` (`native/kernels.metal`) compute,
in exact arithmetic: a running softmax per thread (its max `m`, its sum
`l = Σ exp(s - m)` and its weighted values `acc = Σ exp(s - m) v`), records
merged by rescaling them to a common max and adding them, and a sink logit
with a zero value added at the end. The theorems say that the result is the
softmax of the scores and the sink applied to the values and a zero, for any
way the keys are split among threads, simdgroups and chunks, any order within
each, and any choice of the maxes.

The maxes are only there to keep `exp` in range in floats: in exact
arithmetic any value works, so the theorems take the kernels' comparisons
(`s > m`) and their chosen maxes as arbitrary. Rounding is not covered here
(`inkling check` compares the GPU's values with the CPU's stage by stage).

The arithmetic is any field with a function `E` such that
`E (x + y) = E x * E y` and `E x ≠ 0`. The intended instance is ℝ with
`Real.exp`, but ℝ and `Real.exp` come from Mathlib, and the Lake project these
files are checked with (../../specs, Veil's `v4.35.0-veil-no-mathlib`) has no
Mathlib; with it, `Real.exp_add` and `Real.exp_ne_zero` are the two
hypotheses. The field structure is Lean core's `Lean.Grind.Field`. One more
hypothesis: the softmax's denominator (the sum of the exponentials of the
scores and of the sink) isn't zero, which in ℝ holds because `exp` is
positive.

A value is one coordinate of a value vector (the coordinates don't interact).
Keys are numbered; `sc j` and `v j` are key `j`'s score and value.
-/

set_option linter.unusedVariables false

namespace SoftmaxMerge

open Lean.Grind

/-- A running softmax record: the max `m`, the sum `l` and the weighted values `acc`. -/
structure Rec (α : Type) where
  m : α
  l : α
  acc : α

section

variable {α : Type} [Field α] (E : α → α) (sc v : Nat → α)

/-- `Σ_{j ∈ js} E (sc j - m)`. -/
def wsum (m : α) : List Nat → α
  | [] => 0
  | j :: js => E (sc j - m) + wsum m js

/-- `Σ_{j ∈ js} E (sc j - m) * v j`. -/
def vsum (m : α) : List Nat → α
  | [] => 0
  | j :: js => E (sc j - m) * v j + vsum m js

/-- A record stands for the keys `js`: its sum and weighted values are theirs,
relative to its max. -/
def Represents (r : Rec α) (js : List Nat) : Prop :=
  r.l = wsum E sc r.m js ∧ r.acc = vsum E sc v r.m js

/-- One key in a thread's loop, as the kernels write it:
`if(s > m) { f = exp(m - s); l *= f; acc *= f; m = s; }
 pr = exp(s - m); l += pr; acc += pr * v;`
`gt s m` stands for `s > m`. -/
def step (gt : α → α → Bool) (r : Rec α) (j : Nat) : Rec α :=
  let r' : Rec α := if gt (sc j) r.m then ⟨sc j, r.l * E (r.m - sc j), r.acc * E (r.m - sc j)⟩ else r
  ⟨r'.m, r'.l + E (sc j - r'.m), r'.acc + E (sc j - r'.m) * v j⟩

/-- A thread's loop over its keys, from `r0` (the kernels start with
`m = -1e30, l = 0, acc = 0`). -/
def run (gt : α → α → Bool) (r0 : Rec α) (js : List Nat) : Rec α :=
  js.foldl (step E sc v gt) r0

def sumL (best : α) : List (Rec α) → α
  | [] => 0
  | r :: rs => r.l * E (r.m - best) + sumL best rs

def sumAcc (best : α) : List (Rec α) → α
  | [] => 0
  | r :: rs => r.acc * E (r.m - best) + sumAcc best rs

/-- Records merged at `best`: each rescaled by `exp(m - best)` and added
(`simd_sum` over a simdgroup's lanes, the threadgroup's merge of its
simdgroups, `att_split`'s merge, `att_merge`'s loop over the chunks). -/
def merge (best : α) (rs : List (Rec α)) : Rec α :=
  ⟨best, sumL E best rs, sumAcc E best rs⟩

/-- The output of a merged record with the sink logit `sk`, one more logit with
a zero value: `acc / (l + exp(sk - m))` (the gate is applied after). -/
def withSink (sk : α) (r : Rec α) : α :=
  r.acc / (r.l + E (sk - r.m))

end

section lemmas

variable {α : Type} [Field α] {E : α → α} {sc v : Nat → α}
  (hE : ∀ x y, E (x + y) = E x * E y) (hE0 : ∀ x, E x ≠ 0)

include hE hE0 in
theorem E_zero : E 0 = 1 := by
  have h := hE 0 0
  have h0 := hE0 0
  rw [show (0 : α) + 0 = 0 by grind] at h
  grind

include hE in
theorem E_sub (a b c : α) : E (a - c) = E (a - b) * E (b - c) := by
  rw [← hE]
  congr 1
  grind

include hE in
theorem wsum_shift (m m' : α) (js : List Nat) : wsum E sc m' js = wsum E sc m js * E (m - m') := by
  induction js with
  | nil => simp only [wsum]; grind
  | cons j js ih =>
    simp only [wsum]
    rw [ih, E_sub hE (sc j) m m']
    grind

include hE in
theorem vsum_shift (m m' : α) (js : List Nat) : vsum E sc v m' js = vsum E sc v m js * E (m - m') := by
  induction js with
  | nil => simp only [vsum]; grind
  | cons j js ih =>
    simp only [vsum]
    rw [ih, E_sub hE (sc j) m m']
    grind

theorem wsum_append (m : α) (as bs : List Nat) : wsum E sc m (as ++ bs) = wsum E sc m as + wsum E sc m bs := by
  induction as with
  | nil => simp [wsum]; grind
  | cons j js ih => simp only [List.cons_append, wsum]; rw [ih]; grind

theorem vsum_append (m : α) (as bs : List Nat) : vsum E sc v m (as ++ bs) = vsum E sc v m as + vsum E sc v m bs := by
  induction as with
  | nil => simp [vsum]; grind
  | cons j js ih => simp only [List.cons_append, vsum]; rw [ih]; grind

theorem wsum_perm (m : α) {as bs : List Nat} (h : as.Perm bs) : wsum E sc m as = wsum E sc m bs := by
  induction h with
  | nil => rfl
  | cons x _ ih => simp only [wsum]; rw [ih]
  | swap x y l => simp only [wsum]; grind
  | trans _ _ ih1 ih2 => rw [ih1, ih2]

theorem vsum_perm (m : α) {as bs : List Nat} (h : as.Perm bs) : vsum E sc v m as = vsum E sc v m bs := by
  induction h with
  | nil => rfl
  | cons x _ ih => simp only [vsum]; rw [ih]
  | swap x y l => simp only [vsum]; grind
  | trans _ _ ih1 ih2 => rw [ih1, ih2]

/-- A record of no keys, whatever its max (the kernels' `-1e30`). -/
theorem represents_empty (m0 : α) : Represents E sc v ⟨m0, 0, 0⟩ [] := by
  simp [Represents, wsum, vsum]

include hE hE0 in
/-- One step of a thread's loop adds its key, whatever the comparison says. -/
theorem represents_step (gt : α → α → Bool) {r : Rec α} {js : List Nat} (h : Represents E sc v r js) (j : Nat) :
    Represents E sc v (step E sc v gt r j) (js ++ [j]) := by
  obtain ⟨hl, hacc⟩ := h
  have e0 := E_zero hE hE0
  unfold step
  split
  · simp only [Represents, wsum_append, vsum_append, wsum, vsum]
    rw [wsum_shift hE r.m (sc j) js, vsum_shift hE r.m (sc j) js, ← hl, ← hacc]
    rw [show sc j - sc j = (0 : α) by grind, e0]
    grind
  · simp only [Represents, wsum_append, vsum_append, wsum, vsum]
    rw [← hl, ← hacc]
    grind

include hE hE0 in
/-- A thread's whole loop. -/
theorem represents_run (gt : α → α → Bool) (ks : List Nat) :
    ∀ {r : Rec α} {js : List Nat}, Represents E sc v r js → Represents E sc v (run E sc v gt r ks) (js ++ ks) := by
  induction ks with
  | nil => intro r js h; simpa [run] using h
  | cons k ks ih =>
    intro r js h
    have h1 := represents_step hE hE0 gt h k
    have h2 := ih h1
    simpa [run, List.foldl] using h2

include hE in
/-- Records of disjoint key lists, merged at any max, stand for all their keys. -/
theorem represents_merge (best : α) :
    ∀ (ps : List (Rec α × List Nat)), (∀ p ∈ ps, Represents E sc v p.1 p.2) →
      Represents E sc v (merge E best (ps.map Prod.fst)) (ps.map Prod.snd).flatten := by
  intro ps
  induction ps with
  | nil => intro _; simp [merge, Represents, sumL, sumAcc, wsum, vsum]
  | cons p ps ih =>
    intro h
    have hp := h p (by simp)
    have hs := ih (fun q hq => h q (by simp [hq]))
    obtain ⟨hl, hacc⟩ := hp
    obtain ⟨hsl, hsacc⟩ := hs
    simp only [merge, Represents, List.map_cons, sumL, sumAcc, List.flatten_cons, wsum_append, vsum_append] at *
    rw [← hsl, ← hsacc, hl, hacc, wsum_shift hE p.1.m best, vsum_shift hE p.1.m best]
    exact ⟨rfl, rfl⟩

include hE hE0 in
/-- A record standing for `ks`, with the sink: the softmax of the scores of
`ks` and the sink, applied to their values and a zero. -/
theorem withSink_eq (sk : α) {r : Rec α} {ks : List Nat} (h : Represents E sc v r ks)
    (hden : wsum E sc 0 ks + E sk ≠ 0) :
    withSink E sk r = vsum E sc v 0 ks / (wsum E sc 0 ks + E sk) := by
  obtain ⟨hl, hacc⟩ := h
  have c := hE0 (0 - r.m)
  have hs : E (sk - r.m) = E (sk - 0) * E (0 - r.m) := E_sub hE sk 0 r.m
  rw [show sk - (0 : α) = sk by grind] at hs
  unfold withSink
  rw [hl, hacc, wsum_shift hE 0 r.m, vsum_shift hE 0 r.m, hs]
  grind

end lemmas

/-! ## Splitting keys among threads -/

/-- The keys of a list of key indices that a thread `t` of `n` takes when
thread `t` takes every key `j` with `f j = t`: in their order. -/
def share (f : Nat → Nat) (xs : List Nat) (t : Nat) : List Nat :=
  xs.filter (fun x => f x == t)

theorem sum_zero_of_all {l : List Nat} (h : ∀ x ∈ l, x = 0) : l.sum = 0 := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    rw [List.sum_cons, h x (by simp), ih (fun y hy => h y (by simp [hy]))]

theorem sum_range_ite (n c a : Nat) (ha : a < n) :
    ((List.range n).map (fun t => if a = t then c else 0)).sum = c := by
  induction n with
  | zero => omega
  | succ n ih =>
    rw [List.range_succ, List.map_append, List.sum_append]
    by_cases h : a = n
    · subst h
      have : ((List.range a).map (fun t => if a = t then c else 0)).sum = 0 := by
        apply sum_zero_of_all
        intro x hx
        simp only [List.mem_map, List.mem_range] at hx
        obtain ⟨t, ht, rfl⟩ := hx
        simp only [ite_eq_right_iff]
        omega
      simp [this]
    · rw [ih (by omega)]
      simp [h]

/-- Every thread's share together are the keys, in some order, when each key
goes to one thread `f j < n`. -/
theorem shares_perm (f : Nat → Nat) (n : Nat) (xs : List Nat) (hf : ∀ x ∈ xs, f x < n) :
    ((List.range n).map (share f xs)).flatten.Perm xs := by
  rw [List.perm_iff_count]
  intro a
  rw [List.count_flatten, List.map_map]
  by_cases hm : a ∈ xs
  · have hlt := hf a hm
    have : ∀ t, (List.count a ∘ share f xs) t = if f a = t then List.count a xs else 0 := by
      intro t
      simp only [Function.comp, share]
      split
      · rw [List.count_filter]
        simp [*]
      · rw [List.count_eq_zero]
        simp only [List.mem_filter, beq_iff_eq]
        rintro ⟨_, h⟩
        omega
    rw [List.map_congr_left (fun t _ => this t), sum_range_ite n _ _ hlt]
  · have h0 : List.count a xs = 0 := List.count_eq_zero.mpr hm
    rw [h0]
    apply sum_zero_of_all
    intro x hx
    simp only [List.mem_map, List.mem_range, Function.comp] at hx
    obtain ⟨t, _, rfl⟩ := hx
    rw [List.count_eq_zero]
    simp only [share, List.mem_filter]
    intro h
    exact hm h.1

/-! ## The chunks of `att_split` -/

/-- Chunk `s` of `att_split`: keys `[s * chunk, min ((s + 1) * chunk, keys))`
(`begin = split * chunk; end = min(begin + chunk, p + 1)`). -/
def chunkKeys (keys chunk s : Nat) : List Nat :=
  List.range' (s * chunk) (min ((s + 1) * chunk) keys - s * chunk)

theorem chunks_flatten (keys chunk : Nat) :
    ∀ splits, ((List.range splits).map (chunkKeys keys chunk)).flatten = List.range' 0 (min (splits * chunk) keys) := by
  intro splits
  induction splits with
  | zero => simp
  | succ n ih =>
    rw [List.range_succ, List.map_append, List.flatten_append, ih]
    simp only [List.map_cons, List.map_nil, List.flatten_cons, List.flatten_nil, List.append_nil, chunkKeys]
    by_cases h : n * chunk ≤ keys
    · have hs : min (n * chunk) keys = n * chunk := Nat.min_eq_left h
      rw [hs]
      have := @List.range'_append 0 (n * chunk) (min ((n + 1) * chunk) keys - n * chunk) 1
      simp only [Nat.zero_add, Nat.one_mul] at this
      rw [this]
      congr 1
      have : n * chunk ≤ min ((n + 1) * chunk) keys := by
        rw [Nat.succ_mul]; omega
      omega
    · have hs : min (n * chunk) keys = keys := by omega
      have hz : min ((n + 1) * chunk) keys - n * chunk = 0 := by rw [Nat.succ_mul]; omega
      rw [hs, hz]
      simp only [List.range'_zero, List.append_nil]
      congr 1
      rw [Nat.succ_mul]; omega

/-- `att_split`'s chunks are the keys `0 .. keys - 1`, in order, when
`keys ≤ splits * chunk` (the engine's `chunk = ceil(keys / splits)`). -/
theorem chunks_cover (keys chunk splits : Nat) (h : keys ≤ splits * chunk) :
    ((List.range splits).map (chunkKeys keys chunk)).flatten = List.range keys := by
  rw [chunks_flatten, Nat.min_eq_right h, List.range_eq_range']

/-- The engine's `splits` and `chunk` (`metal.mm`): `splits = min(64, keys / 512)`,
`chunk = ceil(keys / splits)`, used when `keys ≥ 1024`. They cover the keys,
and no chunk is empty. -/
theorem engine_chunks (keys : Nat) (h : 1024 ≤ keys) :
    let splits := min 64 (keys / 512)
    let chunk := (keys + splits - 1) / splits
    2 ≤ splits ∧ keys ≤ splits * chunk ∧ ∀ s, s < splits → s * chunk < min ((s + 1) * chunk) keys := by
  intro splits chunk
  have hs2 : 2 ≤ splits := by simp only [splits]; omega
  have hsk : splits * 512 ≤ keys := by simp only [splits]; omega
  have hcover : keys ≤ splits * chunk := by
    simp only [chunk]
    have := Nat.div_add_mod (keys + splits - 1) splits
    have := Nat.mod_lt (keys + splits - 1) (show 0 < splits by omega)
    omega
  have hchunk : 512 ≤ chunk := by
    simp only [chunk]
    apply (Nat.le_div_iff_mul_le (by omega)).mpr
    omega
  refine ⟨hs2, hcover, ?_⟩
  intro s hs
  have hlt : s * chunk < keys := by
    -- (splits - 1) * chunk < keys: chunk ≤ keys / splits + 1, and splits * (splits - 1) < keys.
    have hc : chunk * splits ≤ keys + splits - 1 := by
      simp only [chunk]
      exact Nat.div_mul_le_self _ _
    have h1 : s * chunk ≤ (splits - 1) * chunk := Nat.mul_le_mul_right _ (by omega)
    have h2 : (splits - 1) * chunk + chunk ≤ keys + splits - 1 := by
      rw [← Nat.succ_mul, Nat.succ_eq_add_one, Nat.sub_add_cancel (by omega), Nat.mul_comm]; exact hc
    omega
  have : s * chunk < (s + 1) * chunk := by rw [Nat.succ_mul]; omega
  omega

/-- What `SplitAttention.lean` assumes of the chunks, for the engine's
`chunk` (`keys ≤ splits * chunk`, `0 < chunk`): every key is in the chunk
`j / chunk`, chunks don't overlap, they end at `keys` at the latest, and the
simdgroup `(j - begin) % 8` of a chunk takes key `j`. -/
theorem chunk_owner (keys chunk splits j : Nat) (hc : 0 < chunk) (hcover : keys ≤ splits * chunk) (hj : j < keys) :
    j / chunk < splits ∧ j / chunk * chunk ≤ j ∧ j < min ((j / chunk + 1) * chunk) keys := by
  have h1 := Nat.div_mul_le_self j chunk
  have h2 : j < (j / chunk + 1) * chunk := by
    rw [Nat.succ_mul]
    have e1 := Nat.div_add_mod j chunk
    have e2 := Nat.mod_lt j hc
    have e3 : j / chunk * chunk = chunk * (j / chunk) := Nat.mul_comm _ _
    omega
  refine ⟨?_, h1, ?_⟩
  · apply Nat.lt_of_not_le
    intro hs
    have : splits * chunk ≤ j / chunk * chunk := Nat.mul_le_mul_right _ hs
    omega
  · omega

theorem chunk_disjoint (chunk s t j : Nat) (hs : s * chunk ≤ j ∧ j < (s + 1) * chunk)
    (ht : t * chunk ≤ j ∧ j < (t + 1) * chunk) : s = t := by
  rcases Nat.lt_trichotomy s t with h | h | h
  · have : (s + 1) * chunk ≤ t * chunk := Nat.mul_le_mul_right _ h
    omega
  · exact h
  · have : (t + 1) * chunk ≤ s * chunk := Nat.mul_le_mul_right _ h
    omega

theorem chunk_inside (keys chunk s : Nat) : min ((s + 1) * chunk) keys ≤ keys := Nat.min_le_right _ _

theorem simdgroup_of (b j : Nat) (h : b ≤ j) : (j - b) % 8 < 8 ∧ (b + (j - b) % 8) % 8 = j % 8 := by
  omega

/-- A key `j ≥ begin` of a chunk is the `(j - begin) / 8`-th key of simdgroup
`(j - begin) % 8`: `j = begin + g + 8 * pos`, the form `SplitAttention.lean`
assumes. Two such forms with simdgroups below 8 are the same. -/
theorem strided_repr (b j : Nat) (h : b ≤ j) : j = b + (j - b) % 8 + 8 * ((j - b) / 8) := by
  omega

/-- A simdgroup's loop `for(j = b + g; j < e; j += 8)` runs `(e - b - g + 7) / 8`
times: its `s`-th address is below `e` iff `s` is below that. -/
theorem strided_len (b e g s : Nat) (hg : g < 8) : b + g + 8 * s < e ↔ s < (e - b - g + 7) / 8 := by
  omega

theorem strided_unique (b g g' p p' : Nat) (hg : g < 8) (hg' : g' < 8) (h : b + g + 8 * p = b + g' + 8 * p') :
    g = g' ∧ p = p' := by
  omega

/-! ## The kernels -/

section kernels

variable {α : Type} [Field α] {E : α → α} {sc v : Nat → α}
  (hE : ∀ x y, E (x + y) = E x * E y) (hE0 : ∀ x, E x ≠ 0)

/-- The records of a list of threads, each running over its share of `xs`. -/
def threadRecords (E : α → α) (sc v : Nat → α) (gt : α → α → Bool) (m0 : α) (f : Nat → Nat) (n : Nat)
    (xs : List Nat) : List (Rec α × List Nat) :=
  (List.range n).map fun t => (run E sc v gt ⟨m0, 0, 0⟩ (share f xs t), share f xs t)

include hE hE0 in
theorem threadRecords_represent (gt : α → α → Bool) (m0 : α) (f : Nat → Nat) (n : Nat) (xs : List Nat) :
    ∀ p ∈ threadRecords E sc v gt m0 f n xs, Represents E sc v p.1 p.2 := by
  intro p hp
  simp only [threadRecords, List.mem_map] at hp
  obtain ⟨t, _, rfl⟩ := hp
  simpa using represents_run hE hE0 gt (share f xs t) (represents_empty (sc := sc) (v := v) (E := E) m0)

include hE hE0 in
/-- `attention`: the keys `first .. p` (`xs`), split among `n` threads
(`n = 32 NSG`), thread `t` taking the keys `j` with `(j - first) % n = t` in
increasing order (`for(j = first + tid; j <= p; j += nth)`), each with its
running softmax from `m0`; then all the threads' records merged at `best` (the
kernel merges a simdgroup's lanes with `simd_sum` and the simdgroups through
threadgroup memory, at the same max), and the sink. The result is the
softmax of the keys' scores and the sink applied to their values and a zero,
for any `n`, maxes and comparisons. -/
theorem attention_exact (gt : α → α → Bool) (m0 best sk : α) (first p n : Nat) (hn : 0 < n)
    (hden : wsum E sc 0 (List.range' first (p + 1 - first)) + E sk ≠ 0) :
    let xs := List.range' first (p + 1 - first)
    withSink E sk (merge E best ((threadRecords E sc v gt m0 (fun j => (j - first) % n) n xs).map Prod.fst))
      = vsum E sc v 0 xs / (wsum E sc 0 xs + E sk) := by
  intro xs
  have hrep := represents_merge (sc := sc) (v := v) hE best _ (threadRecords_represent hE hE0 gt m0 (fun j => (j - first) % n) n xs)
  have hperm : ((threadRecords E sc v gt m0 (fun j => (j - first) % n) n xs).map Prod.snd).flatten.Perm xs := by
    simp only [threadRecords, List.map_map]
    exact shares_perm _ n xs (fun x _ => Nat.mod_lt _ hn)
  have hrep' : Represents E sc v (merge E best ((threadRecords E sc v gt m0 (fun j => (j - first) % n) n xs).map Prod.fst)) xs := by
    obtain ⟨h1, h2⟩ := hrep
    exact ⟨h1.trans (wsum_perm _ hperm), h2.trans (vsum_perm _ hperm)⟩
  exact withSink_eq hE hE0 sk hrep' hden

/-- `att_split`'s record of chunk `s`: its simdgroups (`nsg` of them, simdgroup
`g` taking the chunk's keys `j` with `(j - begin) % nsg = g`, in increasing
order), merged at `best s`. -/
def chunkRecord (E : α → α) (sc v : Nat → α) (gt : α → α → Bool) (m0 : α) (nsg keys chunk : Nat)
    (best : Nat → α) (s : Nat) : Rec α :=
  merge E (best s) ((threadRecords E sc v gt m0 (fun j => (j - s * chunk) % nsg) nsg (chunkKeys keys chunk s)).map Prod.fst)

include hE hE0 in
theorem chunkRecord_represents (gt : α → α → Bool) (m0 : α) (nsg keys chunk : Nat) (hn : 0 < nsg)
    (best : Nat → α) (s : Nat) :
    Represents E sc v (chunkRecord E sc v gt m0 nsg keys chunk best s) (chunkKeys keys chunk s) := by
  have hrep := represents_merge (sc := sc) (v := v) hE (best s) _
    (threadRecords_represent hE hE0 gt m0 (fun j => (j - s * chunk) % nsg) nsg (chunkKeys keys chunk s))
  have hperm : ((threadRecords E sc v gt m0 (fun j => (j - s * chunk) % nsg) nsg (chunkKeys keys chunk s)).map
      Prod.snd).flatten.Perm (chunkKeys keys chunk s) := by
    simp only [threadRecords, List.map_map]
    exact shares_perm _ nsg _ (fun x _ => Nat.mod_lt _ hn)
  obtain ⟨h1, h2⟩ := hrep
  exact ⟨h1.trans (wsum_perm _ hperm), h2.trans (vsum_perm _ hperm)⟩

include hE hE0 in
/-- `att_split` then `att_merge`: the keys `0 .. keys - 1` in `splits` chunks
of `chunk` keys (`keys ≤ splits * chunk`), each chunk's simdgroups merged into
its record at `best s`, and the chunks' records merged at `bestAll` with the
sink. The result is the softmax of all the keys' scores and the sink applied
to their values and a zero: the same as `attention_exact`'s. -/
theorem split_attention_exact (gt : α → α → Bool) (m0 bestAll sk : α) (best : Nat → α)
    (nsg keys chunk splits : Nat) (hn : 0 < nsg) (hcover : keys ≤ splits * chunk)
    (hden : wsum E sc 0 (List.range keys) + E sk ≠ 0) :
    withSink E sk (merge E bestAll ((List.range splits).map (chunkRecord E sc v gt m0 nsg keys chunk best)))
      = vsum E sc v 0 (List.range keys) / (wsum E sc 0 (List.range keys) + E sk) := by
  let ps := (List.range splits).map fun s => (chunkRecord E sc v gt m0 nsg keys chunk best s, chunkKeys keys chunk s)
  have hrep := represents_merge (sc := sc) (v := v) hE bestAll ps (by
    intro p hp
    simp only [ps, List.mem_map] at hp
    obtain ⟨s, _, rfl⟩ := hp
    exact chunkRecord_represents hE hE0 gt m0 nsg keys chunk hn best s)
  have hfst : ps.map Prod.fst = (List.range splits).map (chunkRecord E sc v gt m0 nsg keys chunk best) := by
    simp [ps, List.map_map]
  have hsnd : (ps.map Prod.snd).flatten = List.range keys := by
    simp only [ps, List.map_map]
    exact chunks_cover keys chunk splits hcover
  rw [hfst, hsnd] at hrep
  exact withSink_eq hE hE0 sk hrep hden

include hE hE0 in
/-- Both kernels give the same result for one token at position `p` of a
global visit (keys `0 .. p`), whatever the split. -/
theorem split_equals_plain (gt : α → α → Bool) (m0 best bestAll sk : α) (bests : Nat → α)
    (n nsg chunk splits p : Nat) (hn : 0 < n) (hnsg : 0 < nsg) (hcover : p + 1 ≤ splits * chunk)
    (hden : wsum E sc 0 (List.range (p + 1)) + E sk ≠ 0) :
    withSink E sk (merge E bestAll ((List.range splits).map (chunkRecord E sc v gt m0 nsg (p + 1) chunk bests)))
      = withSink E sk (merge E best ((threadRecords E sc v gt m0 (fun j => (j - 0) % n) n
          (List.range' 0 (p + 1 - 0))).map Prod.fst)) := by
  rw [split_attention_exact hE hE0 gt m0 bestAll sk bests nsg (p + 1) chunk splits hnsg hcover hden]
  have hr : List.range' 0 (p + 1 - 0) = List.range (p + 1) := by simp [List.range_eq_range']
  have := attention_exact (v := v) hE hE0 gt m0 best sk 0 p n hn (by rw [hr]; exact hden)
  simp only at this
  rw [this, hr]

end kernels

end SoftmaxMerge

#print axioms SoftmaxMerge.attention_exact
#print axioms SoftmaxMerge.split_attention_exact
#print axioms SoftmaxMerge.split_equals_plain
#print axioms SoftmaxMerge.engine_chunks
#print axioms SoftmaxMerge.chunk_owner
#print axioms SoftmaxMerge.chunk_disjoint
#print axioms SoftmaxMerge.simdgroup_of
#print axioms SoftmaxMerge.strided_repr
#print axioms SoftmaxMerge.strided_unique
#print axioms SoftmaxMerge.strided_len
