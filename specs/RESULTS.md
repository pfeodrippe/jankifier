# Results

jank 0.1 (Homebrew; its sources are `jank-lang/jank` at `f3d82d654`), macOS
15.1 on Apple Silicon, Veil `v4.35.0`. How to rerun everything:
[README.md](README.md). Each finding has a runnable reproduction in
[repro/](repro/README.md).

Each property is one of:

- **holds**: the model checker found no violation in the stated instance
  (and, where said, `#check_invariants` proved it for all instances);
- **violated**: the model checker found a counterexample, and it was
  reproduced on jank.

## Findings

These reproduce on jank 0.1; the model predicts each one, and its
counterexample is in the build log.

| # | Finding | Where | Reproduction |
|---|---|---|---|
| M1 | A module's object file is loaded although it was compiled against an older version of a dependency: `find` only compares a module's `.o` with its own source. `jank compile-module` doesn't rebuild it either (the module loads from its fresh `.o`, so nothing is written). Macros and inlined code from the old dependency run. | `loader_dynamic.cpp` `find` | compile `app` (requires `lib`), edit `lib`, run: `app` shows `lib`'s old macro |
| M2 | When two directories on the module path have the same module, the **last** wins, although `loader.hpp` says the first does (`register_entry` overwrites). A module's source and object file can come from different directories. | `loader_dynamic.cpp` `register_entry` | `lib` in `a` and `b`, `--module-path a:b`: `b`'s loads |
| M3 | A running REPL never sees an object file created after it started for a module it already indexed (the index is only rebuilt on a lookup miss), so it keeps loading the source. | `find_module` | REPL starts, `compile-module late` elsewhere, `(require 'late)` loads the source |
| M4 | A module whose source was deleted, with an object file, fails with `filesystem error: in last_write_time: No such file or directory` instead of "not found". | `find` (`last_modified_at`) | compile, delete the source, require |
| M5 | `(require 'm :reload)` after `m`'s object file was rebuilt runs the **old** code: `load_o` calls the `jank_load_m` already in the process instead of loading the new object file. | `loader_dynamic.cpp` `load_o` | REPL loads `lib` from `.o` v1, rebuild `lib.o` as v2 elsewhere, reload: v1 runs |
| C3 | A future can see another future's dynamic bindings: a future's thread pushes a binding frame and never pops it, frames are keyed by OS thread id and never removed, and macOS reuses thread ids, so a later future on the same id starts from the stale frame. 200 out of 200 tries leaked. | `core.cpp` `future`, `context.cpp` `push_thread_bindings` | `@(binding [*x* 1] (future *x*))` then `@(future *x*)` returns `1` |
| C4 | The same never-popped frame: every finished future leaves its frame in the map (a leak). | same | 1000 futures leave 1000 frames (counted through C++ interop: `repro/binding-frames-never-freed.jank`) |
| C5 | A delay whose body derefs the delay deadlocks (its `std::mutex` isn't recursive); Clojure reports a stack overflow. | `delay.cpp` | `(def d (delay (inc @d)))`, `@d` hangs |
| C8 | On macOS, `future-cancel` returns `nil`, `future-cancelled?` stays `false`, `realized?` stays `false`, and `@f` returns `nil` instead of throwing. The thread is cancelled, but nothing records it. | `core.cpp` `cancel_future`, `is_future_cancelled` | cancel a sleeping future, deref it |
| N1 | An eval request with a bad argument (e.g. `"line": "bad"`) throws outside `safe-eval`, which ends the connection's loop: that request and every later one on the connection never get a response, so the client hangs. | `nrepl/server/core.jank` `handle-client` | eval with `"line": "bad"`, then any request on the same connection |
| N3 | A failed eval sends `:ex` and `:status [:done :eval-error]` in one message; nREPL sends `done` separately, and CIDER 2.1 leaks a pending request (its spinner) on the combined one. (`jankifier.nrepl` works around it.) | `handler/eval.jank` | eval `(throw ...)` |
| N4 | Output capture is process-wide: with evals on two connections at once, one request's `:out` gets another request's prints, or they go to the server's own stdout. | `capture.jank` | two connections evaluating code which prints |
| N5 | Overlapping captures restore stdout in the wrong order and can leave the server's file descriptor 1 pointing at a deleted temp file: everything printed outside an eval afterwards (e.g. from a future) is lost. | `capture.jank` | two connections evaluating at once, then a future which prints |
| N6 | Sessions aren't tracked: `*1` belongs to the connection, so an eval of `*1` in one session returns another session's last value. | `handler/clone.jank`, `evaluate.cpp` | eval in session A, then `*1` in session B on the same connection |

An earlier version listed "W": watch notifications of concurrent `swap!`s
arriving out of order. It isn't a finding: `add-watch`'s docstring allows it,
and Clojure does the same.

## Properties

### Module loader and cache (`JankSpecs/ModuleCache.lean`)

Instance: modules `lib` and `app` (requires `lib`), directories `a`, `b` and the
build directory, two processes; 713,074 states up to depth 7.

| Property | Result |
|---|---|
| `deps_loaded`: a loaded module's dependencies are loaded | holds; proved for all instances by `#check_invariants` (kernel-checked since phase 2) |
| `loaded_has_code` | holds; proved for all instances (kernel-checked since phase 2) |
| M1 `m1_object_matches_dependencies` | violated |
| M2 `m2_first_match_wins` | violated |
| M3 `m3_index_sees_new_objects` | violated |
| M4 `m4_deleted_source_reported` | violated |
| M5 `m5_load_runs_chosen_object` | violated |

Conformance (traces): the 5 counterexamples (M2 and M3 with a load added at
the end to show the effect) and 30 random scenarios of edits, touches,
deletions, `jank compile-module` runs and REPL `require`s, replayed step by
step: all 35 conform.

The conformance check changed the model twice. A compile is atomic in the
model (no edits or other processes' steps during `jank compile-module`), which
is how it runs. And a module which can't be found fails before its
dependencies load, since `find` comes first and only the module's `ns` form
loads them; the first version required the dependencies loaded for every
load, and couldn't take the step jank took.

### Dynamic bindings and futures (`JankSpecs/Concurrency/Bindings.lean`)

Instance: a main thread and two futures, three OS thread ids, values 0..2;
23,933 states (complete).

| Property | Result |
|---|---|
| `conveyed_on_top`, `bound_future_sees_binding`, `main_live`, `live_ids_distinct`, `main_tid_unique` | hold |
| C3 `c3_binding_isolation` | violated |
| C4 `c4_frames_released` | violated |
| C8 `c8_cancel_visible` | violated |
| C7 `set!` only from the binding thread | modelled in the runtime (`var::set`), but not reachable from jank code: `set!` and `var-set` aren't ported |

Conformance: the 3 counterexamples and 150 random programs (nested
`binding`s, futures, derefs, cancels), with the real OS thread ids, replayed
step by step: all conform. In the C3 counterexample jank shows future 2,
created outside the binding, on future 1's thread id `6168440832`, returning
`:v1`.

### Atoms (`JankSpecs/Concurrency/Atom.lean`)

| Property | Result |
|---|---|
| C1 `c1_swaps_are_atomic` (two threads, two `swap!`s each; 298 states) | holds |
| C2 `c2_cas_succeeds_on_match` | violated in the model: `compare-and-set!` is one `compare_exchange_weak`, which may fail spuriously. Depends on the CPU jank is compiled for: jank 0.1's binary uses `casal`, which can't (0 in 200,000 contended tries); the same C++ compiled for a Cortex-A72 (ARMv8.0, a Raspberry Pi 4) uses `ldaxr`/`stlxr` and fails tens of thousands of times in 2,000,000 on this machine (`repro/compare-exchange-weak-spurious.cpp`) |
| `watch_calls_chain` | violated, but not a requirement: `add-watch`'s docstring warns that the state may have changed again before the call, and that watch fns may be called from several threads at once. Not a finding (Clojure behaves the same) |

Conformance (outcome sets): 5000 runs showed 3 of the model's 7 outcomes for
two futures doing two `swap!`s, including out-of-order watch calls, and none
outside them; `compare-and-set!` from the value `swap!` returned succeeded in
5000 runs.

### Delay, promise, lazy seq (`JankSpecs/Concurrency/Once.lean`)

| Property | Result |
|---|---|
| C5 `c5_delay_runs_once`, `c5_delay_derefs_agree` (three threads; 58,421 and 42,488 states) | hold |
| C5 `c5_delay_deref_returns` | violated (self-deref deadlock) |
| C6 `c6_promise_first_wins` | holds |
| C9 `c9_lazy_body_once`, `c9_lazy_realized_once` | hold |

Conformance (outcome sets): 3000 runs each with a delay which returns and one
which throws, three futures dereffing it, delivering and dereffing a promise,
and realizing a lazy seq whose body throws first: all 4 of the model's
outcomes, nothing else. The self-dereffing delay hangs (killed after 30s).
The check also caught a race in the test program itself (it read a counter
before joining the futures), which the model rejected.

### nREPL server (`JankSpecs/Nrepl.lean`)

Instance: two connections, four requests, two sessions.

| Property | Result |
|---|---|
| `one_eval_per_connection`, `in_order`, `answered_only_when_alive_or_before` (8,970 states) | hold |
| N1 `n1_connection_survives` | violated |
| N3 `n3_done_separate` | violated |
| N4 `n4_output_isolation` | violated |
| N5 `n5_stdout_restored` | violated |
| N6 `n6_sessions_isolated` | violated |

Conformance (outcome sets): 4 targeted and 20 random scripts of four requests
over two connections, each run three times on a fresh server: all conform. The
runs showed each violation: connection 0 never answering after a bad `"line"`
(N1), `[:done :eval-error]` (N3), `:out` with another connection's prints and
prints on the server's stdout (N4), stdout lost after concurrent evals (N5),
and `*1` in session 1 returning session 0's value (N6).

The conformance check changed the model twice. The first version captured
output in one atomic step and attributed a print when it happened; jank showed
an outcome that model doesn't allow (a request's print on the server's stdout,
with stdout working afterwards). Two details explain it, and are now modelled:
`println` writes to C's buffered `stdout`, so a print lands wherever descriptor
1 points when the buffer is next flushed, by any connection's capture; and a
capture's start is three steps (`dup` the backup, `fflush`, `dup2`), so two
captures can both back up the original stdout before either redirects. The
harness's own "is stdout still working" check needed the same flush.

## Notes on Veil

The full list of rough edges, with workarounds, is in [AGENTS.md](AGENTS.md).


- A conditional update of a relation inside a procedure (`if … then decide … else
  r p D M`) crashed Veil's VC generation (`generalize failed`); the same update
  as one boolean formula works.
- SMT queries can't use `List` or `Option` fields, so `sat trace` and
  `#check_invariants` are only used for the module cache model.
- `veil.printCounterexamples` only affects `#check_invariants`; model checking
  counterexamples always print full states, so expected violations are asserted
  with `#guard_msgs (drop error)` and printed by a second run with
  `veil.violationIsError false`.
- Interpreted model checking is much slower than compiled; the default mode
  compiles a checker per instance, which takes a minute or so.

# Phase 2

Phase 2 ([PLAN.md](PLAN.md#phase-2)) did three things: proofs for all sizes
of what phase 1 only model checked (A), the two nREPL properties phase 1 left
out (B), and blind models (C): models of code that hadn't been read, whose
properties were written from the docstrings first, so that what the checker
finds isn't shaped by suspicions.

## Findings

| # | Finding | Where | Reproduction | Found by | Clojure |
|---|---|---|---|---|---|
| A1 | **Transients of array maps (every map of up to 8 entries) write into the maps they came from.** `native_array_map`'s copy constructor is `= default`, so `transient` shares the persistent map's array; `assoc!` of an existing key overwrites it in place, `dissoc!` shifts it in place (leaving a duplicate key), and a key added while capacity is left is written in place. `persistent!` hands the same array to its result, so a later transient of the result changes it too. Ordinary `clojure.core` functions use transients: `(into m {:a 9})`, `(into m [[:b 7]])` and `(update-vals m inc)` change `m`. | `detail/native_array_map.hpp:33`, `obj/transient_array_map.cpp:24`, `native_array_map.cpp:139`, `:168` | `(let [m {:a 1}] (into m {:a 2}) m)` is `{:a 2}`; `(let [m {:a 1 :b 2}] (persistent! (dissoc! (transient m) :a)) m)` is `{:b 2, :b 2}` | the differential test of the blind T1/T4 (100 of 500 random programs, all on maps); then the storage model (`ArrayMap.lean`), whose checker finds it in 4 steps | jank only |
| A2 | Reading a transient after `persistent!` returns data instead of throwing, for 7 operations: on a vector `nth` (one argument), `contains?`, `find`; on an array map `get` with a fallback, `contains?`, `find`, calling it with a fallback. Those methods don't call `assert_active`. | `obj/transient_vector.cpp:53`, `:198`, `:217`; `obj/transient_array_map.cpp` | `(let [t (transient [1])] (persistent! t) (nth t 0))` is `1` | reading the code for the model; checked by the model's table on jank | jank only (Clojure throws) |
| A3 | Multimethod dispatch ignores a preference declared on an ancestor: `is_preferred` gets the hierarchy *var* (`reset_cache` stores `hierarchy`, not its value), and `(parents var tag)` is `nil`. jank throws "multiple methods" where Clojure picks the preferred one. (Comparing the var with its value also resets the cache on every call.) | `obj/multi_function.cpp:136`, `:185`, `:248` | `(derive ::c ::a2) (derive ::a2 ::a) (derive ::c ::b)`, methods on `::a2` and `::b`, `(prefer-method f ::a ::b)`, `(f ::c)` | reading the code (this variant), and the checker from the blind MM1 (the variant with the preference on the other value's ancestor) | jank only |
| A4 | Multimethod dispatch depends on the method table's hash order: with methods on `i`, `j` and `k`, where `k` is more specific than both, the call throws "multiple methods" if the table lists `i` and `j` before `k`. | `obj/multi_function.cpp:262` (Clojure's `MultiFn.findAndCacheBestMethod`) | 14 of 40 name sets throw on jank, 9 of 40 on Clojure | the checker, from the blind MM1 (no preferences); also seen while modelling the loop | shared with Clojure |
| A5 | `alter-var-root` deadlocks when its function alters the same var: `alter_root` holds `write_mutex` (not recursive) while calling the function. | `runtime/var.cpp:106` | `(alter-var-root #'z (fn [v] (alter-var-root #'z inc) (inc v)))` hangs; Clojure returns, root 1 | reading the code (a property added after reading it) | jank only |
| A6 | Races that the docstrings don't allow: two `defonce`s of one var both evaluate the expression (V4); two `with-redefs` of one var leave it redefined (V5); two `require`s of one lib both load it (V7). | `clojure/core.jank:4289`, `:4549`, `:4836` | futures started together: `defonce` evaluated twice in 162 of 200 runs, `with-redefs` left the var at 50 in 1696 of 2000, `require` loaded twice in 197 of 200 | the checker, from the blind V4, V5, V7 | shared with Clojure (157 of 200, 1175 of 2000, 199 of 200) |

Found along the way, without a model:

| # | Finding | Reproduction |
|---|---|---|
| S1 | Printing an exception's stack trace (`pr-str` or `str` of an `ex-info`) makes the process crash with SIGSEGV when it exits, after `-main` returned. | `(defn -main [& _] (println (pr-str (ex-info "boom" {}))))`, exit code 139; with `(cpp/_exit 0)` it's 0 |
| S2 | A `let*` or `loop` whose value is a string literal doesn't compile: codegen declares its result with the literal's C++ type (`const char[9] v17{ };`). `let` and `loop` expand to them. | `(defn f [x] (let [t x] "ok"))`; `(let [] "ok")`; `(do x "ok")` and `(let [t x] (str "ok"))` compile |
| S3 | `(deref ref timeout-ms timeout-val)` is an empty stub ("TODO: Blocking" in `clojure/core.jank:1096`): it returns `nil` at once, without waiting or returning `timeout-val`. | `(deref (future (cpp/usleep 2000000) 1) 10 :timeout)` and `(deref (promise) 10 :timeout)` are `nil` (a plain `deref` of a future that threw does rethrow) |
| S4 | Not ported, so not modelled: agents, refs (`dosync`), `var-set`, `with-local-vars`, `flush` (each throws "TODO: port ..."); `set!` doesn't resolve; `locking` expands to an unresolved `monitor-enter`. | |

One suspicion turned out wrong: evaluating code from several threads at once
(two nREPL connections, `require` in futures) is serialized where it matters
(the JIT's interpreter is behind a lock, and `current_def_var` is
`thread_local`), so the `require` model has no JIT race.

## How each finding was found

- From the blind properties, through the differential test of T1/T4 rather
  than the checker: A1, the most severe finding of both phases. The first
  transient model didn't describe the storage, so the checker couldn't find
  it; the storage model written afterwards finds it in 4 steps and predicts
  jank's corrupted maps entry for entry.
- From the checker: one variant of A3 (from the blind MM1), A4, and the A6
  races. A4 and A6 are shared with Clojure, so they're Clojure's semantics
  rather than jank bugs, but they go against what Clojure documents (A4 its
  multimethod reference, A6 the docstrings).
- From reading the code to model it: A2, A3, A5, the cache reset of A3, and
  S3.
- From writing the tests: S1, S2, S4.

## Proofs for all sizes

Each proof is by `#check_invariants`: every property holds initially and every
action preserves the conjunction of all of them, for any number of threads,
requests, connections and so on. The SMT solver's answers are reconstructed
into Lean proofs that Lean's kernel checks (`veil.smt.trust false`), and
`#guard_msgs` pins the table of results in each file (except the module
cache's, where an expected failure's row can time out; its harness checks the
two proofs in the log). They are proofs about the models; the link to jank is
the conformance testing.

| Model | Proved | Auxiliary invariants |
|---|---|---|
| `Concurrency/Once.lean` | C5 `c5_delay_runs_once`, `c5_delay_derefs_agree`; C6 `c6_promise_first_wins`; C9 `c9_lazy_body_once`, `c9_lazy_realized_once` | the mutex is held exactly while the body runs, by one thread; what's cached; one value delivered; an unrealized lazy seq's body ran at most once |
| `Concurrency/Atom.lean` | C1 `c1_swaps_are_atomic` (no lost update), `c1_swap_results_increase` (each `swap!` returns more than the ones before it, so no two return the same) | the largest value returned is the number of `swap!`s; only `reset!` threads are mid-`reset!` |
| `Nrepl.lean` | `one_eval_per_connection`, `in_order`, `answered_only_when_alive_or_before`, N2, N7 | a connection with an eval in progress is busy; only evals are captured; descriptor 1 and each backup point to at most one temp file |
| `Blind/Vars.lean` | V1 `v1_alter_no_lost_update`, V2 `v2_intern_one_object` | the lock is held exactly while in `alter_root`, by one thread; objects are interned once |
| `Blind/Require.lean` | V7 `v7_require_complete` | the lib is complete once it's in `*loaded-libs*` |
| `ModuleCache.lean` | `deps_loaded`, `loaded_has_code` | |

The properties expected to fail are only required when `focus` selects them,
so their rows fail in the tables. That doesn't weaken the other proofs: with
`focus = 0` they hold trivially, so the others are inductive on their own, and
no action reads `focus`, so the reachable states are the same for every
`focus`.

To make the proofs possible, the `Option` and `List` fields of the Once, Atom
and nREPL models became relations, enums and functions over finite types
(SMT can't handle the former, and Veil's model checker can only store
functions over finite types). The reshaped models are the ones that are model
checked and replayed against jank: they explore exactly as many states as
before (58,421 and 42,488; 298; 8,970), and the recorded jank runs still
conform.

## nREPL N2 and N7

Both hold: `response-for` copies `id` and `session` into every response, and
the `:default` handler answers `[:error :unknown-op :done]`. The model has them
(and proves them for all sizes); the conformance check now records both, and
the 24 scripts × 3 runs conform again: every response carried its request's
`id` and `session`, and each unknown op was reported as one.

## Blind models

### Vars (`Blind/Vars.lean`) and `require` (`Blind/Require.lean`)

| Property (from the docstrings) | Result |
|---|---|
| V1 concurrent `alter-var-root`s lose no update | holds; proved for any number of threads |
| V2 (and V3, V6) concurrent interns of a var, namespace or keyword get one object | holds; proved (each is one find-or-insert under one write lock) |
| V4 `defonce` evaluates at most once | violated with two threads (A6); holds for one |
| V5 `with-redefs` restores the root | violated with two threads (A6); holds for one, also when the body throws |
| V7 `require` loads a lib once | violated with two threads (A6) |
| V7 ... and completely, when it returns | holds; proved for any number of threads |
| V8 a def is seen by another thread | holds by the code (`root` is a `std::atomic`, sequentially consistent); not modelled |
| `alter-var-root` returns (added after reading the code) | violated (A5) |

Conformance (`conformance/blind/vars.py`, outcome sets): three futures
`alter-var-root` (2000 runs: always 3), two `with-redefs` (2000 runs), two
`defonce`s (200 runs, a new var each), two `require`s (200 runs, a new lib
each), and the nested `alter-var-root`: every outcome is one the models allow,
and each allowed outcome showed up. Clojure, running the same programs,
shows the same outcomes except the last (it returns).

### Multimethods (`Blind/Multi.lean`)

The model checker builds the programs itself: any sequence of up to six
`derive`, `defmethod` and `prefer-method` steps over five dispatch values (one
is `:default`), with calls in between; a call goes through the method table in
every order. Next to jank's loop, the model runs Clojure's on the same order.

| Property | Result |
|---|---|
| MM1, MM2, MM3: a call uses the method of the matching value that dominates the others (Clojure's rules), `:default` or no method when none matches, "multiple methods" only when none dominates; every call sees the current hierarchy, methods and preferences | violated: A4 without preferences, A3 with one |
| jank's loop ends like Clojure's on the same order (added after reading the code) | holds without preferences (1,707,847 states); violated with one (A3) |
| MM4, MM5 (`get-method` and `methods`; concurrent `defmethod`) | not modelled. Every call takes the multimethod's lock to reset the cache, and dispatch runs under it; the cache pointer is read without the lock (a C++ data race, harmless on ARM64 in practice) |

Conformance (`conformance/multi/run.py`, program replay): the three
counterexamples and 300 random programs (870 calls) on jank: every result is
one the model allows. jank and Clojure differ only on the checker's preference
counterexample, and every Clojure result is one the model's copy of Clojure's
loop allows.

### Transients (`Blind/Transients.lean`, `Blind/ArrayMap.lean`)

| Property | Result |
|---|---|
| T1 the source is untouched | violated for array maps (A1; the storage model finds it in 4 steps); holds for vectors and sets in 500 random programs |
| T2 the result is right | violated for array maps when two transients share an array (A1); holds otherwise |
| T3 a finished transient can't be used | violated for 7 operations (A2) |
| T4 a result stays put | violated for array maps (A1; 6 steps) |
| T5 transients are independent | violated for array maps (A1; 5 steps) |
| T6 `pop!` on an empty transient vector throws and leaves it usable | holds (800,001 states) |

The storage model with persistent maps only (no transients) holds over
336,501 states.

Conformance:
- `conformance/transients/run.py`: every kind of transient, every operation it
  has, after `persistent!`: jank does what the model's table predicts (64
  operations; 7 return where they should throw, A2). And 500 random programs
  on jank and Clojure: Clojure passes all; jank fails 100, all on maps.
- `conformance/transients/arraymap.py` (program replay): 500 random programs
  of `{}`, `assoc`, `dissoc`, `transient`, `assoc!`, `dissoc!`, `persistent!`;
  jank prints every map exactly as the storage model predicts, including the
  38 programs where a map ends up with the wrong entries.

## Notes on Veil, phase 2

- `veil.smt.trust false` has to be set before the module (with `set_option
  ... in` on `#check_invariants` it has no effect), and then the solver's
  proofs are kernel-checked at little cost (seconds per model here).
- A `require` inside a `procedure` is an assertion the callers must
  establish, not an assumption.
- `let x :| p` only works in the executable model when the candidates can be
  enumerated from a relation in `p` (not from a type class's `next`).
- `max` doesn't translate to SMT; an `if` does.
