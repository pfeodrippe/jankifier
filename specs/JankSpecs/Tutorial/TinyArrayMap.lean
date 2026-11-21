module
public import Veil

/-!
# Tutorial: jank's array map transients, in small

The example of `specs/TUTORIAL.md`: `Blind/ArrayMap.lean` cut down to maps of
one entry, in arrays of one slot. A map points to an array; `transient` in
jank 0.1 copies the pointer, not the array (`copyOnTransient = false`).
-/

veil module TinyArrayMap

type obj
type arr
type key
type val

/- The fix: `transient` copies the array. jank 0.1 doesn't. -/
immutable relation copyOnTransient : Bool

relation used : obj → Bool
relation persistentMap : obj → Bool
relation finished : obj → Bool
/- `points o a`: map `o` points to array `a`. `slot a k v`: `a` holds `k v`. -/
relation points : obj → arr → Bool
relation arrUsed : arr → Bool
relation slot : arr → key → val → Bool
/- What each map should hold: the meaning, for the property (not in jank). -/
relation should : obj → key → val → Bool

#gen_state

after_init {
  used O := false
  persistentMap O := false
  finished O := false
  points O A := false
  arrUsed A := false
  slot A K V := false
  should O K V := false
}

/- `{k v}`: a new persistent map, in a new array. -/
action literal (o : obj) (a : arr) (k : key) (v : val) {
  require ¬ used o ∧ ¬ arrUsed a
  used o := true
  persistentMap o := true
  arrUsed a := true
  points o A := decide (A = a)
  slot a K V := decide (K = k ∧ V = v)
  should o K V := decide (K = k ∧ V = v)
}

/- `(transient p)`: jank shares `p`'s array; the fix copies it into `a`. -/
action transient (p : obj) (t : obj) (a : arr) {
  require used p ∧ persistentMap p ∧ ¬ used t ∧ ¬ arrUsed a
  used t := true
  if copyOnTransient then
    arrUsed a := true
    slot a K V := decide (∃ B, points p B ∧ slot B K V)
    points t A := decide (A = a)
  else
    points t A := points p A
  should t K V := should p K V
}

/- `(assoc! t k v)` when `k` is there: the value is overwritten in place. -/
action assocBang (t : obj) (k : key) (v : val) {
  require used t ∧ ¬ persistentMap t ∧ ¬ finished t
  require ∃ A V, points t A ∧ slot A k V
  slot A K V := decide ((points t A ∧ K = k ∧ V = v) ∨ (¬ points t A ∧ slot A K V))
  should t K V := decide (K = k ∧ V = v)
}

/- `(persistent! t)`: the result points to `t`'s array. -/
action persistentBang (t : obj) (q : obj) {
  require used t ∧ ¬ persistentMap t ∧ ¬ finished t ∧ ¬ used q
  finished t := true
  used q := true
  persistentMap q := true
  points q A := points t A
  should q K V := should t K V
}

/- From `transient`'s docstring: "Returns a new, transient version of the
collection": a persistent map always holds what it should. -/
safety [maps_hold_what_they_should]
  persistentMap O → ((∃ A, points O A ∧ slot A K V) ↔ should O K V)

#gen_spec

-- jank 0.1: a counterexample.
set_option veil.violationIsError false in
#model_check { obj := Fin 3, arr := Fin 3, key := Fin 1, val := Fin 2 }
  { copyOnTransient := false }

-- The fix: no violation.
#model_check { obj := Fin 3, arr := Fin 3, key := Fin 1, val := Fin 2 }
  { copyOnTransient := true }

end TinyArrayMap
