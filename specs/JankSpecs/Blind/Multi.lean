module
public import Veil

/-!
# jank's multimethods

A blind model (see `PLAN.md`, phase 2, C2): MM1 to MM3 were written in
`PLAN.md` from the docstrings and Clojure's dispatch rules before this code was
read; the model follows jank 0.1 (`f3d82d654`,
`runtime/obj/multi_function.cpp`) step by step.

Programs are built by the model checker: any sequence of `derive`,
`defmethod` and `prefer-method` (up to `maxSetups` of them), with calls in
between. A call (`get_method`, `:248`):

- `cached_hierarchy != hierarchy.deref()` resets the cache to the method table
  (`reset_cache`, `:136`). `reset_cache` stores `hierarchy` itself (the var
  `#'global-hierarchy`), not its value, so the comparison is between a var and
  a map, which always differs: the cache is reset on every call.
- The cache (the method table) has the dispatch value: that method.
- Else `find_and_cache_best_method` (`:262`) goes through the method table,
  in the hash map's order (unspecified, so any order here): for each entry
  whose key the value `isa?`, the entry becomes the best if there's none yet
  or it dominates the best; then if the best doesn't dominate the entry, it
  throws "Multiple methods ... neither is preferred". With no best, the
  `:default` method, else no method.
- "Dominates" (`is_dominant`, `:227`) is "preferred" or `isa?`. "Preferred"
  (`is_preferred`, `:185`) checks the prefer table, then recurses on the
  `parents` of each value, but it gets `cached_hierarchy`, the var: `(parents
  var tag)` is `(get (:parents var) tag)`, which is `nil`, so only direct
  preferences count.

Clojure's `MultiFn` runs the same loop, with `parents` of the hierarchy map,
so a preference declared on an ancestor counts. The model runs that loop too,
next to jank's, on the same order (the `C` fields), to tell jank's own
behaviour from what it inherited.

`prefer-method` (`:163`) throws if `y` is already preferred to `x`, checking
with the hierarchy's value, so there ancestors count.
-/

veil module Multi

type dval
enum phase_t = { idle, looping, done }
/- How a call ended: a method (`resKey`'s), the `:default` method, no
method, or "multiple methods". -/
enum res_t = { method, defaultMethod, noMethod, ambiguous }

/- The `:default` dispatch value, and how many setup steps a program has. -/
immutable individual defaultVal : dval
immutable individual maxSetups : Nat
immutable individual maxPrefs : Nat
immutable individual focus : Nat

/- The hierarchy (`isa` is its reflexive, transitive closure), the method
table and the prefer table. -/
relation isa : dval → dval → Bool
relation hasMethod : dval → Bool
relation pref : dval → dval → Bool
individual setups : Nat
individual prefs : Nat

/- The call in progress: its dispatch value, the entries seen so far, and
for jank's loop and Clojure's (`C`), the best entry so far and whether it
threw; then how it ended. -/
individual phase : phase_t
individual target : dval
relation visited : dval → Bool
individual hasBest : Bool
individual best : dval
individual threw : Bool
individual hasBestC : Bool
individual bestC : dval
individual threwC : Bool
individual res : res_t
individual resKey : dval
individual resC : res_t
individual resKeyC : dval

#gen_state

after_init {
  isa X Y := decide (X = Y)
  hasMethod X := false
  pref X Y := false
  setups := 0
  prefs := 0
  phase := idle
  target := defaultVal
  visited X := false
  hasBest := false
  best := defaultVal
  threw := false
  hasBestC := false
  bestC := defaultVal
  threwC := false
  res := noMethod
  resKey := defaultVal
  resC := noMethod
  resKeyC := defaultVal
}

/- Clojure's "prefers": a preference between ancestors (or the values
themselves). jank's dispatch only sees direct preferences. -/
ghost relation prefersC (x : dval) (y : dval) := ∃ X Y, isa x X ∧ isa y Y ∧ pref X Y
ghost relation domJ (x : dval) (y : dval) := pref x y ∨ isa x y
ghost relation domC (x : dval) (y : dval) := (∃ X Y, isa x X ∧ isa y Y ∧ pref X Y) ∨ isa x y
ghost relation matching (k : dval) := hasMethod k ∧ isa target k

/-! ## Setting up -/

/- `(derive x y)`: Clojure's checks (not already an ancestor, no cycle). -/
action derive (x : dval) (y : dval) {
  require phase = idle ∧ setups < maxSetups
  require x ≠ y ∧ x ≠ defaultVal ∧ y ≠ defaultVal ∧ ¬ isa x y ∧ ¬ isa y x
  isa A B := decide (isa A B ∨ (isa A x ∧ isa y B))
  setups := setups + 1
}

action defmethod (k : dval) {
  require phase = idle ∧ setups < maxSetups ∧ ¬ hasMethod k
  hasMethod k := true
  setups := setups + 1
}

