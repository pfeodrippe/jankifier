module
public import Veil

/-!
# Tutorial: jank's `swap!`, proved

The proof example of `specs/TUTORIAL.md`: `Concurrency/Atom.lean` cut down to
`swap! inc`. `swap!` loads the value, then `compare_exchange_weak`s it to that
plus one; if the atom changed meanwhile, it starts again (`obj/atom.cpp:81`).
-/

-- The SMT solver's answers are turned into proofs which Lean's kernel checks.
set_option veil.smt.trust false

veil module TinyAtom

type thread
enum pc_t = { idle, loaded, done }

individual value : Nat
function pc : thread → pc_t
function seen : thread → Nat
/- Ghost state, for the properties (not in jank): how many `swap!`s took
effect, the largest value one returned, and whether one returned a value no
larger than an earlier one did. -/
individual swaps : Nat
individual maxReturned : Nat
individual stale : Bool

#gen_state

after_init {
  value := 0
  pc T := idle
  seen T := 0
  swaps := 0
  maxReturned := 0
  stale := false
}

/- Read the atom. -/
action load (t : thread) {
  require pc t = idle
  seen t := value
  pc t := loaded
}

/- Compare-and-set: store what was read plus one only if the atom still holds
what was read; otherwise go back and read again. -/
action cas (t : thread) {
  require pc t = loaded
  if value = seen t then
    value := seen t + 1
    swaps := swaps + 1
    stale := decide (stale ∨ seen t + 1 ≤ maxReturned)
    if maxReturned < seen t + 1 then
      maxReturned := seen t + 1
    pc t := done
  else
    pc t := idle
}

/- No update is lost. -/
safety [no_lost_update] value = swaps
/- Each `swap!` returns more than every `swap!` before it. -/
safety [results_increase] ¬ stale

/- Added after the first proof attempt failed: the largest value returned so
far is the number of `swap!`s. It rules out the unreachable state the solver
found (`maxReturned = 1`, `swaps = 0`). -/
invariant [max_is_swaps] maxReturned = swaps

#gen_spec

#check_invariants

#model_check { thread := Fin 3 } { }

end TinyAtom
