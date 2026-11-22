module
public import Veil

/-!
# jank's vars: `alter-var-root`, `def`, `with-redefs`, `defonce`, interning

A blind model (see `PLAN.md`, phase 2, C1): the properties V1, V2, V4 and V5
below were written in `PLAN.md` from the docstrings before this code was read;
the model follows the code of jank 0.1 (`f3d82d654`) step by step, with every
thread's steps interleaved. One var, whose root is a number.

- **Root** (`runtime/var.cpp`): `root` is a `std::atomic<object_ref>`; `deref`
  (`:278`) returns the thread binding if any, else `root.load()`, without a
  lock. `bind_root` (`:98`) takes `write_mutex` (a `folly::SharedMutex`, not
  recursive) and stores. `alter_root` (`:106`) takes `write_mutex`, then
  **calls `f` while holding it**, stores the result, and unlocks (RAII, also
  when `f` throws).
- **`alter-var-root`** (`clojure/core.jank:2524`) calls `alter_root`.
- **`def`** with a value (`evaluate.cpp:287`) interns the var and calls
  `bind_root`; without one it only interns it (the root is unchanged).
- **`with-redefs`** (`core.jank:4568`, `with-redefs-fn` `:4549`) reads each
  var's root (`var_get_root`, an atomic load), `bind_root`s the new values,
  calls the body, and in `finally` `bind_root`s the old values back.
- **`defonce`** (`core.jank:4289`) is `(let [v (def name)] (when-not (bound? v)
  (def name expr)))`: check, then evaluate `expr`, then `bind_root`, as
  separate steps.
- **Interning** a var (`ns.cpp:26` `ns::intern_var`), a namespace
  (`context.cpp:401` `intern_ns`, used by `create-ns`) or a keyword
  (`context.cpp:587` `intern_keyword`, used by `keyword`) is one find-or-insert
  under one write lock: one step here (`intern`).

Each thread runs one program, from the theory.

`fixed` turns on a proposed fix of jank, to check it before it's written:

- `a5`: `write_mutex` is recursive (as Clojure's `synchronized alterRoot`
  is), so an `alter-var-root` inside `f` re-enters it; the outer one then
  stores `(f v)` over the nested one's value, as on Clojure. (Not calling `f`
  under the lock, with a compare-and-set loop as `swap!` does, would loop
  forever on this `f`: each retry alters the var again, so the outer
  compare-and-set fails again.)
-/

-- The SMT solver's answers are turned into proofs which Lean's kernel checks.
set_option veil.smt.trust false

veil module Vars

type thread
/- `alter`: `(alter-var-root #'x inc)`; `alterNested`: `(alter-var-root #'x
(fn [v] (alter-var-root #'x inc) (inc v)))`; `define`: `(def x 100)`;
`redefs`: `(with-redefs [x 50] ...)`; `defonce`: `(defonce x 7)`; `intern`:
`(intern ns 'y)` (or `create-ns`, `keyword`). -/
enum prog_t = { alter, alterNested, define, redefs, defonce, intern }
enum pc_t = { start, waiting, locked, stuck, checked, evaluated, inBody, done }
/- The proposed fixes (see above). -/
enum fix_t = { a5 }

immutable function prog : thread → prog_t
immutable individual initRoot : Nat
immutable individual initBound : Bool
immutable individual focus : Nat
immutable relation fixed : fix_t → Bool

/- The var's root (when it has one), and who holds `write_mutex`. -/
individual root : Nat
individual rootBound : Bool
relation owns : thread → Bool
function pc : thread → pc_t
/- `alter-var-root`s done; `defonce` expressions evaluated. -/
individual alters : Nat
individual evals : Nat
/- What each `with-redefs` read as the old root. -/
function oldRoot : thread → Nat
relation oldBound : thread → Bool
/- Interning: whether the object exists, who created it, and which object
each interning thread got (`gotObj t c`: the one `c` created). -/
individual interned : Bool
relation createdBy : thread → Bool
relation gotObj : thread → thread → Bool

#gen_state

after_init {
  root := initRoot
  rootBound := initBound
  owns T := false
  pc T := start
  alters := 0
  evals := 0
  oldRoot T := 0
  oldBound T := false
  interned := false
  createdBy T := false
  gotObj T C := false
}

/-! ## `alter-var-root` -/

/- `alter_root` locks `write_mutex`, or waits for it. -/
action alterLock (t : thread) {
  require (prog t = alter ∨ prog t = alterNested) ∧ pc t = start
  if ∀ T, ¬ owns T then
    owns t := true
    pc t := locked
  else
    pc t := waiting
}

