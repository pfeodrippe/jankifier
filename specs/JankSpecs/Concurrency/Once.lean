module
public import Veil

/-!
# jank's run-once values: delay, promise, lazy seq

Models of how jank 0.1 computes a value once, for threads which ask for it at
the same time (`compiler+runtime/src/cpp/jank/runtime/obj/` at `f3d82d654`):

- **`delay`** (`delay.cpp`): `deref` takes a `std::mutex`, returns the cached
  value or rethrows the cached error, or else runs the body and caches its
  result or its error. The mutex isn't recursive: a body which derefs its own
  delay waits for itself forever. (Clojure's `Delay` locks with
  `synchronized`, which is recursive, so the same body runs again, until the
  stack overflows.)
- **`promise`** (`promise.cpp`): `deliver` sets the value if it's still
  pending, under a lock, and wakes the waiters; `deref` waits until it's
  delivered.
- **lazy seq** (`lazy_sequence.cpp`): realizing takes a recursive mutex and
  calls the body once; if the body throws, nothing is cached, so the next
  realization calls it again. The whole realization is one step here, since
  it holds the mutex throughout.

The delay's body is one of: return a value, throw, or deref the delay itself.
The lazy seq's body throws on its first call or not, then returns.

The state uses only relations, functions, enums and numbers (no `Option`), so
that `#check_invariants` can prove the properties which hold for any number of
threads and values.
-/

-- The SMT solver's answers are turned into proofs which Lean's kernel checks.
set_option veil.smt.trust false

veil module Once

type thread
type value
enum body_t = { returns, throws, derefsSelf }
enum dpc_t = { idle, waiting, running, finished, stuck }
/- A result: none yet, a value, or an error. -/
enum res_t = { nothing, ok, err }

immutable individual delayBody : body_t
immutable relation lazyThrowsFirst : thread → Bool
immutable individual focus : Nat

/-! Delay: who holds its mutex, what's cached, how many times the body ran,
and what each thread's deref gave. -/
relation owns : thread → Bool
individual cached : res_t
individual runs : Nat
function dpc : thread → dpc_t
function got : thread → res_t

/-! Promise: the delivered value (at most one), who delivered, and what each
deref returned. -/
relation promised : value → Bool
relation delivered : thread → Bool
relation promiseGot : thread → value → Bool

