# Working on the specs

For agents (and people) changing the models, harnesses or reproductions in
`specs/`. What the specs are: [README.md](README.md); the approach:
[PLAN.md](PLAN.md); what was found: [RESULTS.md](RESULTS.md). Everything below
was hit while building them, with Veil `v4.35.0` and jank 0.1.

## Conventions

- For code that hasn't been read yet, the properties are written from the
  docstrings (and Clojure's documented behaviour) in `PLAN.md` first; then the
  code is read and modelled step by step. A property added after reading the
  code is labelled as such, and `RESULTS.md` ("How each finding was found")
  says how each finding was found.
- A violated property is a finding only if a docstring, Clojure's reference or
  jank's own docs promise it (watch call order looked like a bug, and is
  documented behaviour).
- Every model has a conformance check against jank (trace replay, outcome
  sets, program replay or a differential test against Clojure). Most model
  mistakes were found this way.
- A property expected to fail is written `focus = k → ...` and gets its own
  `#model_check` with that `focus`. The proofs stay sound because with
  `focus = 0` those properties hold trivially and no action reads `focus`; the
  comment next to `#check_invariants` says so.
- Proofs are kernel-checked (`set_option veil.smt.trust false` at the top of
  the file), and the `#check_invariants` table is pinned with `#guard_msgs`
  (unless a row can time out, see below), so the build fails when a proof
  breaks.
- Every finding has a reproduction in [repro/](repro/README.md): a `.cljc`
  that runs on jank and Clojure when possible; nondeterministic ones run many
  times and print how often the bug showed up.
- jank runs in scratch directories (`scratch_dir` in
  `conformance/lib/jank_harness.py`, under the ignored `conformance/out/`),
  because `jank repl` writes `.nrepl-port` in its directory.

## Veil: writing models

| Symptom | Cause, and what to do |
|---|---|
| `type module` doesn't parse | `module` is a keyword (so is `trace` inside a module); rename (`modname`) |
| A property with a variable `W` doesn't elaborate (`W` has a function type) | Some single letters name things already in scope; use another letter |
| A docstring (`/-- ... -/`) before a Veil declaration or an `#eval` is rejected | Use a plain comment (`/- ... -/`) |
| Veil's generated code doesn't compile | Don't set `autoImplicit false` |
| Assigning a `Prop` to a `Bool` field fails | Wrap it in `decide` |
| `doesNotThrow` fails for the callers of a procedure | A `require` inside a `procedure` is an assertion the callers must establish; put the `require` in the actions |
| A field update reads a field the same action already changed | `f X := e` reads the old `f` (all `X` at once), but later statements see earlier ones; order the updates (update `cellVal` before the `cellKey` its condition reads) |
| `⟨...⟩` for a `Theory` breaks when a field is added | Use named fields: `{ prog := ..., focus := 0 }` |
| `failed to synthesize ... EnumClass` outside the module | Open the module's namespace (`open Require`) in a namespace of its own |

## Veil: model checking and executable models

| Symptom | Cause, and what to do |
|---|---|
| A field prints as `<unrepresentable>` and the state count drops | **A function or relation over an infinite type (`Nat`) isn't part of the state's identity: different states are silently merged.** Index by declared finite types (a `type slot`, given by the instance). Compare state counts after any change to a model |
| `could not extract executable choices for a nondeterministic pick` | `let x :| p` needs its candidates from a relation in `p`; a type class's predicate (`next` of `TotalOrderWithMinimum`) doesn't work. Pass a successor function in the theory instead |
| `failed to synthesize Decidable` for a property | Unbounded `∀` over `Nat` can't be decided: use `∀ i, i < n → ...`, or ghost state (a flag updated by the actions) |
| An action with a `Nat` parameter can't be explored | Action parameters must be finite types |
| `Fin n` instance missing | Use a concrete `n` |
| The initial states explode | Give every field a value in `after_init` (an unassigned one is every value) |
| Only one violation is reported, and it hides another | Model checking stops at the first violation, breadth-first, so the shortest counterexample wins: one `focus` per property, and an instance that excludes the shortcut (`maxPrefs := 0` in `Multi.lean`) |
| `#guard_msgs` on a counterexample keeps changing | Counterexamples print whole states. Assert the violation with `#guard_msgs (drop error) in #model_check ...`, then print it with a second run under `set_option veil.violationIsError false in` |
| `veil.printCounterexamples false` doesn't shorten model checking output | It only applies to `#check_invariants` |
| Each `#model_check` takes a minute or two | The default mode compiles a checker per instance; `interpreted` skips that but is far slower on big instances |
| Using the model from Lean code | `letI : Veil.LogSwitch := ⟨false⟩` before `enumerableTransitionSystem ... theory`; `.initStates`, `(.tr theory s).successes`; read fields by casting: a function `A → B` is `Std.ExtTreeMap A B`, of two arguments `Std.ExtTreeMap (A × B) _`, a relation `Std.ExtTreeSet`; match labels by `reprStr` |