action alterAcquire (t : thread) {
  require pc t = waiting ∧ ∀ T, ¬ owns T
  owns t := true
  pc t := locked
}

/- With the lock, `f` is called on the root. A nested `alter-var-root` of the
same var locks `write_mutex` again, which this thread holds: it waits
forever (with the fix `a5`, it re-enters the lock and stores `v + 1`, then
the outer one stores `v + 1` too). Otherwise the result is stored and the
lock released. -/
action alterApply (t : thread) {
  require pc t = locked
  if prog t = alterNested ∧ ¬ fixed a5 then
    pc t := stuck
  else
    root := root + 1
    alters := alters + 1
    owns t := false
    pc t := done
}

/-! ## `def` with a value: `bind_root` -/

action define (t : thread) {
  require prog t = define ∧ pc t = start ∧ ∀ T, ¬ owns T
  root := 100
  rootBound := true
  pc t := done
}

/-! ## `with-redefs` -/

/- `var_get_root`: an atomic load, without the lock. -/
action redefsRead (t : thread) {
  require prog t = redefs ∧ pc t = start
  oldRoot t := root
  oldBound t := rootBound
  pc t := checked
}

/- `bind_root` of the new value; then the body runs. -/
action redefsBind (t : thread) {
  require prog t = redefs ∧ pc t = checked ∧ ∀ T, ¬ owns T
  root := 50
  rootBound := true
  pc t := inBody
}

/- `finally`: `bind_root` of the old value, whether the body threw or not. -/
action redefsRestore (t : thread) {
  require prog t = redefs ∧ pc t = inBody ∧ ∀ T, ¬ owns T
  root := oldRoot t
  rootBound := oldBound t
  pc t := done
}

/-! ## `defonce` -/

/- `(def name)` (interns, the root is unchanged), then `bound?`. -/
action defonceCheck (t : thread) {
  require prog t = defonce ∧ pc t = start
  if rootBound then
    pc t := done
  else
    pc t := checked
}

/- `(def name expr)`: `expr` is evaluated ... -/
action defonceEval (t : thread) {
  require prog t = defonce ∧ pc t = checked
  evals := evals + 1
  pc t := evaluated
}

/- ... then `bind_root`. -/
action defonceBind (t : thread) {
  require prog t = defonce ∧ pc t = evaluated ∧ ∀ T, ¬ owns T
  root := 7
  rootBound := true
  pc t := done
}

/-! ## Interning (a var, a namespace or a keyword) -/

/- Find, or create and insert, under one write lock. -/
action intern (t : thread) {
  require prog t = intern ∧ pc t = start
  if interned then
    gotObj t C := createdBy C
  else
    interned := true
    createdBy C := decide (C = t)
    gotObj t C := decide (C = t)
  pc t := done
}

/-! ## Properties

V1, V2, V4 and V5 are from `PLAN.md`, written before the code was read. -/

/- V1: concurrent `alter-var-root`s lose no update. -/
safety [v1_alter_no_lost_update] (∀ T, prog T = alter) → root = initRoot + alters
/- V2 (and V3, V6, by the same code pattern): concurrent interns of one name
get the same object. -/
safety [v2_intern_one_object] gotObj T C ∧ gotObj U D → C = D
/- V4: `defonce` evaluates its expression at most once. -/
safety [v4_defonce_once] focus = 4 → evals ≤ 1
/- V5: once every `with-redefs` has finished, the root is back to what it was
(with no other writers). -/
safety [v5_redefs_restored]
  focus = 5 → ((∀ T, prog T = redefs ∧ pc T = done) → (root = initRoot ∧ rootBound = initBound))

/- Added after reading the code (so not blind): `alter-var-root` returns,
also when `f` alters the same var (Clojure's `alterRoot` is `synchronized`,
which is reentrant). -/
safety [v1_alter_returns] focus = 1 → pc T ≠ stuck
/- With the fix `a5`, it does. -/
safety [v1_fixed_alter_returns] fixed a5 → pc T ≠ stuck

/- Auxiliary invariants, which make V1 and V2 inductive: a thread holds the
lock exactly while it's in `alter_root`, and only one does; interned objects
were created once. -/
invariant [lock_held] (pc T = locked ∨ pc T = stuck) ↔ owns T
invariant [lock_single] owns T ∧ owns U → T = U
invariant [alter_only_alters] (pc T = locked ∨ pc T = waiting ∨ pc T = stuck) →
  (prog T = alter ∨ prog T = alterNested)
invariant [created_once] createdBy C ∧ createdBy D → C = D
invariant [got_created] gotObj T C → createdBy C
invariant [created_interned] createdBy C → interned

#gen_spec

/-! ## Proofs

