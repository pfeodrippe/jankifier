module
public import Veil

/-!
# jank's atoms

A model of `swap!`, `reset!` and `compare-and-set!` on one atom, with a watch,
as jank 0.1 implements them (`compiler+runtime/src/cpp/jank/runtime/obj/atom.cpp`
at `f3d82d654`), with every thread's steps interleaved.

- `swap!` loops: load the value, call the function (here `inc`), validate,
  then `compare_exchange_weak`; on success it notifies the watches with the
  old and new value, on failure it starts again. `compare_exchange_weak` may
  fail even when the value matches (C++ allows it), which only costs a retry.
- `reset!` loads the old value, stores the new one, then notifies: not one
  atomic step.
- `compare-and-set!` is one `compare_exchange_weak`, so it can fail
  spuriously too, and then returns false although the value matched.
- Watches run after the update, outside any lock, so notifications from
  different threads can arrive in either order.

Each thread runs a small program, from the theory: some `swap!`s, then
optionally one `compare-and-set!` of what it last saw to that plus 10, or one
`reset!`.

The state uses only relations, functions and numbers (the watch's calls are a
numbered log, not a list), so that `#check_invariants` can prove C1 for any
number of threads and `swap!`s.
-/

-- The SMT solver's answers are turned into proofs which Lean's kernel checks.
set_option veil.smt.trust false

veil module Atom

type thread
/- Positions in the watch's log of calls: the first one, and the one after
each (the instances use `Fin n`, from 0, adding 1). -/
type slot

enum pc_t = { idle, loaded, notifying, resetting, done }

/- Each thread's program: how many `swap!`s, then `compare-and-set!`
(`casAfter`) or `reset!` to `resetTo t` (`resetAfter`), or nothing. -/
immutable function swaps : thread → Nat
immutable relation casAfter : thread → Bool
immutable relation resetAfter : thread → Bool
immutable function resetTo : thread → Nat
immutable individual focus : Nat
immutable individual firstSlot : slot
immutable function slotAfter : slot → slot

individual value : Nat
function pc : thread → pc_t
function swapsDone : thread → Nat
/- What the thread loaded (`swap!`, `reset!`), and the notification it owes. -/
function seen : thread → Nat
function notifyOld : thread → Nat
function notifyNew : thread → Nat
/- What each thread's last `swap!` returned, and its `compare-and-set!`. -/
function lastSwap : thread → Nat
relation casDone : thread → Bool
relation casOk : thread → Bool
/- `compare-and-set!` saw the value it expected and still failed. -/
relation casSpurious : thread → Bool
/- The watch's calls, in order: the call in slot `i` got the old value
`watchOld i` and the new value `watchNew i`; the slots before `nextSlot` are
used. -/
function watchOld : slot → Nat
function watchNew : slot → Nat
individual nextSlot : slot
individual calls : Nat
/- The last call's new value, and whether some call's old value wasn't the
previous call's new value. -/
individual lastNew : Nat
individual chainBroken : Bool
/- Successful updates by `swap!`, the largest value one returned, and
whether one returned a value no larger than an earlier one did. -/
individual totalSwaps : Nat
individual maxReturned : Nat
individual returnedStale : Bool

#gen_state

after_init {
  value := 0
  pc T := idle
  swapsDone T := 0
  seen T := 0
  lastSwap T := 0
  casDone T := false
  casOk T := false
  casSpurious T := false
  watchOld I := 0
  watchNew I := 0
  nextSlot := firstSlot
  calls := 0
  lastNew := 0
  chainBroken := false
  totalSwaps := 0
  maxReturned := 0
  returnedStale := false
}

/- The watch is called with `o` and `n`. -/
procedure record (o : Nat) (n : Nat) {
  chainBroken := decide (chainBroken ∨ (0 < calls ∧ o ≠ lastNew))
  watchOld nextSlot := o
  watchNew nextSlot := n
  nextSlot := slotAfter nextSlot
  calls := calls + 1
  lastNew := n
}

/- `swap!`: load the value. -/
action swapLoad (t : thread) {
  require pc t = idle ∧ swapsDone t < swaps t
  seen t := value
  pc t := loaded
}