/- `(prefer-method f x y)`; it throws (here: can't happen) if `y` is already
preferred to `x`. -/
action preferMethod (x : dval) (y : dval) {
  require phase = idle ∧ setups < maxSetups ∧ prefs < maxPrefs
  require x ≠ y ∧ ¬ pref x y ∧ ¬ (∃ X Y, isa y X ∧ isa x Y ∧ pref X Y)
  pref x y := true
  prefs := prefs + 1
  setups := setups + 1
}

/-! ## A call -/

/- `get_method`: the cache is reset to the method table; an exact match is
the method. -/
action call (v : dval) {
  require phase = idle
  target := v
  visited K := false
  hasBest := false
  threw := false
  hasBestC := false
  threwC := false
  if hasMethod v then
    res := method
    resKey := v
    resC := method
    resKeyC := v
    phase := done
  else
    phase := looping
}

/- `find_and_cache_best_method`: the next entry of the method table, in any
order. -/
action visit (k : dval) {
  require phase = looping ∧ hasMethod k ∧ ¬ visited k
  visited k := true
  if isa target k ∧ ¬ threw then
    if ¬ hasBest ∨ pref k best ∨ isa k best then
      best := k
      hasBest := true
    if ¬ (pref best k ∨ isa best k) then
      threw := true
  if isa target k ∧ ¬ threwC then
    if ¬ hasBestC ∨ (∃ X Y, isa k X ∧ isa bestC Y ∧ pref X Y) ∨ isa k bestC then
      bestC := k
      hasBestC := true
    if ¬ ((∃ X Y, isa bestC X ∧ isa k Y ∧ pref X Y) ∨ isa bestC k) then
      threwC := true
}

/- After the whole table: the best, or the `:default` method, or none. -/
action finish {
  require phase = looping ∧ ∀ K, hasMethod K → visited K
  if threw then
    res := ambiguous
  else
    if hasBest then
      res := method
      resKey := best
    else
      if hasMethod defaultVal then
        res := defaultMethod
      else
        res := noMethod
  if threwC then
    resC := ambiguous
  else
    if hasBestC then
      resC := method
      resKeyC := bestC
    else
      if hasMethod defaultVal then
        resC := defaultMethod
      else
        resC := noMethod
  phase := done
}

/- The call returned (or threw); the program goes on. -/
action next {
  require phase = done
  phase := idle
}

/-! ## Properties

MM1 to MM3 are from `PLAN.md`, written before the code was read. -/

/- MM1, MM2: a call uses the method of the matching dispatch value which
dominates every other matching one (`isa?` or preferred, by Clojure's rules);
`:default` or no method when none matches; "multiple methods" only when no
matching value dominates the others. MM3 is part of it: every call is checked
against the hierarchy, methods and preferences of that moment. -/
safety [mm1_dispatch]
  focus = 1 → (phase = done →
    ((res = method → (matching resKey ∧ ∀ K, matching K → domC resKey K)) ∧
     ((res = defaultMethod ∨ res = noMethod) → ∀ K, ¬ matching K) ∧
     (res = ambiguous → ¬ ∃ M, matching M ∧ ∀ K, matching K → domC M K)))

/- Added after reading the code (not blind): jank's loop ends like Clojure's
on the same order. -/
safety [mm_like_clojure]
  focus = 2 → (phase = done → (res = resC ∧ (res = method → resKey = resKeyC)))

#gen_spec

/-! ## Model checking

Five dispatch values (one is `:default`), programs of up to six setup steps
with at most one preference, and calls in between.

Without preferences, jank's loop is Clojure's (so `mm_like_clojure` holds),
and MM1 still fails: the loop's result depends on the method table's order,
in Clojure too. -/

#model_check { dval := Fin 5 } { defaultVal := 4, maxSetups := 6, maxPrefs := 0, focus := 2 }

#guard_msgs (drop error) in
#model_check { dval := Fin 5 } { defaultVal := 4, maxSetups := 6, maxPrefs := 0, focus := 1 }
set_option veil.violationIsError false in
#model_check { dval := Fin 5 } { defaultVal := 4, maxSetups := 6, maxPrefs := 0, focus := 1 }

-- With a preference, jank also differs from Clojure.

#guard_msgs (drop error) in
#model_check { dval := Fin 5 } { defaultVal := 4, maxSetups := 6, maxPrefs := 1, focus := 1 }
set_option veil.violationIsError false in
#model_check { dval := Fin 5 } { defaultVal := 4, maxSetups := 6, maxPrefs := 1, focus := 1 }

#guard_msgs (drop error) in
#model_check { dval := Fin 5 } { defaultVal := 4, maxSetups := 6, maxPrefs := 1, focus := 2 }
set_option veil.violationIsError false in
#model_check { dval := Fin 5 } { defaultVal := 4, maxSetups := 6, maxPrefs := 1, focus := 2 }

#gen_executable

end Multi
