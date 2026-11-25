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

"Upstream" is what jank's issues and pull requests say about each finding
(searched on 2026-11-21, by keyword: "none found" isn't proof there's
none), and whether it's still on jank's main branch: the build published on
2026-11-20 (`774d02f62`), checked with the reproductions and the harnesses
(`JANK=...`, see [README.md](README.md#testing-against-jank)). Of all the
findings, N1 and S5 are fixed there; S8 now compiles but gives a wrong value;
the rest are still there (the sources of A1–A5, C2–C8, M1–M5, N4/N5 and S10
are unchanged since 0.1).

| # | Finding | Where | Reproduction | Upstream |
|---|---|---|---|---|
| M1 | A module's object file is loaded although it was compiled against an older version of a dependency: `find` only compares a module's `.o` with its own source. `jank compile-module` doesn't rebuild it either (the module loads from its fresh `.o`, so nothing is written). Macros and inlined code from the old dependency run. | `loader_dynamic.cpp` `find` | compile `app` (requires `lib`), edit `lib`, run: `app` shows `lib`'s old macro | none found; on main: still there |
| M2 | When two directories on the module path have the same module, the **last** wins, although `loader.hpp` says the first does (`register_entry` overwrites). A module's source and object file can come from different directories. | `loader_dynamic.cpp` `register_entry` | `lib` in `a` and `b`, `--module-path a:b`: `b`'s loads | none found; on main: still there |
| M3 | A running REPL never sees an object file created after it started for a module it already indexed (the index is only rebuilt on a lookup miss), so it keeps loading the source. | `find_module` | REPL starts, `compile-module late` elsewhere, `(require 'late)` loads the source | none found; on main: still there |
| M4 | A module whose source was deleted, with an object file, fails with `filesystem error: in last_write_time: No such file or directory` instead of "not found". | `find` (`last_modified_at`) | compile, delete the source, require | none found; on main: still there |
| M5 | `(require 'm :reload)` after `m`'s object file was rebuilt runs the **old** code: `load_o` calls the `jank_load_m` already in the process instead of loading the new object file. | `loader_dynamic.cpp` `load_o` | REPL loads `lib` from `.o` v1, rebuild `lib.o` as v2 elsewhere, reload: v1 runs | none found; on main: still there |
| C3 | A future can see another future's dynamic bindings: a future's thread pushes a binding frame and never pops it, frames are keyed by OS thread id and never removed, and macOS reuses thread ids, so a later future on the same id starts from the stale frame. 200 out of 200 tries leaked. | `core.cpp` `future`, `context.cpp` `push_thread_bindings` | `@(binding [*x* 1] (future *x*))` then `@(future *x*)` returns `1` | none found; on main: still there |
| C4 | The same never-popped frame: every finished future leaves its frame in the map (a leak). | same | 1000 futures leave 1000 frames (counted through C++ interop: `repro/binding-frames-never-freed.jank`) | none found; on main: still there |
| C5 | A delay whose body derefs the delay deadlocks (its `std::mutex` isn't recursive); Clojure reports a stack overflow. | `delay.cpp` | `(def d (delay (inc @d)))`, `@d` hangs | none found; on main: still there |
| C8 | On macOS, `future-cancel` returns `nil`, `future-cancelled?` stays `false`, `realized?` stays `false`, and `@f` returns `nil` instead of throwing. The thread is cancelled, but nothing records it. | `core.cpp` `cancel_future`, `is_future_cancelled` | cancel a sleeping future, deref it | none found; on main: still there |
| N1 | An eval request with a bad argument (e.g. `"line": "bad"`) throws outside `safe-eval`, which ends the connection's loop: that request and every later one on the connection never get a response, so the client hangs. | `nrepl/server/core.jank` `handle-client` | eval with `"line": "bad"`, then any request on the same connection | #1169 (open); **fixed on main** (PR #1175): an error response, and the connection goes on; main conforms to the model with the `n1` fix |
| N3 | A failed eval sends `:ex` and `:status [:done :eval-error]` in one message; nREPL sends `done` separately, and CIDER 2.1 leaks a pending request (its spinner) on the combined one. (`jankifier.nrepl` works around it.) | `handler/eval.jank` | eval `(throw ...)` | none found; on main: still there |
| N4 | Output capture is process-wide: with evals on two connections at once, one request's `:out` gets another request's prints, or they go to the server's own stdout. | `capture.jank` | two connections evaluating code which prints | none found (#1022, closed: a crash with two clients evaluating at once); on main: still there |
| N5 | Overlapping captures restore stdout in the wrong order and can leave the server's file descriptor 1 pointing at a deleted temp file: everything printed outside an eval afterwards (e.g. from a future) is lost. | `capture.jank` | two connections evaluating at once, then a future which prints | none found (#1022, as N4); on main: still there |
| N6 | Sessions aren't tracked: `*1` belongs to the connection, so an eval of `*1` in one session returns another session's last value. | `handler/clone.jank`, `evaluate.cpp` | eval in session A, then `*1` in session B on the same connection | known: PR #1175 says sessions aren't tracked (`proof`'s `session.isolated` fails); no issue; on main: still there |

## Findings from a Lean replica of jank

A second model, a Lean replica of jank written blind from its sources (determinismo's
`lean/jank`), predicted 120 deviations from Clojure in rounds 1 and 2. On jank main (`7135b7708`,
x86-64 Linux) 108 were confirmed exactly (4 of them after a rerun: the test runner had dropped
their reports) and 8 were refuted (3 of them fixed after 0.1). Round 3, which replicated the
libraries jank runs on, predicted 76 more (LS1–LS76 here): of the 57 with a test, 48 were
confirmed, 4 refuted, 3 failed in another way, and 2 (LS50, LS53) had tests that couldn't tell until round 4's rerun confirmed them (LU5, LU6). Round 4
(LU1–LU92 here) re-stated round 3's unclear items and covered the parts no round had touched; of
its 87 tests, 66 confirmed by the value or error predicted (5 hangs and a segfault among them),
and a rerun with the test runner fixed (24 tests, each failing in all three of its timelines)
recorded every error's text: 16 more of round 4's tests confirmed their prediction, one (u82) found
another bug instead (reading any `#inst` needs the `en_US.UTF-8` locale, LU82), three (u88–u90)
couldn't load `jank.shell` in the test image and wait, and round 3's four errors without text (LS1,
LS36, LS37, LS42) now have it. Their minimal examples, code paths and upstream status are in
[repros.md](repros.md#found-by-a-lean-replica-of-jank); the replica and its tests are in
determinismo-workloads' [jank-interop/lean](https://github.com/determinismo-dst/determinismo-workloads/tree/main/workloads/jank-interop/lean).

- **Crashes**: D9 (NaN from `∞-∞` or `0.0/0.0`, SIGSEGV on x86-64), D2b (int32 minimum / -1,
  SIGFPE), R47 (a parameter named like its fn), R119 (`first` of an infinite mapped real range),
  R97 (`(compare :a 1)`, the `catch` never runs), D24 (a throwing `catch` then a throwing
  `finally`, `std::terminate`), LS34 (a long input to a regex overflows the stack), LU26
  (`cpp/delete` of a pointer from C++'s `new`), LU79 (`slurp` of a missing file: an uncatchable
  native error).
- **Hangs**: R1 (NUL in `read-string`), D16 (a watch removing itself), R116 (`range` past 2^31),
  R117 (`doseq` over a held cons), LS62–LS65 and LS67 (locks re-entered by validators,
  `alter-var-root`, `realized?`, `future-cancel`, lazy var metadata), LU13 (`alter-var-root`
  first-calling its fn), LU19 (`defmethod` with a lazy dispatch value), LU28 (`with-meta` on
  `iterate` or `(range)`).
- **Wrong values**:
  - numbers: D2, D4b, D5–D8, D10, D12, D13, R23, R24, R26, R44, R99, R122, LS3–LS8, LS10–LS12,
    LS14–LS21, LS40, LU1, LU2, LU75, LU83, LU84;
  - concurrency: D18, D19, LU15, LU18;
  - the compiler: R29, R30, R33, R34, R37, R38, R42, R103, R108, R110, R112, LS38, LS41, LU3,
    LU4, LU7–LU11, LU14 (lazily compiled fns: a var's root rebound at a fn's first call, losing
    `alter-var-root` wrappers and `with-redefs` stubs), LU20, LU23–LU25 (C++ operators and
    templates);
  - collections: R105, R118, R120, R121, LS59, LS60, LU27, LU31–LU34, LU61, LU66, LU67, LU69, LU81;
  - the reader: R4–R6, R10, R11, R13–R16, R19–R21, LU40, LU71;
  - strings and printing: R53, R55–R61, R63, R68–R72, R76, LS73, LU16, LU39, LU63, LU64, LU65,
    LU70, LU78, LU85, LU86, LU91;
  - regex: R79, R81, R82, R84, LS22, LS23, LS25, LS26, LS29–LS31, LS33, LU35–LU38;
  - nREPL and the REPL: LU41, LU44;
  - modules and the CLI: LU45, LU50, LU51, LU55.
- **Errors where Clojure works**: D25, R2, R3, R7, R8, R12, R17, R18, R27, R28, R39–R41, R73,
  R74, R96, R98, R101, R104, R114, LS1, LS18, LS24, LS27, LS28, LS32, LS35–LS37, LS42, LS61,
  LS71, LU5, LU6, LU12, LU17, LU21, LU22 (C++ interop: a reference parameter, a converting class,
  scoped enums, a hidden base operator), LU29, LU30, LU48, LU49, LU59, LU62, LU68, LU72–LU74,
  LU76, LU77, LU80, LU82 (`#inst` needs the `en_US.UTF-8` locale), LU87, LU92.
- **Upstream**: D1, R25 and D4 are #1208; D15 is A2 here, R100 is A3, D21 is S3, R80 is S6, D22
  is C3 (which also happens on Linux). LS60 is #1235's map case.
  The rest: no issue found (keyword search, 2026-11-25).

An earlier version listed "W": watch notifications of concurrent `swap!`s
arriving out of order. It isn't a finding: `add-watch`'s docstring allows it,
and Clojure does the same.

## Properties

### Module loader and cache (`JankSpecs/ModuleCache.lean`)

Instance: modules `lib` and `app` (requires `lib`), directories `a`, `b` and the
build directory, two processes; 847,850 states up to depth 7 (713,074 before
the model recorded what each load's lookup chose, for M2 and M3).

| Property | Result |
|---|---|
| `deps_loaded`: a loaded module's dependencies are loaded | holds; proved for all instances by `#check_invariants` (kernel-checked since phase 2) |
| `loaded_has_code` | holds; proved for all instances (kernel-checked since phase 2) |
| M1 `m1_object_matches_dependencies` | violated |
| M2 `m2_first_match_wins` (a load uses the first directory's source) | violated |
| M3 `m3_index_sees_new_objects` (a load's lookup knows the object files on disk) | violated |
| M4 `m4_deleted_source_reported` | violated |
| M5 `m5_load_runs_chosen_object` | violated |

Conformance (traces): the 5 counterexamples (which end with the load that
shows the effect) and 30 random scenarios of edits, touches,
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

| # | Finding | Where | Reproduction | Found by | Clojure | Upstream |
|---|---|---|---|---|---|---|
| A1 | **Transients of array maps (every map of up to 8 entries) write into the maps they came from.** `native_array_map`'s copy constructor is `= default`, so `transient` shares the persistent map's array; `assoc!` of an existing key overwrites it in place, `dissoc!` shifts it in place (leaving a duplicate key), and a key added while capacity is left is written in place. `persistent!` hands the same array to its result, so a later transient of the result changes it too. Ordinary `clojure.core` functions use transients: `(into m {:a 9})`, `(into m [[:b 7]])` and `(update-vals m inc)` change `m`. | `detail/native_array_map.hpp:33`, `obj/transient_array_map.cpp:24`, `native_array_map.cpp:139`, `:168` | `(let [m {:a 1}] (into m {:a 2}) m)` is `{:a 2}`; `(let [m {:a 1 :b 2}] (persistent! (dissoc! (transient m) :a)) m)` is `{:b 2, :b 2}` | the differential test of the blind T1/T4 (100 of 500 random programs, all on maps); then the storage model (`ArrayMap.lean`), whose checker finds it in 4 steps | jank only | #1190 (open); on main: still there |
| A2 | Reading a transient after `persistent!` returns data instead of throwing, for 7 operations: on a vector `nth` (one argument), `contains?`, `find`; on an array map `get` with a fallback, `contains?`, `find`, calling it with a fallback. Those methods don't call `assert_active`. | `obj/transient_vector.cpp:53`, `:198`, `:217`; `obj/transient_array_map.cpp` | `(let [t (transient [1])] (persistent! t) (nth t 0))` is `1` | reading the code for the model; checked by the model's table on jank | jank only (Clojure throws) | none found; on main: still there |
| A3 | Multimethod dispatch ignores a preference declared on an ancestor: `is_preferred` gets the hierarchy *var* (`reset_cache` stores `hierarchy`, not its value), and `(parents var tag)` is `nil`. jank throws "multiple methods" where Clojure picks the preferred one. (Comparing the var with its value also resets the cache on every call.) | `obj/multi_function.cpp:136`, `:185`, `:248` | `(derive ::c ::a2) (derive ::a2 ::a) (derive ::c ::b)`, methods on `::a2` and `::b`, `(prefer-method f ::a ::b)`, `(f ::c)` | reading the code (this variant), and the checker from the blind MM1 (the variant with the preference on the other value's ancestor) | jank only | none found; on main: still there |
| A4 | Multimethod dispatch depends on the method table's hash order: with methods on `i`, `j` and `k`, where `k` is more specific than both, the call throws "multiple methods" if the table lists `i` and `j` before `k`. | `obj/multi_function.cpp:262` (Clojure's `MultiFn.findAndCacheBestMethod`) | 14 of 40 name sets throw on jank, 9 of 40 on Clojure | the checker, from the blind MM1 (no preferences); also seen while modelling the loop | shared with Clojure | none found; on main: still there |
| A5 | `alter-var-root` deadlocks when its function alters the same var: `alter_root` holds `write_mutex` (not recursive) while calling the function. | `runtime/var.cpp:106` | `(alter-var-root #'z (fn [v] (alter-var-root #'z inc) (inc v)))` hangs; Clojure returns, root 1 | reading the code (a property added after reading it) | jank only | none found; on main: still there |
| A6 | Races that the docstrings don't allow: two `defonce`s of one var both evaluate the expression (V4); two `with-redefs` of one var leave it redefined (V5); two `require`s of one lib both load it (V7). | `clojure/core.jank:4289`, `:4549`, `:4836` | futures started together: `defonce` evaluated twice in 162 of 200 runs, `with-redefs` left the var at 50 in 1696 of 2000, `require` loaded twice in 197 of 200 | the checker, from the blind V4, V5, V7 | shared with Clojure (157 of 200, 1175 of 2000, 199 of 200) | none found; on main: still there |

Found along the way, without a model (each has its file in
[repro/](repro/README.md) too):

| # | Finding | Reproduction | Upstream |
|---|---|---|---|
| S1 | Printing an exception's stack trace (`pr-str` or `str` of an `ex-info`) makes the process crash with SIGSEGV when it exits, after `-main` returned. | `(defn -main [& _] (println (pr-str (ex-info "boom" {}))))`, exit code 139; with `(cpp/_exit 0)` it's 0 | maybe #854 (open: segfaults at exit); on main: still there |
| S2 | A `let*` or `loop` whose value is a string literal doesn't compile: codegen declares its result with the literal's C++ type (`const char[9] v17{ };`). `let` and `loop` expand to them. | `(defn f [x] (let [t x] "ok"))`; `(let [] "ok")`; `(do x "ok")` and `(let [t x] (str "ok"))` compile | related: #1023 (closed 2026-10-08, before 0.1; this case remains); on main: still there |
| S3 | `(deref ref timeout-ms timeout-val)` is an empty stub ("TODO: Blocking" in `clojure/core.jank:1096`): it returns `nil` at once, without waiting or returning `timeout-val`. | `(deref (future (cpp/usleep 2000000) 1) 10 :timeout)` and `(deref (promise) 10 :timeout)` are `nil` (a plain `deref` of a future that threw does rethrow) | none found; on main: still there |
| S4 | Not ported, so not modelled: agents, refs (`dosync`), `var-set`, `with-local-vars`, `flush` (each throws "TODO: port ..."); `set!` doesn't resolve; `locking` expands to an unresolved `monitor-enter`. | | — |
| S5 | `sort` and `sort-by` of an empty collection return an empty `native_vector_sequence`, which `first` reads past the end of (its constructor asserts non-empty in debug builds only, `obj/native_vector_sequence.cpp:24`; `runtime/core/seq.cpp:1118`, `:1165`): SIGSEGV. `seq` of it is `nil`, so `seq`-based code works. | `(first (sort []))`, `(first (sort-by identity []))`, `(clojure.string/join ", " (sort []))` crash; `(vec (sort []))` is `[]` | #1181; **fixed on main** (PR #1182) |
| S6 | `re-find` and `re-matches` give `""` for an optional group that didn't match; Clojure gives `nil`. | `(re-find #"a(b)?" "a")` is `["a" ""]`, Clojure `["a" nil]` | none found; on main: still there |
| S7 | **`if` with a number literal in one branch and a boolean literal in the other returns a number for the boolean**: the result gets the number's C++ type, and the boolean is converted (`true` to 1, `false` to 0). No error; the value is wrong. | `((fn [k] (if (= k :a) 1 true)) :b)` is `1`, `((fn [k] (if (= k :a) 1 false)) :b)` is `0`; with `:one` instead of `1` it's `true` | related: #1187 (closed 2026-11-17); on main: still there |
| S8 | A `case` whose default is a number or boolean literal doesn't compile: the generated C++ assigns the literal's native value to the result object (`no viable overloaded '='`, from `case*`, `clojure/core.jank:4531`). jank compiles a function's body when it's first called, so the error shows then. | `(defn f [k] (case k :a 1 true))` then `(f :b)`; with a `nil` or keyword default it works | related: #1025 (closed 2026-11-17, PR #1116); **on main it compiles, but returns the wrong value**: `(case k :a 1 true)` is `1`, as in S7 |
| S9 | **Arithmetic on `count`'s result is unsigned** when jank compiles it natively (`count` gives a C++ `usize`): a subtraction below zero wraps around, and comparisons see the huge number, while functions that box it (`neg?`, `pr-str`) see a negative one. | `(let [s "abc"] (- (count s) 3000))` prints `-2997`, but `(let [s "abc"] (< (- (count s) 3000) 0))` is `false` and `(let [s "abc"] (max 0 (- (count s) 3000)))` is `-2997`; `(max 0 (- 73 3000))` is `0` | none found; on main: still there |
| S10 | **Integer arithmetic wraps at 32 bits**: numbers that fit in 32 bits are `small_integer`s, whose `data` is an `i32`, and `+`, `-` and `*` of two of them compute `typed_l->data + typed_r->data` in `i32` before boxing (`runtime/core/math.hpp:83`, and `sub`, `mul` alike). No error; the value is wrong. (`inc` and `+'` promote correctly.) | `(+ 2147483647 1)` is `-2147483648`, `(* 1000000000 1000000000)` is `-1486618624`, `(reduce + (repeat 3 1000000000))` is `-1294967296`, also from `jank run`; Clojure gives `2147483648`, `1000000000000000000`, `3000000000` | #1208 (open); on main: still there |

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
- From porting the conformance harnesses to jank: S5, S6, S7, S8, S9, S10.

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

Conformance (`jank-specs.conformance.vars`, outcome sets): three futures
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

Conformance (`jank-specs.conformance.multi`, program replay): the three
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
- `jank-specs.conformance.transients`: every kind of transient, every operation it
  has, after `persistent!`: jank does what the model's table predicts (64
  operations; 7 return where they should throw, A2). And 500 random programs
  on jank and Clojure: Clojure passes all; jank fails 100, all on maps.
- `jank-specs.conformance.arraymap` (program replay): 500 random programs
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

# Proposed fixes

Each finding of the models has a proposed fix, written into its model before
any C++: a value of the model's `fix_t`, which the theory value `fixed`
turns on (the model's docstring says what each changes in jank). Each was
checked the way its finding was found: the finding's property with the fix,
by the model checker (no violation), and where the model has proofs, a
property `fixed x → ...` proved for any number of threads, connections or
requests (kernel-checked, pinned with `#guard_msgs`). Every other property
was checked with the fixes on too. The proofs which already held quantify
over the theory, so they hold with every combination of fixes.

The harnesses take the fixes (`(c/check "nrepl" {:fixes [:n1 :n3 :n4n5
:n6]})`) and then check jank against the fixed model: the regression test
once a fix is written.

| Finding | Fix | Checked |
|---|---|---|
| C2 | `compare-and-set!` uses `compare_exchange_strong` (`swap!` keeps the weak one: there a spurious failure only costs a retry) | proved for all instances (`c2_fixed_cas_succeeds_on_match`); 68 states with two threads |
| C3, C4 | a future's thread pops the frame it pushed when it ends, by returning or by being cancelled (a `pthread_cleanup_push` handler) | C3 and C4: 21,437 states each |
| C5 | a deref of a delay by the thread running its body throws at once, so the body throws and the delay caches the error (Clojure's recursive lock runs the body again until the stack overflows) | proved for all instances (`c5_fixed_deref_returns`); 1,200 states with two threads |
| C8 | `future-cancel` records the cancellation, so deref throws and `future-cancelled?` is true | 23,933 states; with C3/C4's fix too, everything that held still holds (21,437 states) |
| A5 | `write_mutex` is recursive, as Clojure's `synchronized alterRoot`; the outer `alter-var-root` then stores `(f v)` over the nested one's value, as on Clojure. A compare-and-set loop instead would loop forever on this `f`: each retry alters the var again | proved for all instances (`v1_fixed_alter_returns`); one and two threads |
| N1 | converting an eval's arguments is inside the handler's `try`: an error response, and the loop goes on | proved (`n1_fixed_connection_survives`); 25 states |
| N3 | `done` in its own message, after `:ex` and `eval-error` | proved (`n3_fixed_done_separate`); 25 states |
| N4, N5 | an eval's output goes to a writer of its own (`*out*` bound for the request, `println` writing to `*out*`), instead of moving file descriptor 1 | proved (`n4_fixed_output_isolation`, `n5_fixed_stdout_restored`, with three auxiliary invariants); 269 states each |
| N6 | sessions are tracked, each with its own `*1` | proved (`n6_fixed_sessions_isolated`, with an auxiliary invariant); 25 states; all four nREPL fixes together, every request kind: 269 states |
| A1 | `transient` of an array map clones the array (as persistent `assoc` does), so a transient never writes into the map it came from; `persistent!` can still move the array into its result | T1, T4 and T5: 10,568,901 states each, up to depth 6 (their counterexamples take 4 to 6 steps; the whole space with transients is too large) |
| A2 | the seven methods which don't call `assert_active` call it | T3: 800,001 states |
| A3 | `reset_cache` stores the hierarchy's value, so `is_preferred` follows ancestors, as Clojure does | jank's loop ends like Clojure's with a preference: 16,076,355 states |
| A4 (shared with Clojure) | after the loop, the result is the matching value which dominates every other one, if there's one, whatever the table's order (beyond Clojure's `MultiFn`, towards the rule Clojure documents) | MM1 without preferences: 1,710,007 states; with A3's fix too, with a preference: 16,106,115 states |
| M1 | an object file records the versions (hashes) of the dependencies it was compiled against, and loads only if they're the ones loaded now | 847,850 states, up to depth 7 |
| M2 | `register_entry` keeps the first directory's entry | not enough alone (the model checker shows it, pinned): a module added to an earlier directory after the process started is still found in the stale index's later one. With M3's fix too: 786,538 states, up to depth 7 |
| M3 | every lookup looks at the module's files again, as a miss does now | 786,514 states, up to depth 7 |
| M4 | `find` checks the indexed source still exists before reading its mtime: "no source", not a filesystem error | 847,850 states, up to depth 7 |
| M5 | `load_o` loads the object file it chose even when `jank_load_<module>` exists (looked up in the new object's own handle) | 847,850 states, up to depth 7 |

Not modelled as fixes: A6, the races shared with Clojure (two `defonce`s,
two `with-redefs`, two `require`s of one name at once). `with-redefs`
changes the root for every thread by design; making it exclusive would
deadlock a body which waits for another thread's `with-redefs`.

What checking the fixes found:

- M2's fix needs M3's, as above. And M2 and M3 were stated over the index,
  which is a cache: right after another process writes a file, every index is
  out of date, whatever the loader does, so no fix could satisfy them. They're
  now stated over what a load uses (its source is the first directory's; its
  lookup knows the object files on disk), which is what users see; their
  counterexamples on jank 0.1 are the same.
- `conveyed_on_top` in the bindings model said "a future not yet joined has
  its binding on top"; with C3/C4's fix a finished future has popped its
  frame. Its comment says "a running future", so it's now stated for running
  futures (it held, and holds, for jank 0.1 too).
- C8's property says a deref of a cancelled future doesn't return a value;
  with the fix it throws, which the model now records (`lastDerefThrew`).

Against the fixed models, jank 0.1 fails each harness on the scenarios which
show the findings (C5's needed a scenario of its own: a delay whose body
derefs it, run in a separate process, since jank deadlocks), except atoms with
C2's fix: this machine's `casal` never fails spuriously, so jank already
shows only what the fixed model allows.
