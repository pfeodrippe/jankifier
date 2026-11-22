module
public import Veil

/-!
# jank's transients

A blind model (see `PLAN.md`, phase 2, C3): T3 and T6 were written in
`PLAN.md` from the docstrings before this code was read; the model follows
jank 0.1 (`f3d82d654`, `runtime/obj/transient_*.cpp`).

Each transient has an `active` flag, cleared by `persistent!`
(`to_persistent`). An operation throws on a finished transient only if its
method calls `assert_active` (directly, or through the method it calls);
that's the `checks` table, read off the code:

- vector (`transient_vector.cpp`): every operation, except `nth` with one
  argument (`:53`), `find` (`:198`) and `contains?` (`:217`), which read the
  data directly.
- array map (`transient_array_map.cpp`): every operation, except `get` with a
  fallback, `find`, `contains?`, and calling it with a fallback (which is `get`
  with a fallback). Its `to_persistent` moves its data into the result.
- hash map, sorted map, hash set, sorted set: every operation.

`pop!` on an empty vector throws before changing anything (`:229`).

`fixed` turns on a proposed fix of jank, to check it before it's written:

- `a2`: the seven methods which don't call `assert_active` call it, so every
  operation on a finished transient throws (the same as `checks` true for
  every operation).

T1, T2, T4 and T5 (the source, the result and other transients aren't
changed) are about immer's structural sharing, which this model doesn't
describe; `jank-specs.conformance.transients` tests them on jank against
Clojure.
-/

veil module Transients

type tr
enum kind_t = { vector, arrayMap, hashMap, hashSet, sortedMap, sortedSet }
enum op_t = { conjOp, assocOp, dissocOp, disjOp, popOp, persistentOp, countOp, getOp,
  getFallbackOp, nthOp, nthFallbackOp, containsOp, findOp, callOp, callFallbackOp }
enum out_t = { nothing, returned, threw }
/- The proposed fixes (see above). -/
enum fix_t = { a2 }

immutable function kindOf : tr → kind_t
/- The operations each kind has, and those which check `active`. -/
immutable relation supported : kind_t → op_t → Bool
immutable relation checks : kind_t → op_t → Bool
immutable individual focus : Nat
immutable relation fixed : fix_t → Bool

relation active : tr → Bool
function size : tr → Nat
/- The last operation: on which transient, whether it was active, its size
before, and how it ended. -/
individual lastTr : tr
individual lastOp : op_t
individual lastWasActive : Bool
individual lastSize : Nat
individual lastOut : out_t

#gen_state

after_init {
  active T := true
  size T := 0
  lastOp := countOp
  lastWasActive := true
  lastSize := 0
  lastOut := nothing
}

action apply (t : tr) (o : op_t) {
  require supported (kindOf t) o
  require size t < 2
  lastTr := t
  lastOp := o
  lastWasActive := active t
  lastSize := size t
  if ¬ active t then
    if checks (kindOf t) o ∨ fixed a2 then
      lastOut := threw
    else
      -- Reads the data the result was made from (or moved from).
      lastOut := returned
  else
    if o = persistentOp then
      active t := false
      lastOut := returned
    else
      if o = popOp then
        if size t = 0 then
          lastOut := threw
        else
          size t := size t - 1
          lastOut := returned
      else
        if o = conjOp ∨ o = assocOp then
          size t := size t + 1
          lastOut := returned
        else
          if o = dissocOp ∧ kindOf t = vector then
            -- `dissoc!` isn't supported on a vector.
            lastOut := threw
          else
            lastOut := returned
}

/-! ## Properties

T3 and T6 are from `PLAN.md`, written before the code was read. -/

/- T3: every operation on a transient after `persistent!` throws. -/
safety [t3_finished_transient_throws]
  focus = 3 → (lastOut ≠ nothing ∧ ¬ lastWasActive → lastOut = threw)
/- T6: `pop!` on an empty transient vector throws, and leaves it usable. -/
safety [t6_pop_empty]
  (lastOut ≠ nothing ∧ lastOp = popOp ∧ lastWasActive ∧ lastSize = 0) →
    (lastOut = threw ∧ active lastTr)

#gen_spec

/-! ## Model checking

One transient of each kind, with the operations and checks of the code: T6
holds, T3 doesn't. -/

#model_check { tr := Fin 6 }
  { kindOf := fun t => match t.val with
      | 0 => kind_t_IndT.vector | 1 => kind_t_IndT.arrayMap | 2 => kind_t_IndT.hashMap
      | 3 => kind_t_IndT.hashSet | 4 => kind_t_IndT.sortedMap | _ => kind_t_IndT.sortedSet,
    supported := fun k o => match k, o with
      | .vector, .disjOp | .vector, .callFallbackOp => false
      | .vector, _ => true
      | .hashSet, .assocOp | .hashSet, .dissocOp | .hashSet, .popOp | .hashSet, .nthOp
      | .hashSet, .nthFallbackOp | .hashSet, .findOp => false
      | .sortedSet, .assocOp | .sortedSet, .dissocOp | .sortedSet, .popOp | .sortedSet, .nthOp
      | .sortedSet, .nthFallbackOp | .sortedSet, .findOp => false
      | .hashSet, _ | .sortedSet, _ => true
      | _, .disjOp | _, .popOp | _, .nthOp | _, .nthFallbackOp => false
      | _, _ => true,
    checks := fun k o => match k, o with
      | .vector, .nthOp | .vector, .findOp | .vector, .containsOp => false
      | .arrayMap, .getFallbackOp | .arrayMap, .findOp | .arrayMap, .containsOp
      | .arrayMap, .callFallbackOp => false
      | _, _ => true,
    focus := 0, fixed := fun _ => false }