V1 and V2 are proved for any number of threads. V4, V5 and
`v1_alter_returns` are only required when `focus` is 4, 5 or 1; they're false
there (the model checker below shows it), so their rows fail. That doesn't
weaken the other proofs: with `focus = 0` they hold trivially, so the others
are inductive on their own, and no action reads `focus`, so the reachable
states are the same for every `focus`. -/

/--
info: Initialization must establish the invariant:
  doesNotThrow ... ✅
  v1_alter_no_lost_update ... ✅
  v2_intern_one_object ... ✅
  v4_defonce_once ... ✅
  v5_redefs_restored ... ✅
  v1_alter_returns ... ✅
  v1_fixed_alter_returns ... ✅
  lock_held ... ✅
  lock_single ... ✅
  alter_only_alters ... ✅
  created_once ... ✅
  got_created ... ✅
  created_interned ... ✅
The following set of actions must preserve the invariant and successfully terminate:
  intern
    doesNotThrow ... ✅
    v1_alter_no_lost_update ... ✅
    v2_intern_one_object ... ✅
    v4_defonce_once ... ✅
    v5_redefs_restored ... ✅
    v1_alter_returns ... ✅
    v1_fixed_alter_returns ... ✅
    lock_held ... ✅
    lock_single ... ✅
    alter_only_alters ... ✅
    created_once ... ✅
    got_created ... ✅
    created_interned ... ✅
  redefsRestore
    doesNotThrow ... ✅
    v1_alter_no_lost_update ... ✅
    v2_intern_one_object ... ✅
    v4_defonce_once ... ✅
    v5_redefs_restored ... ❌
    v1_alter_returns ... ✅
    v1_fixed_alter_returns ... ✅
    lock_held ... ✅
    lock_single ... ✅
    alter_only_alters ... ✅
    created_once ... ✅
    got_created ... ✅
    created_interned ... ✅
  redefsBind
    doesNotThrow ... ✅
    v1_alter_no_lost_update ... ✅
    v2_intern_one_object ... ✅
    v4_defonce_once ... ✅
    v5_redefs_restored ... ✅
    v1_alter_returns ... ✅
    v1_fixed_alter_returns ... ✅
    lock_held ... ✅
    lock_single ... ✅
    alter_only_alters ... ✅
    created_once ... ✅
    got_created ... ✅
    created_interned ... ✅
  alterAcquire
    doesNotThrow ... ✅
    v1_alter_no_lost_update ... ✅
    v2_intern_one_object ... ✅
    v4_defonce_once ... ✅
    v5_redefs_restored ... ✅
    v1_alter_returns ... ✅
    v1_fixed_alter_returns ... ✅
    lock_held ... ✅
    lock_single ... ✅
    alter_only_alters ... ✅
    created_once ... ✅
    got_created ... ✅
    created_interned ... ✅
  redefsRead
    doesNotThrow ... ✅
    v1_alter_no_lost_update ... ✅
    v2_intern_one_object ... ✅
    v4_defonce_once ... ✅
    v5_redefs_restored ... ✅
    v1_alter_returns ... ✅
    v1_fixed_alter_returns ... ✅
    lock_held ... ✅
    lock_single ... ✅
    alter_only_alters ... ✅
    created_once ... ✅
    got_created ... ✅
    created_interned ... ✅
  alterApply
    doesNotThrow ... ✅
    v1_alter_no_lost_update ... ✅
    v2_intern_one_object ... ✅
    v4_defonce_once ... ✅
    v5_redefs_restored ... ✅
    v1_alter_returns ... ❌
    v1_fixed_alter_returns ... ✅
    lock_held ... ✅
    lock_single ... ✅
    alter_only_alters ... ✅
    created_once ... ✅
    got_created ... ✅
    created_interned ... ✅
  defonceEval
    doesNotThrow ... ✅
    v1_alter_no_lost_update ... ✅
    v2_intern_one_object ... ✅
    v4_defonce_once ... ❌
    v5_redefs_restored ... ✅
    v1_alter_returns ... ✅
    v1_fixed_alter_returns ... ✅
    lock_held ... ✅
    lock_single ... ✅
    alter_only_alters ... ✅
    created_once ... ✅
    got_created ... ✅
    created_interned ... ✅
  defonceBind
    doesNotThrow ... ✅
    v1_alter_no_lost_update ... ✅
    v2_intern_one_object ... ✅
    v4_defonce_once ... ✅
    v5_redefs_restored ... ✅
    v1_alter_returns ... ✅
    v1_fixed_alter_returns ... ✅
    lock_held ... ✅
    lock_single ... ✅
    alter_only_alters ... ✅
    created_once ... ✅
    got_created ... ✅
    created_interned ... ✅
  alterLock
    doesNotThrow ... ✅
    v1_alter_no_lost_update ... ✅
    v2_intern_one_object ... ✅
    v4_defonce_once ... ✅
    v5_redefs_restored ... ✅
    v1_alter_returns ... ✅
    v1_fixed_alter_returns ... ✅
    lock_held ... ✅
    lock_single ... ✅
    alter_only_alters ... ✅
    created_once ... ✅
    got_created ... ✅
    created_interned ... ✅
  defonceCheck
    doesNotThrow ... ✅
    v1_alter_no_lost_update ... ✅
    v2_intern_one_object ... ✅
    v4_defonce_once ... ✅
    v5_redefs_restored ... ✅
    v1_alter_returns ... ✅
    v1_fixed_alter_returns ... ✅
    lock_held ... ✅
    lock_single ... ✅
    alter_only_alters ... ✅
    created_once ... ✅
    got_created ... ✅
    created_interned ... ✅
  define
    doesNotThrow ... ✅
    v1_alter_no_lost_update ... ✅
    v2_intern_one_object ... ✅
    v4_defonce_once ... ✅
    v5_redefs_restored ... ✅
    v1_alter_returns ... ✅
    v1_fixed_alter_returns ... ✅
    lock_held ... ✅
    lock_single ... ✅
    alter_only_alters ... ✅
    created_once ... ✅
    got_created ... ✅
    created_interned ... ✅
