module
public import Veil

/-!
# Tutorial: a `swap!` without compare-and-set

The model checking example of `specs/TUTORIAL.md`: `swap!` as load, then
store, with nothing in between to notice another thread's store. jank's real
`swap!` is `Tutorial/TinyAtom.lean`.
-/

veil module NaiveAtom

type thread
enum pc_t = { idle, loaded, done }

individual value : Nat
function pc : thread → pc_t
function seen : thread → Nat
/- How many `swap!`s finished (ghost state: for the property, not in jank). -/
individual swaps : Nat

#gen_state

after_init {
  value := 0
  pc T := idle
  seen T := 0
  swaps := 0
}

/- Read the atom. -/
action load (t : thread) {
  require pc t = idle
  seen t := value
  pc t := loaded
}

/- Write what was read, plus one. -/
action store (t : thread) {
  require pc t = loaded
  value := seen t + 1
  swaps := swaps + 1
  pc t := done
}

/- No update is lost. -/
safety [no_lost_update] value = swaps

#gen_spec

set_option veil.violationIsError false in
#model_check { thread := Fin 2 } { }

end NaiveAtom