/-! Lazy seq: its body's calls, whether it's realized, and what each
realization gave (`ok` the seq, `err` the body's exception). -/
individual lazyCalls : Nat
individual lazyRealized : Bool
function lazyGot : thread → res_t

#gen_state

after_init {
  owns T := false
  cached := nothing
  runs := 0
  dpc T := idle
  got T := nothing
  promised V := false
  delivered T := false
  promiseGot T V := false
  lazyCalls := 0
  lazyRealized := false
  lazyGot T := nothing
}

/-! ## delay -/

/- `@d`: take the mutex, or wait for it. -/
action delayDeref (t : thread) {
  require dpc t = idle ∧ got t = nothing
  if ∀ T, ¬ owns T then
    owns t := true
    dpc t := running
  else
    dpc t := waiting
}

/- A waiting thread takes the mutex once it's free. -/
action delayAcquire (t : thread) {
  require dpc t = waiting ∧ ∀ T, ¬ owns T
  owns t := true
  dpc t := running
}

/- With the mutex: return or rethrow what's cached, or run the body. -/
action delayRun (t : thread) {
  require dpc t = running
  if cached ≠ nothing then
    got t := cached
    owns t := false
    dpc t := finished
  else
    runs := runs + 1
    if delayBody = returns then
      cached := ok
      got t := ok
      owns t := false
      dpc t := finished
    else
      if delayBody = throws then
        cached := err
        got t := err
        owns t := false
        dpc t := finished
      else
        -- The body derefs the delay: the same thread asks for the mutex it
        -- holds, and waits for it forever.
        dpc t := stuck
}

/-! ## promise -/

action deliver (t : thread) (v : value) {
  require ¬ delivered t
  delivered t := true
  if ∀ V, ¬ promised V then
    promised V := decide (V = v)
}

/- `@p` returns once it's delivered. -/
action promiseDeref (t : thread) {
  require (∀ V, ¬ promiseGot t V) ∧ ∃ V, promised V
  promiseGot t V := promised V
}

/-! ## lazy seq -/

/- Realizing: under the mutex, call the body if it hasn't returned yet. -/
action lazyRealize (t : thread) {
  require lazyGot t = nothing
  if lazyRealized then
    lazyGot t := ok
  else
    lazyCalls := lazyCalls + 1
    if lazyCalls = 1 ∧ lazyThrowsFirst t then
      lazyGot t := err
    else
      lazyRealized := true
      lazyGot t := ok
}

/-! ## Properties -/

/- C5: the delay's body runs at most once, and every deref gets the same. -/
safety [c5_delay_runs_once] runs ≤ 1
safety [c5_delay_derefs_agree] got T ≠ nothing ∧ got U ≠ nothing → got T = got U
/- C5: a deref of the delay returns (or throws). -/
safety [c5_delay_deref_returns] focus = 5 → dpc T ≠ stuck
/- C6: every deref of a promise returns the first value delivered. -/
safety [c6_promise_first_wins] promiseGot T V → promised V
/- C9: once a lazy seq is realized its body isn't called again; it's called
again after it threw. -/
safety [c9_lazy_body_once] lazyCalls ≤ 2
safety [c9_lazy_realized_once] lazyRealized → (lazyCalls = 1 ∨ lazyCalls = 2)

/-! Auxiliary invariants, which make the properties above inductive. -/

/- A thread holds the mutex exactly while it runs the body (or is stuck in
it), and only one thread holds it. -/
invariant [mutex_held] (dpc T = running ∨ dpc T = stuck) ↔ owns T
invariant [mutex_single] owns T ∧ owns U → T = U
/- Before the body runs nothing is cached; once it ran, its result is cached,
or its thread is stuck in it. -/
invariant [delay_not_run] runs = 0 → (cached = nothing ∧ dpc T ≠ stuck)
invariant [delay_ran] runs = 1 ∧ cached = nothing → ∃ T, dpc T = stuck
/- A deref gave what's cached. -/
invariant [got_cached] got T ≠ nothing → got T = cached
/- At most one value is delivered. -/
invariant [promise_single] promised V ∧ promised X → V = X
/- Until the lazy seq is realized, its body was called at most once (and
threw). -/
invariant [lazy_unrealized] ¬ lazyRealized → lazyCalls ≤ 1

#gen_spec

/-! ## Proofs

Everything except `c5_delay_deref_returns` is proved for any number of threads
and values: each property holds initially and every action preserves the
conjunction of all of them. `c5_delay_deref_returns` is only required when
`focus = 5`; it's false there (the model checker below shows it), so its rows
fail. That doesn't weaken the other proofs: with `focus = 0` it holds
trivially, so the others are inductive on their own, and no action reads
`focus`, so the reachable states are the same for every `focus`.

The SMT solver's answers are reconstructed into proofs that Lean's kernel
checks (`veil.smt.trust false`, at the top), and `#guard_msgs` pins the table
of results, so the build fails if any of them changes. -/

/--
info: Initialization must establish the invariant:
  doesNotThrow ... ✅
  c5_delay_runs_once ... ✅
  c5_delay_derefs_agree ... ✅
  c5_delay_deref_returns ... ✅
  c6_promise_first_wins ... ✅
  c9_lazy_body_once ... ✅
  c9_lazy_realized_once ... ✅
  mutex_held ... ✅
  mutex_single ... ✅
  delay_not_run ... ✅
  delay_ran ... ✅
  got_cached ... ✅
  promise_single ... ✅
  lazy_unrealized ... ✅
The following set of actions must preserve the invariant and successfully terminate:
  delayAcquire
    doesNotThrow ... ✅
    c5_delay_runs_once ... ✅
    c5_delay_derefs_agree ... ✅
    c5_delay_deref_returns ... ✅
    c6_promise_first_wins ... ✅
    c9_lazy_body_once ... ✅
    c9_lazy_realized_once ... ✅
    mutex_held ... ✅
    mutex_single ... ✅
    delay_not_run ... ✅
    delay_ran ... ✅
    got_cached ... ✅
    promise_single ... ✅
    lazy_unrealized ... ✅
  deliver
    doesNotThrow ... ✅
    c5_delay_runs_once ... ✅
    c5_delay_derefs_agree ... ✅
    c5_delay_deref_returns ... ✅
    c6_promise_first_wins ... ✅
    c9_lazy_body_once ... ✅
    c9_lazy_realized_once ... ✅
    mutex_held ... ✅
    mutex_single ... ✅
    delay_not_run ... ✅
    delay_ran ... ✅
    got_cached ... ✅
    promise_single ... ✅
    lazy_unrealized ... ✅
  lazyRealize
    doesNotThrow ... ✅
    c5_delay_runs_once ... ✅
    c5_delay_derefs_agree ... ✅
    c5_delay_deref_returns ... ✅
    c6_promise_first_wins ... ✅
    c9_lazy_body_once ... ✅
    c9_lazy_realized_once ... ✅
    mutex_held ... ✅
    mutex_single ... ✅
    delay_not_run ... ✅
    delay_ran ... ✅
    got_cached ... ✅
    promise_single ... ✅
    lazy_unrealized ... ✅
  delayDeref
    doesNotThrow ... ✅
    c5_delay_runs_once ... ✅
    c5_delay_derefs_agree ... ✅
    c5_delay_deref_returns ... ✅
    c6_promise_first_wins ... ✅
    c9_lazy_body_once ... ✅
    c9_lazy_realized_once ... ✅
    mutex_held ... ✅
    mutex_single ... ✅
    delay_not_run ... ✅
    delay_ran ... ✅
    got_cached ... ✅
    promise_single ... ✅
    lazy_unrealized ... ✅
  promiseDeref
    doesNotThrow ... ✅
    c5_delay_runs_once ... ✅
    c5_delay_derefs_agree ... ✅
    c5_delay_deref_returns ... ✅
    c6_promise_first_wins ... ✅
    c9_lazy_body_once ... ✅
    c9_lazy_realized_once ... ✅
    mutex_held ... ✅
    mutex_single ... ✅
    delay_not_run ... ✅
    delay_ran ... ✅
    got_cached ... ✅
    promise_single ... ✅
    lazy_unrealized ... ✅
  delayRun
    doesNotThrow ... ✅
    c5_delay_runs_once ... ✅
    c5_delay_derefs_agree ... ✅
    c5_delay_deref_returns ... ❌
    c6_promise_first_wins ... ✅
    c9_lazy_body_once ... ✅
    c9_lazy_realized_once ... ✅
    mutex_held ... ✅
    mutex_single ... ✅
    delay_not_run ... ✅
    delay_ran ... ✅
    got_cached ... ✅
    promise_single ... ✅
    lazy_unrealized ... ✅
-/
#guard_msgs in
set_option veil.printCounterexamples false in
set_option veil.violationIsError false in
#check_invariants

/-! ## Model checking -/

-- Three threads, a delay which returns, and one which throws.
#model_check { thread := Fin 3, value := Fin 2 }
  { delayBody := body_t_IndT.returns, lazyThrowsFirst := fun t => t = 0, focus := 0 }
#model_check { thread := Fin 3, value := Fin 2 }
  { delayBody := body_t_IndT.throws, lazyThrowsFirst := fun _ => false, focus := 0 }

-- C5, with a body which derefs its own delay.
#guard_msgs (drop error) in
#model_check interpreted { thread := Fin 1, value := Fin 2 }
  { delayBody := body_t_IndT.derefsSelf, lazyThrowsFirst := fun _ => false, focus := 5 }
  (sequential := true)

set_option veil.violationIsError false in
#model_check interpreted { thread := Fin 1, value := Fin 2 }
  { delayBody := body_t_IndT.derefsSelf, lazyThrowsFirst := fun _ => false, focus := 5 }
  (sequential := true)

#gen_executable

end Once
