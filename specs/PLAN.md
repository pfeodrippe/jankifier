# Formal models of jank, in Veil

Status: phase 1 (sections 1 to 3) is done; the three models, their checks and
their conformance harnesses are in place, and [RESULTS.md](RESULTS.md) has
what was found. Two changes from this plan: the concurrency model is three
Veil modules (bindings and futures, atoms, run-once values), and the
concurrent parts are tested by outcome sets (every end result jank shows must
be one the model allows) rather than step by step, since their interleavings
can't be observed. Phase 2 ([below](#phase-2)) is done too, with these
changes from its plan: transients got two models (`Blind/Transients.lean`, which
operations check that a transient is active, and `Blind/ArrayMap.lean`, the
storage of array maps, written after the differential test found A1);
multimethods are modelled single-threaded (MM4 and MM5 aren't); and V3, V6 and
V8 are covered by the code pattern V2's proof covers, or by the code alone,
rather than models of their own.

Goal: formal models of three parts of jank, each checked with
[Veil](https://github.com/verse-lab/veil) and **tested against the real jank**
so that the model's behaviour matches the implementation:

1. the module loader and its compiled-module cache;
2. the concurrency model (atoms, vars and dynamic bindings, futures, delays,
   promises, lazy sequences);
3. the nREPL server.

The models describe what jank *does*, bugs included, next to properties that
users expect. A property that fails is a bug candidate, and it only counts as
a finding once it reproduces on the real jank.

## Versions

- jank: the installed `jank` 0.1 (`/opt/homebrew/bin/jank`). Its bundled jank
  sources and its 220 headers are identical to `~/dev/jank` at `f3d82d654`, so
  the C++ there is treated as its implementation. Every modelled behaviour
  cites `file:line` at that commit.
- Veil `v4.35.0` (Lean `v4.35.0`, prebuilt for macOS ARM64), z3 4.15.4.

## How each model is built and checked

1. **Model**: a Veil module (`JankSpecs/*.lean`) whose state and actions
   follow the code paths, with comments citing the code.
2. **Non-vacuity**: a `sat trace` per action (each can happen) and the empty
   `sat trace { }`.
3. **Properties**, in two groups:
   - *implementation facts*: what the code guarantees (e.g. "a module loaded
     from its object file has `mtime(o) >= mtime(source)`"), which must hold;
   - *expected properties*: what users or docs expect (e.g. "loaded code was
     compiled against the loaded versions of its dependencies"), which may not.
4. **Checks**: `#model_check` on finite instances, `#check_invariants` (proof
   for all instances) for the properties that hold where SMT can do it, and
   `sat`/`unsat trace` for specific reachability questions.
5. **Conformance with the real jank**, in both directions:
   - *model → jank*: every counterexample the model finds is turned into a
     concrete script and run on jank. It must reproduce; if it doesn't, the
     model is wrong and gets fixed.
   - *jank → model*: a harness generates random scenarios, runs them on jank,
     records what it observes, and checks each recorded trace against the
     model: the model must allow it (and, where the model is deterministic,
     predict exactly the same observations). The replay uses the model's
     executable actions (`#gen_executable`) from a Lean program, or, if that
     isn't usable, one `sat trace` per recorded trace with concrete actions
     and `assert`s on the observations.
6. **Results**: `RESULTS.md` lists each property as holds (proved, or model
   checked up to the stated bounds) or violated (model counterexample plus a
   reproduction on jank), and any model fixes made because conformance found
   a mismatch.

## 1. Module loader and cache

Code: `runtime/module/loader_dynamic.cpp` (`register_entry`, `find`,
`find_module`, `load`, `load_o`), `loader.cpp` (`is_loaded`,
`set_is_loaded`), `loader.hpp`; `clojure.core`'s `require`/`load`.

**State**
- Files: an ordered module path of directories; per directory and module, an
  optional source (`.jank` / `.cljc`, with a content version and an mtime)
  and an optional object file (`.o`, with the source version it was compiled
  from, the versions of the dependencies it was compiled against, and an
  mtime). A logical clock gives mtimes; equal mtimes are possible.
- A fixed dependency graph between modules (from their `ns` forms).
- Process: the module index (`entries`, built when the loader starts and
  extended only when a lookup misses), the loaded set (`*loaded-libs*`), and
  for each loaded module where its code came from (source / object file) and
  which versions it embodies.
- `*compile-files*` and the output target, which change what `find` picks.

**Actions**: edit a source, touch a file, compile a module (writes `.o` files
the way `jank compile-module` does), delete an object file, delete a source,
start a process (fresh index), `require` a module (loading its dependencies
first), `require … :reload`.

**Implementation facts to check**
- `find` picks the object file iff it exists, isn't in a JAR, and
  `mtime(o) >= mtime(source)` (a tie prefers the binary); with
  `*compile-files*` only when the target is `object`.
- A module without a source is an error, even with an object file.
- An already loaded module isn't loaded again without `:reload`.

**Expected properties (hypotheses)**
- M1 *dependency freshness*: loaded code was compiled against the versions of
  its dependencies which are loaded. Expected **violated**: `find` only
  compares a module's object file with its own source, so after a dependency
  changes, a dependent's old `.o` still counts as fresh. This is the stale
  cache crash we hit with the flecs example.
- M2 *first match wins*: as `loader.hpp` documents ("the first match for a
  module in the module path is the one taken"). Expected **violated**:
  `register_entry` overwrites an existing entry, so the *last* directory wins,
  and one module's entry can mix a source from one directory with an object
  file from another.
- M3 *index freshness*: in a running process, a file created after indexing
  is seen. Expected **violated** for modules already in the index: the index
  is only extended when a lookup misses.
- M4 *deleted source*: requiring a module whose source was deleted after
  indexing gives a "not found" error. Hypothesis: `last_write_time` on the
  missing file throws instead.

**Conformance harness** (`conformance/module_cache/`): builds temporary module
path directories with tiny modules that print their version, applies random
action sequences (edit, touch with chosen mtimes, `jank compile-module`,
delete, run), and records which version of each module ran. This model is
deterministic, so the model must predict exactly the same output for every
scenario (target: 200 random scenarios plus one per hypothesis).

## 2. Concurrency model

Code: `obj/atom.cpp`, `var.cpp`, `context.cpp` (`push_thread_bindings`,
`pop_thread_bindings`, `get_thread_bindings`), `core.cpp` (`future`,
`cancel_future`, `is_future_cancelled`), `obj/delay.cpp`, `obj/promise.cpp`,
`obj/lazy_sequence.cpp`, `obj/future.cpp`; `clojure.core`'s `binding`,
`future`, `future-cancel`, `bound-fn`.

**State**: threads (with their `std::thread::id`, which the OS can reuse
once a thread has been joined), the per-thread-id stacks of binding frames,
vars (root, dynamic flag, `thread_bound` flag), atoms (value, validator,
watch log), futures (status, result, joined?), delays (fn / value / error,
mutex holder), promises (status, value, waiters), lazy seqs (fn / value).

**Actions**: interleavings at the granularity of the code's atomic steps:
the load / call fn / validate / CAS steps of `swap!`; `reset!` (load, then
store, then notify); `compare-and-set!` (a weak CAS, which C++ allows to fail
spuriously); push / pop binding frames, `set!`, `alter-var-root`; create a
future (snapshot of the creator's bindings, new thread, push), finish, deref
(join), cancel; delay deref (lock, run, cache value or error); promise
deliver and deref (block until delivered); lazy seq realization (lock, call
fn, cache).

**Expected properties (hypotheses)**
- C1 *`swap!` is atomic*: the final value is the result of applying every
  swap's function in some order, each `swap!` returns the value it installed.
  Expected to hold.
- C2 *`compare-and-set!` succeeds when the current value is the old value*
  (Clojure's guarantee). jank uses `compare_exchange_weak`, which C++ allows
  to fail spuriously. Expected violated in the model; on Apple Silicon with
  LSE atomics it may never be observable, which the results will say.
- C3 *binding isolation*: a thread sees a dynamic binding only if it
  established it, or it was conveyed when its future was created. Expected
  **violated**: a future pushes its conveyed frame and never pops it, frames
  are keyed by thread id and never removed, so a later future whose thread
  reuses that id starts from the stale frame and sees the earlier future's
  bindings.
- C4 *frames are balanced*: a finished thread leaves no binding frames.
  Expected violated (the same never-popped frame; a leak).
- C5 *delay runs once*: its fn runs at most once, and every deref returns the
  same value or rethrows the same error. Expected to hold; a delay which
  derefs itself deadlocks (a non-recursive `std::mutex`), where Clojure
  overflows the stack.
- C6 *promise*: the first deliver wins, every deref returns that value, and
  deref blocks until it's delivered. Expected to hold.
- C7 *`set!`* only works on the thread which bound the var. Expected to hold.
- C8 *future cancel*: after `future-cancel`, the future reports cancelled and
  deref throws. Hypothesis: on macOS `is_future_cancelled` always returns
  false and the status stays `running`, so deref returns `nil`.
- C9 *lazy seq*: its fn runs once, or again after it threw. Expected to hold.

**Conformance harness** (`conformance/concurrency/`): jank programs which run
each scenario (with sleeps or promises to force specific interleavings),
print their observations, and run many times; every observed outcome must be
allowed by the model, and each model counterexample gets a targeted program
(e.g. C3: a future inside `(binding [*x* 1] …)`, deref it, then a future
outside the binding reads `*x*`). Deadlocks are detected with a timeout.

## 3. nREPL server

Code: `jank/nrepl/server/core.jank` (`handle-client`, `-main`),
`handler.jank`, `handler/*.jank`, `capture.jank`, `eval.jank`,
`evaluate.cpp` (`safe_eval`, which sets `*1`/`*2`/`*3`/`*e`).

**State**: connections, each served by its own future, which handles its
requests one at a time in order; requests (id, session, op, and for evals
what the code does: return, throw, print); the responses sent on each
connection; the process's stdout/stderr file descriptors and the capture
redirections in progress (`dup2` to a temp file and back); per-thread
bindings of `*1` / `*e` (conveyed to each connection's future); whether a
connection's loop is still running.

**Actions**: connect, send a request, the server's steps for each op (clone,
close, describe, eval / load-file split into capture start, eval, capture
end, respond; lookup, completions, unknown op), a handler throwing outside
`safe-eval` (e.g. a non-numeric `line`), disconnect.

**Expected properties (hypotheses)**
- N1 *every request gets exactly one `done`*, as its last response. Expected
  **violated** when a handler throws outside `safe-eval`: the connection's
  loop ends, and that request and every later one on the connection never get
  a response.
- N2 every response carries its request's `id` and `session`. Expected to
  hold.
- N3 *`done` comes separately from `eval-error`* (what nREPL itself does, and
  what CIDER 2.1 relies on). Expected violated: jank sends
  `[:done :eval-error]` in one message, which is the CIDER spinner leak
  `jankifier.nrepl` works around.
- N4 *output isolation*: a response's `:out` is what that request printed.
  Expected **violated** with evals on two connections at the same time: the
  captures redirect the same process-wide file descriptors.
- N5 *stdout is restored*: once no eval is running, stdout is the original.
  Hypothesis: overlapping captures restore in the wrong order and leave stdout
  pointing at a deleted temp file.
- N6 *sessions isolate state*: `*1` in one session isn't changed by an eval in
  another. Expected violated for two sessions on one connection (sessions
  aren't tracked; `*1` is bound per connection thread). Expected to hold
  across connections.
- N7 an unknown op gets `[:error :unknown-op :done]`. Expected to hold.

**Conformance harness** (`conformance/nrepl/`): starts `jank repl` (outside
the jankifier directory, since it writes `.nrepl-port`), drives it with a
bencode client over one or more connections, with random and targeted
request sequences, and records every request and response with timestamps.
Each recorded trace must be accepted by the model; targeted scenarios
reproduce each counterexample (N1 with a bad `line`, N4/N5 with two
concurrent evals that print).

## Layout

```
specs/
  PLAN.md            this plan
  RESULTS.md         findings, per property, with reproductions
  lakefile.lean      Veil v4.35.0 dependency
  JankSpecs/
    ModuleCache.lean
    Concurrency.lean   (split into several files if it grows)
    Nrepl.lean
    Conformance/       trace replay against the models
  conformance/
    module_cache/  concurrency/  nrepl/   harnesses run against real jank
    out/               recorded traces (gitignored)
```

## Milestones

1. Toolchain: Veil builds; a smoke model checks.
2. Module cache: model, checks, conformance, reproductions.
3. Concurrency: model, checks, conformance, reproductions.
4. nREPL: model, checks, conformance, reproductions.
5. `RESULTS.md`.

## Completion criteria, for each model

- `lake build` succeeds, running the model's Veil commands.
- Each action has a `sat trace`, and each modelled behaviour cites the code.
- Model checking completes for the stated instance sizes.
- Every property is classified as holds or violated; every violation has a
  model counterexample and a reproduction on jank 0.1, or the model was fixed.
- The conformance harness passes: recorded jank traces are accepted (and, for
  the module cache, predicted exactly).

## Not covered

The compiler (analyzer, macroexpansion, codegen, C++ interop), the GC, and
JAR handling beyond "object files in JARs are ignored". Those need other tools
(differential testing against Clojure on the JVM, fuzzing, sanitizers).

## Phase 2

Phase 1 found 14 bugs, but every one was suspected from reading the code
before the model checker ran: the checker confirmed them and gave minimal
reproductions, it didn't discover anything. And what holds was only checked
on small instances. Phase 2 does three things.

### A. Proofs for all sizes

Prove, with `#check_invariants` (inductive invariants discharged by SMT), the
properties that phase 1 only model checked on small instances:

- C1 `swap!` is atomic, for any number of threads and swaps;
- C5 a delay's body runs at most once, and every deref that returns agrees;
- C6 a promise's first delivery wins;
- `one_eval_per_connection` and `in_order` for the nREPL server, for any
  number of connections and requests.

SMT can't handle the `List` and `Option` fields of those models, so their
state is reshaped into relations and functions over the model's types. The
reshaped model must stay the one that's model checked and replayed against
jank (no separate "proof model"), so the conformance checks rerun after the
change. Each proof needs auxiliary invariants (an inductive strengthening);
they are listed with the proof.

### B. nREPL N2 and N7

The two nREPL properties of the plan that the model left out:

- N2 every response carries its request's `id` and `session`;
- N7 an unknown op gets `[:error :unknown-op :done]`.

Both go in `Nrepl.lean` and in the conformance projection.

### C. Blind models

Models of parts of jank whose implementation hasn't been read yet, built in
this order, so the properties can't be shaped by suspicions:

1. The properties are written first, below, from what the code promises:
   Clojure's docstrings (jank ports `clojure.core` with them) and Clojure's
   documented behaviour. They're fixed here before any of the code is read.
2. The model follows the code step by step: each read and write of shared
   state, lock, and branch where the code has one, citing `file:line`, with no
   abstraction aimed at a property.
3. The checker searches; every violation is then reproduced on jank, and
   each model gets a conformance harness (random programs, outcome sets or
   trace replay) as in phase 1.

A violation found this way counts as found by the checker. If one also
violates in Clojure on the JVM, `RESULTS.md` says so.

Already read in phase 1, so not blind: `context.cpp`'s thread bindings and
`var::set`, the module loader (sequentially; its concurrency wasn't looked
at), `atom.cpp`, `delay.cpp`, `promise.cpp`, `lazy_sequence.cpp`, `future`
and the nREPL server.

Not ported in jank 0.1, so not modelled (each throws "TODO: port ...", checked
by running it): agents (`agent`, `send`, `await`), refs (`dosync`), `var-set`,
`with-local-vars`, `flush`; `set!` doesn't resolve, and `locking` expands to
an unresolved `monitor-enter`.

#### C1. Vars and namespaces

Code (to be read after this section is written): `runtime/var.cpp`,
`ns.cpp`, `ns_dynamic.cpp`, the var, namespace and keyword parts of
`context.cpp`; `clojure.core`'s `def`, `intern`, `alter-var-root`, `defonce`,
`with-redefs`, `create-ns`, `keyword`, `require`.

Properties, from the docstrings:

- V1 *`alter-var-root` is atomic* ("Atomically alters the root binding of var
  v by applying f to its current value plus any args"): concurrent
  `alter-var-root`s of one var lose no update.
- V2 *`intern` finds or creates one var* ("Finds or creates a var named by the
  symbol name in the namespace ns"): concurrent `intern`s of one name return
  the same var, and it's what the namespace maps afterwards.
- V3 *`create-ns` finds or creates one namespace* ("returns it or the
  already-existing namespace of the same name"): concurrent `create-ns`s of
  one name return the same namespace.
- V4 *`defonce` evaluates at most once* ("defs name to have the root value of
  the expr iff the named var has no root value, else expr is unevaluated").
- V5 *`with-redefs` restores* ("After the body is executed, the root values of
  all the Vars will be set back to their old values"), also when the body
  throws; during the body the new roots are visible in all threads.
- V6 *keywords are interned*: `(keyword "a")` is identical to `:a`, also when
  two threads create the same keyword at once.
- V7 *`require` loads a lib once and completely* ("Loads libs, skipping any
  that are already loaded"): with concurrent `require`s of one lib, its body
  runs once, and when a `require` returns, the lib's vars are defined.
- V8 *a var defined in one thread is seen by another thread* once the other
  thread knows the definition happened (e.g. after dereffing a promise the
  first thread delivered): its root is the defined value.

#### C2. Multimethods

Code: `runtime/obj/multi_function.cpp`; `clojure.core`'s `defmulti`,
`defmethod`, `remove-method`, `remove-all-methods`, `prefer-method`,
`prefers`, `methods`, `get-method`, `derive`, `underive`, `isa?`.

Properties, from the docstrings and Clojure's dispatch rules:

- MM1 *dispatch*: a call uses the method for its exact dispatch value if there
  is one; else the method whose dispatch value the value `isa?`, if exactly
  one is most specific (or preferred); else the `:default` method; else it
  throws ("No method in multimethod ... for dispatch value").
- MM2 *ambiguity*: when two methods match and neither dominates nor is
  preferred, the call throws ("Multiple methods ... match"); after
  `(prefer-method f x y)` it uses `x`'s.
- MM3 *changes are seen*: after `defmethod`, `remove-method`,
  `remove-all-methods`, `prefer-method`, `derive` or `underive` returns, every
  later call (in any thread that knows the change happened) dispatches by the
  new methods, preferences and hierarchy, whatever it called before (no stale
  cache).
- MM4 *`get-method` and `methods` agree with dispatch*: `get-method` returns
  the method a call would use, and `methods` maps exactly the defined
  dispatch values.
- MM5 *concurrent changes*: a call concurrent with a `defmethod` uses the old
  or the new method set, never a mix, and never fails when both have a
  method for its value.

#### C3. Transients

Code: `runtime/obj/transient_vector.cpp`, `transient_hash_map.cpp`,
`transient_array_map.cpp`, `transient_hash_set.cpp`,
`transient_sorted_map.cpp`, `transient_sorted_set.cpp`; `clojure.core`'s
`transient`, `persistent!`, `conj!`, `assoc!`, `dissoc!`, `disj!`, `pop!`.

Properties, from the docstrings:

- T1 *the source is untouched* ("Returns a new, transient version of the
  collection"): no operation on a transient changes the collection it was made
  from, or any other persistent collection.
- T2 *the result is right*: `persistent!` returns what the same operations
  would give on the persistent collection (`conj`, `assoc`, `dissoc`, `disj`,
  `pop`).
- T3 *a finished transient can't be used* ("The transient collection cannot be
  used after this call, any such use will throw an exception"): every
  operation after `persistent!` throws, including a second `persistent!`.
- T4 *a result stays put*: a collection returned by `persistent!` isn't changed
  by later operations on its transient, nor on new transients made from it.
- T5 *transients are independent*: two transients made from one collection
  don't affect each other.
- T6 *errors*: `pop!` on an empty transient vector throws, and leaves the
  transient usable.
