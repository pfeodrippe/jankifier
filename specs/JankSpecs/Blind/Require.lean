module
public import Veil

/-!
# jank's `require`, from several threads

A blind model (see `PLAN.md`, phase 2, C1, V7): the property was written in
`PLAN.md` from `require`'s docstring before this code was read; the model
follows jank 0.1 (`f3d82d654`) step by step, with every thread's steps
interleaved.

- `require` → `load-libs` → `load-lib` (`clojure/core.jank:4836`): reads
  `loaded?` (`(contains? @*loaded-libs* lib)`), and if it's false calls
  `load-one` (`:4814`): `load` (`:4801`, the module loader's `load_module`,
  which evaluates the file form by form, `context_dynamic.cpp:50`), and only
  then `(swap! *loaded-libs* conj lib)`. Nothing holds a lock from the check to
  the `swap!`.
- Each form is analyzed and evaluated on its own; the JIT's interpreter is
  behind a lock (`jit_prc.interpreter.lock()`), namespaces and vars have their
  own locks, so evaluating forms from several threads at once is safe, form by
  form.

The lib is `(ns lib) (def a 1) (def b 2)`: `forms` steps. Each thread runs
`(require 'lib)` once.
-/

-- The SMT solver's answers are turned into proofs which Lean's kernel checks.
set_option veil.smt.trust false

veil module Require

type thread
enum pc_t = { start, loading, done }

immutable individual forms : Nat
immutable individual focus : Nat

function pc : thread → pc_t
/- How many forms of the file this thread has evaluated, in its load. -/
function pos : thread → Nat
/- `*loaded-libs*` has the lib; how many forms have been evaluated by some
load (the lib's vars defined so far); how many loads ran the whole file. -/
individual loadedLib : Bool
individual defined : Nat
individual runs : Nat

#gen_state

after_init {
  pc T := start
  pos T := 0
  loadedLib := false
  defined := 0
  runs := 0
}

/- `load-lib`: `loaded?`. -/
action check (t : thread) {
  require pc t = start
  if loadedLib then
    pc t := done
  else
    pc t := loading
}

/- `load`: the next form of the file. -/
action evalForm (t : thread) {
  require pc t = loading ∧ pos t < forms
  pos t := pos t + 1
  if defined < pos t then
    defined := pos t
}

/- After the file: `(swap! *loaded-libs* conj lib)`, and `require` returns. -/
action finish (t : thread) {
  require pc t = loading ∧ pos t = forms
  runs := runs + 1
  loadedLib := true
  pc t := done
}

/-! ## Properties

V7 is from `PLAN.md`, written before the code was read. -/

/- V7: the lib is loaded once ... -/
safety [v7_require_loads_once] focus = 7 → runs ≤ 1
/- ... and completely: when `require` returns, every form has been
evaluated (the lib's vars are defined). -/
safety [v7_require_complete] pc T = done → defined = forms

/- Auxiliary invariants, which make `v7_require_complete` inductive. -/
invariant [loaded_complete] loadedLib → defined = forms
invariant [pos_bounded] pos T ≤ forms ∧ defined ≤ forms
invariant [pos_defined] pos T ≤ defined
invariant [done_after_load] pc T = done → loadedLib

#gen_spec

/-! ## Proofs

`v7_require_complete` is proved for any number of threads and forms.
`v7_require_loads_once` is only required when `focus = 7`; it's false there
(the model checker below shows it), so its rows fail. That doesn't weaken the
other proofs: with `focus = 0` it holds trivially, so the others are
inductive on their own, and no action reads `focus`, so the reachable states
are the same for every `focus`. -/

/--
info: Initialization must establish the invariant:
  doesNotThrow ... ✅
  v7_require_loads_once ... ✅
  v7_require_complete ... ✅
  loaded_complete ... ✅
  pos_bounded ... ✅
  pos_defined ... ✅
  done_after_load ... ✅
The following set of actions must preserve the invariant and successfully terminate:
  check
    doesNotThrow ... ✅
    v7_require_loads_once ... ✅
    v7_require_complete ... ✅
    loaded_complete ... ✅
    pos_bounded ... ✅
    pos_defined ... ✅
    done_after_load ... ✅
  finish
    doesNotThrow ... ✅
    v7_require_loads_once ... ❌
    v7_require_complete ... ✅
    loaded_complete ... ✅
    pos_bounded ... ✅
    pos_defined ... ✅
    done_after_load ... ✅
  evalForm
    doesNotThrow ... ✅
    v7_require_loads_once ... ✅
    v7_require_complete ... ✅
    loaded_complete ... ✅
    pos_bounded ... ✅
    pos_defined ... ✅
    done_after_load ... ✅
-/
#guard_msgs in
set_option veil.printCounterexamples false in
set_option veil.violationIsError false in
#check_invariants

/-! ## Model checking -/

-- One thread: loaded once. Three threads: complete when it returns.
#model_check { thread := Fin 1 } { forms := 3, focus := 7 }
#model_check { thread := Fin 3 } { forms := 3, focus := 0 }

-- V7: two threads `require` it at once.
#guard_msgs (drop error) in
#model_check { thread := Fin 2 } { forms := 3, focus := 7 } (sequential := true)
set_option veil.violationIsError false in
#model_check { thread := Fin 2 } { forms := 3, focus := 7 } (sequential := true)

#gen_executable

end Require