## Veil: proofs (`#check_invariants`)

| Symptom | Cause, and what to do |
|---|---|
| Expected violations show as ❌ rows | It checks every `safety` and `invariant` together; guard them with `focus` (above). `veil.violationIsError false` keeps the build going |
| `cannot translate Type`, or the SMT encoding fails | `Option`, `List` and `max` don't translate: use relations (`stdoutTo : req → Bool` for an `Option req`), enums, numbered logs over a finite type, and `if` |
| `generalize failed` while generating conditions | A conditional relation update inside a procedure; write it as one `decide` formula |
| ❓ with `TIMEOUT` | Arithmetic under quantifiers (`i - 1`); restate it with ghost state. A row that can time out makes a pinned table flaky: don't pin that model, check the rows in its harness (`ModuleCache.lean`) |
| "Trusting SMT solver for N goals" stays | `veil.smt.trust false` must be set before `veil module`; `set_option ... in` on `#check_invariants` has no effect |
| A proof fails although the property holds | It isn't inductive: add `invariant [...]` clauses (who holds a lock, at most one of something, which phases imply which) |

## Building

- `lake build` (everything) or `lake build JankSpecs.X`; `lake env lean` fails
  (a missing cvc5 native symbol).
- Don't run two `lake build`s in `specs/` at once.
- The `ld64.lld: warning: ... has version 26.0.0` lines are noise.

## Lean from jank (`lean-sys`)

| Symptom | Cause, and what to do |
|---|---|
| `Library not loaded: @rpath/libLake_shared.dylib` (or `libleanshared_2`) | Lean's shared libraries have no rpath: load each after the ones it depends on (Lean's runtime, then `Lake_shared`, then packages, dependencies first) |
| A project's own library loads before lean-sys's | lein-jank puts `:linked-libraries` from `project.clj` before the dependencies' (and they're deprecated): link it from the project's own `jank-build.bb`, whose directives come last |
| `no symbol initialize_...` | Lean 4.35 initializers are `initialize_<package>_<Module_Name>(uint8_t builtin)`, with the Lake package's name |
| A crash calling Lean from a future | Register the thread first (`lean_initialize_thread`); lean-sys's helpers do it |
| The build script can't run Lake | The sandbox can't reach `~/.elan`: build the Lean side before `lein run` |
| `Could not locate jank/build/util` in a dependency's build script | A lein-jank issue: it gives a dependency's build script an empty classpath (no `jank-build`) when the dependency comes from a profile's `:dependencies`. To be fixed in lein-jank, not worked around in the packages |

## jank, when writing test programs

| Symptom | What to do |
|---|---|
| No `flush`, no `Thread/sleep` | `(cpp/raw "#include <cstdio>")` and `(cpp/fflush cpp/stdout)`; `(cpp/raw "#include <unistd.h>")` and `(cpp/usleep us)` |
| Output missing when jank crashed or was killed | stdio's buffer is lost when stdout is a pipe: flush before anything that can crash or hang |
| Exit code 139 after a program that printed an exception | RESULTS S1: printing a stack trace makes the process crash at exit; don't trust that exit code, or end with `(cpp/fflush cpp/stdout)` and `(cpp/_exit 0)` |
| `(catch jank.runtime.object_ref e)` doesn't catch | The runtime throws C++ exceptions: `(catch :default _ ...)`, or `(catch std.exception e (.what e))` for the message |
| `(deref x ms v)` returns `nil` at once | RESULTS S3, a stub: sleep, then ask `realized?` |
| `(let [...] "text")` or a `loop` returning a literal string doesn't compile | RESULTS S2: return `(str "text")` or a keyword |
| A deadlocked thread keeps the process alive | End with `(cpp/_exit 0)` |
| The same program on jank and Clojure | A `.cljc` with `#?(:jank ... :clj ...)`: `jank run --module-path . x.cljc`, `clojure -Sdeps '{:paths ["."]}' -M x.cljc` |
| Clojure fails compiling a big generated form jank takes | A method is too large: generate one top-level form per run |
| Reading jank's internals (binding frames, thread ids) | `cpp/raw` a C++ function over `jank::runtime::__rt_ctx` (`repro/binding-frames-never-freed.jank`) |