-/
#guard_msgs in
set_option veil.printCounterexamples false in
set_option veil.violationIsError false in
#check_invariants

/-! ## Model checking -/

-- Three threads `alter-var-root` at once; three intern at once.
#model_check { thread := Fin 3 }
  { prog := fun _ => prog_t_IndT.alter, initRoot := 0, initBound := true, focus := 0,
    fixed := fun _ => false }
#model_check { thread := Fin 3 }
  { prog := fun _ => prog_t_IndT.intern, initRoot := 0, initBound := true, focus := 0,
    fixed := fun _ => false }

-- V4 and V5 hold for one thread at a time (the body throwing or not makes no
-- difference: the restore is in `finally`).
#model_check { thread := Fin 1 }
  { prog := fun _ => prog_t_IndT.defonce, initRoot := 0, initBound := false, focus := 4,
    fixed := fun _ => false }
#model_check { thread := Fin 1 }
  { prog := fun _ => prog_t_IndT.redefs, initRoot := 3, initBound := true, focus := 5,
    fixed := fun _ => false }

-- V4: two threads `defonce` at once.
#guard_msgs (drop error) in
#model_check { thread := Fin 2 }
  { prog := fun _ => prog_t_IndT.defonce, initRoot := 0, initBound := false, focus := 4,
    fixed := fun _ => false }
  (sequential := true)
set_option veil.violationIsError false in
#model_check { thread := Fin 2 }
  { prog := fun _ => prog_t_IndT.defonce, initRoot := 0, initBound := false, focus := 4,
    fixed := fun _ => false }
  (sequential := true)

-- V5: two threads `with-redefs` the same var at once.
#guard_msgs (drop error) in
#model_check { thread := Fin 2 }
  { prog := fun _ => prog_t_IndT.redefs, initRoot := 3, initBound := true, focus := 5,
    fixed := fun _ => false }
  (sequential := true)
set_option veil.violationIsError false in
#model_check { thread := Fin 2 }
  { prog := fun _ => prog_t_IndT.redefs, initRoot := 3, initBound := true, focus := 5,
    fixed := fun _ => false }
  (sequential := true)

-- `v1_alter_returns`: `f` alters the same var.
#guard_msgs (drop error) in
#model_check { thread := Fin 1 }
  { prog := fun _ => prog_t_IndT.alterNested, initRoot := 0, initBound := true, focus := 1,
    fixed := fun _ => false }
  (sequential := true)
set_option veil.violationIsError false in
#model_check { thread := Fin 1 }
  { prog := fun _ => prog_t_IndT.alterNested, initRoot := 0, initBound := true, focus := 1,
    fixed := fun _ => false }
  (sequential := true)

-- `v1_alter_returns` with the fix `a5`: no violation, for one thread and for
-- two (each with a nested `alter-var-root`).
#model_check { thread := Fin 1 }
  { prog := fun _ => prog_t_IndT.alterNested, initRoot := 0, initBound := true, focus := 1,
    fixed := fun _ => true }
#model_check { thread := Fin 2 }
  { prog := fun _ => prog_t_IndT.alterNested, initRoot := 0, initBound := true, focus := 1,
    fixed := fun _ => true }

#gen_executable

end Vars