#guard_msgs (drop error) in
#model_check { tr := Fin 6 }
  { kindOf := fun t => match t.val with
      | 0 => kind_t_IndT.vector | 1 => kind_t_IndT.arrayMap | 2 => kind_t_IndT.hashMap
      | 3 => kind_t_IndT.hashSet | 4 => kind_t_IndT.sortedMap | _ => kind_t_IndT.sortedSet,
    supported := fun k o => match k, o with
      | .vector, .disjOp | .vector, .callFallbackOp => false
      | .vector, _ => true
      | .hashSet, .assocOp | .hashSet, .dissocOp | .hashSet, .popOp | .hashSet, .nthOp
      | .hashSet, .nthFallbackOp | .hashSet, .findOp => false
      | .sortedSet, .assocOp | .sortedSet, .dissocOp | .sortedSet, .popOp | .sortedSet, .nthOp
      | .sortedSet, .nthFallbackOp | .sortedSet, .findOp => false
      | .hashSet, _ | .sortedSet, _ => true
      | _, .disjOp | _, .popOp | _, .nthOp | _, .nthFallbackOp => false
      | _, _ => true,
    checks := fun k o => match k, o with
      | .vector, .nthOp | .vector, .findOp | .vector, .containsOp => false
      | .arrayMap, .getFallbackOp | .arrayMap, .findOp | .arrayMap, .containsOp
      | .arrayMap, .callFallbackOp => false
      | _, _ => true,
    focus := 3, fixed := fun _ => false } (sequential := true)
set_option veil.violationIsError false in
#model_check { tr := Fin 6 }
  { kindOf := fun t => match t.val with
      | 0 => kind_t_IndT.vector | 1 => kind_t_IndT.arrayMap | 2 => kind_t_IndT.hashMap
      | 3 => kind_t_IndT.hashSet | 4 => kind_t_IndT.sortedMap | _ => kind_t_IndT.sortedSet,
    supported := fun k o => match k, o with
      | .vector, .disjOp | .vector, .callFallbackOp => false
      | .vector, _ => true
      | .hashSet, .assocOp | .hashSet, .dissocOp | .hashSet, .popOp | .hashSet, .nthOp
      | .hashSet, .nthFallbackOp | .hashSet, .findOp => false
      | .sortedSet, .assocOp | .sortedSet, .dissocOp | .sortedSet, .popOp | .sortedSet, .nthOp
      | .sortedSet, .nthFallbackOp | .sortedSet, .findOp => false
      | .hashSet, _ | .sortedSet, _ => true
      | _, .disjOp | _, .popOp | _, .nthOp | _, .nthFallbackOp => false
      | _, _ => true,
    checks := fun k o => match k, o with
      | .vector, .nthOp | .vector, .findOp | .vector, .containsOp => false
      | .arrayMap, .getFallbackOp | .arrayMap, .findOp | .arrayMap, .containsOp
      | .arrayMap, .callFallbackOp => false
      | _, _ => true,
    focus := 3, fixed := fun _ => false } (sequential := true)

-- T3 with the fix `a2`: no violation.
#model_check { tr := Fin 6 }
  { kindOf := fun t => match t.val with
      | 0 => kind_t_IndT.vector | 1 => kind_t_IndT.arrayMap | 2 => kind_t_IndT.hashMap
      | 3 => kind_t_IndT.hashSet | 4 => kind_t_IndT.sortedMap | _ => kind_t_IndT.sortedSet,
    supported := fun k o => match k, o with
      | .vector, .disjOp | .vector, .callFallbackOp => false
      | .vector, _ => true
      | .hashSet, .assocOp | .hashSet, .dissocOp | .hashSet, .popOp | .hashSet, .nthOp
      | .hashSet, .nthFallbackOp | .hashSet, .findOp => false
      | .sortedSet, .assocOp | .sortedSet, .dissocOp | .sortedSet, .popOp | .sortedSet, .nthOp
      | .sortedSet, .nthFallbackOp | .sortedSet, .findOp => false
      | .hashSet, _ | .sortedSet, _ => true
      | _, .disjOp | _, .popOp | _, .nthOp | _, .nthFallbackOp => false
      | _, _ => true,
    checks := fun k o => match k, o with
      | .vector, .nthOp | .vector, .findOp | .vector, .containsOp => false
      | .arrayMap, .getFallbackOp | .arrayMap, .findOp | .arrayMap, .containsOp
      | .arrayMap, .callFallbackOp => false
      | _, _ => true,
    focus := 3, fixed := fun _ => true }

#gen_executable

end Transients