/- `swap!`: `compare_exchange_weak` of `seen` to `seen + 1`. It fails if the
value changed, or spuriously (`spurious`); then the loop loads again. -/
action swapCas (t : thread) (spurious : Bool) {
  require pc t = loaded
  if value = seen t ∧ ¬ spurious then
    value := seen t + 1
    notifyOld t := seen t
    notifyNew t := seen t + 1
    lastSwap t := seen t + 1
    swapsDone t := swapsDone t + 1
    totalSwaps := totalSwaps + 1
    returnedStale := decide (returnedStale ∨ seen t + 1 ≤ maxReturned)
    if maxReturned < seen t + 1 then
      maxReturned := seen t + 1
    pc t := notifying
  else
    pc t := idle
}

/- The watch runs for the update. -/
action notify (t : thread) {
  require pc t = notifying
  record (notifyOld t) (notifyNew t)
  pc t := if swapsDone t < swaps t then idle else done
}

/- After its `swap!`s, `compare-and-set!` from the value it last saw (its last
swap's result) to that plus 10: one `compare_exchange_weak`. -/
action cas (t : thread) (spurious : Bool) {
  require (pc t = idle ∨ pc t = done) ∧ swapsDone t = swaps t ∧ casAfter t ∧ ¬ casDone t
  casDone t := true
  if value = lastSwap t ∧ ¬ spurious then
    value := lastSwap t + 10
    casOk t := true
    record (lastSwap t) (lastSwap t + 10)
  else
    if value = lastSwap t then
      casSpurious t := true
}

/- `reset!`: load the old value, then store and notify. -/
action resetLoad (t : thread) {
  require (pc t = idle ∨ pc t = done) ∧ swapsDone t = swaps t ∧ resetAfter t
  require ¬ (∃ T, T = t ∧ pc T = resetting)
  seen t := value
  pc t := resetting
}

action resetStore (t : thread) {
  require pc t = resetting
  value := resetTo t
  record (seen t) (resetTo t)
  pc t := done
}

/-! ## Properties -/

/- C1: without `reset!` and `compare-and-set!`, the value counts the
`swap!`s (no update is lost), and each `swap!` returns a larger value than
the ones which took effect before it, so no two return the same value. -/
safety [c1_swaps_are_atomic]
  (∀ T, ¬ casAfter T ∧ ¬ resetAfter T) → value = totalSwaps
safety [c1_swap_results_increase]
  (∀ T, ¬ casAfter T ∧ ¬ resetAfter T) → ¬ returnedStale
/- C2: `compare-and-set!` succeeds when the atom holds the expected value. -/
safety [c2_cas_succeeds_on_match] focus = 2 → ¬ casSpurious T
/- The watch sees the updates in order: each call's old value is the previous
call's new value. Not a requirement: `add-watch`'s docstring says the state may
have changed again before the call, and that watch fns may be called from
several threads at once; this property only checks the model allows it (and
the atom harness saw it on jank). -/
safety [watch_calls_chain] focus = 3 → ¬ chainBroken

/- Auxiliary invariants, which make C1 inductive: the largest value a `swap!`
returned is the number of `swap!`s, and only a thread doing `reset!` is in the
middle of one. -/
invariant [c1_max_returned]
  (∀ T, ¬ casAfter T ∧ ¬ resetAfter T) → maxReturned = totalSwaps
invariant [resetting_resets] pc T = resetting → resetAfter T

#gen_spec

/-! ## Proofs

C1 is proved for any number of threads and `swap!`s. `c2_cas_succeeds_on_match`
and `watch_calls_chain` are only required when `focus` is 2 or 3; they're
false there (the model checker below shows it), so their rows fail. That
doesn't weaken the other proofs: with `focus = 0` they hold trivially, so the
others are inductive on their own, and no action reads `focus`, so the
reachable states are the same for every `focus`. `#guard_msgs` pins the table
of results, so the build fails if any of them changes. -/

/--
info: Initialization must establish the invariant:
  doesNotThrow ... ✅
  c1_swaps_are_atomic ... ✅
  c1_swap_results_increase ... ✅
  c2_cas_succeeds_on_match ... ✅
  watch_calls_chain ... ✅
  c1_max_returned ... ✅
  resetting_resets ... ✅
The following set of actions must preserve the invariant and successfully terminate:
  swapLoad
    doesNotThrow ... ✅
    c1_swaps_are_atomic ... ✅
    c1_swap_results_increase ... ✅
    c2_cas_succeeds_on_match ... ✅
    watch_calls_chain ... ✅
    c1_max_returned ... ✅
    resetting_resets ... ✅
  resetStore
    doesNotThrow ... ✅
    c1_swaps_are_atomic ... ✅
    c1_swap_results_increase ... ✅
    c2_cas_succeeds_on_match ... ✅
    watch_calls_chain ... ❌
    c1_max_returned ... ✅
    resetting_resets ... ✅
  notify
    doesNotThrow ... ✅
    c1_swaps_are_atomic ... ✅
    c1_swap_results_increase ... ✅
    c2_cas_succeeds_on_match ... ✅
    watch_calls_chain ... ❌
    c1_max_returned ... ✅
    resetting_resets ... ✅
  resetLoad
    doesNotThrow ... ✅
    c1_swaps_are_atomic ... ✅
    c1_swap_results_increase ... ✅
    c2_cas_succeeds_on_match ... ✅
    watch_calls_chain ... ✅
    c1_max_returned ... ✅
    resetting_resets ... ✅
  cas
    doesNotThrow ... ✅
    c1_swaps_are_atomic ... ✅
    c1_swap_results_increase ... ✅
    c2_cas_succeeds_on_match ... ❌
    watch_calls_chain ... ❌
    c1_max_returned ... ✅
    resetting_resets ... ✅
  swapCas
    doesNotThrow ... ✅
    c1_swaps_are_atomic ... ✅
    c1_swap_results_increase ... ✅
    c2_cas_succeeds_on_match ... ✅
    watch_calls_chain ... ✅
    c1_max_returned ... ✅
    resetting_resets ... ✅
-/
#guard_msgs in
set_option veil.printCounterexamples false in
set_option veil.violationIsError false in
#check_invariants

/-! ## Model checking -/

-- Two threads with two `swap!`s each: no lost update.
#model_check { thread := Fin 2, slot := Fin 6 }
  { swaps := fun _ => 2, casAfter := fun _ => false, resetAfter := fun _ => false,
    resetTo := fun _ => 0, focus := 0, firstSlot := 0, slotAfter := fun i => i + 1 }

-- C2, on its own: `compare_exchange_weak` can fail with the expected value.
#guard_msgs (drop error) in
#model_check interpreted { thread := Fin 1, slot := Fin 6 }
  { swaps := fun _ => 1, casAfter := fun _ => true, resetAfter := fun _ => false,
    resetTo := fun _ => 0, focus := 2, firstSlot := 0, slotAfter := fun i => i + 1 } (sequential := true)

set_option veil.violationIsError false in
#model_check interpreted { thread := Fin 1, slot := Fin 6 }
  { swaps := fun _ => 1, casAfter := fun _ => true, resetAfter := fun _ => false,
    resetTo := fun _ => 0, focus := 2, firstSlot := 0, slotAfter := fun i => i + 1 } (sequential := true)

-- Watch order, on its own: two threads' `swap!`s notify out of order.
#guard_msgs (drop error) in
#model_check interpreted { thread := Fin 2, slot := Fin 6 }
  { swaps := fun _ => 1, casAfter := fun _ => false, resetAfter := fun _ => false,
    resetTo := fun _ => 0, focus := 3, firstSlot := 0, slotAfter := fun i => i + 1 } (sequential := true)

set_option veil.violationIsError false in
#model_check interpreted { thread := Fin 2, slot := Fin 6 }
  { swaps := fun _ => 1, casAfter := fun _ => false, resetAfter := fun _ => false,
    resetTo := fun _ => 0, focus := 3, firstSlot := 0, slotAfter := fun i => i + 1 } (sequential := true)

#gen_executable

end Atom
