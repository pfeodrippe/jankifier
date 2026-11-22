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
- A fix of a finding is modelled before it's written in jank: a value of the
  model's `enum fix_t`, and `immutable relation fixed : fix_t → Bool` in its
  theory, which the changed actions read. Each finding's property gets a
  `#model_check` with its fix (no violation expected), and, where the model
  has proofs, a property `fixed x → ...` in the pinned table. Every theory
  has `fixed`: in Lean files `fixed := fun _ => false` is jank as it is; from
  jank, `:fixed (h/fixed-term [])`. Adding an enum adds a type argument to
  `Theory`, `State`, `Label` and `enumerableTransitionSystem` in the
  checkers.
- Proofs are kernel-checked (`set_option veil.smt.trust false` at the top of
  the file), and the `#check_invariants` table is pinned with `#guard_msgs`
  (unless a row can time out, see below), so the build fails when a proof
  breaks.
- Every finding has a reproduction in [repro/](repro/README.md): a `.cljc`
  that runs on jank and Clojure when possible; nondeterministic ones run many
  times and print how often the bug showed up.
- jank runs in scratch directories (`scratch-dir` in
  `src/jank_specs/harness.jank`, under the ignored `conformance/out/`),
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
| A crash right after calling a compiled Lean function from C++ | Signatures come from Lean's IR (`IR.findEnvDecl`): erased parameters (types, proofs, the `IO` world) are still passed, as `lean_box(0)`; a `BaseIO` function returns its value, an `IO` one an ok/error object; `@&` parameters are borrowed |
| Where a Lean value's fields are, when reading it from C++ | Constructor layouts come from the compiler (`Lean.Compiler.LCNF.getCtorLayout`): objects first, then usize, then scalars by size; a structure with one relevant field is that field (`hasTrivialStructure?`), so `Fin n` is a `Nat` and `Std.ExtTreeMap` is its tree |
| A library compiled from Lean's emitted C exports nothing | `LEAN_EXPORT` marks symbols visible only with `-DLEAN_EXPORTING`; compile with `leanc -c` (the toolchain's `clang` alone has no system headers) and link with `cc -shared -undefined dynamic_lookup`, not `leanc`, which would link a second copy of Lean's runtime |
| A value with one constructor and one field reads as the field | Lean represents it as the field; lean-sys keeps the constructor and field of an inductive type (a Veil label type with one action) and the field's name of a structure defined in the session (a Veil state with one field), not a library structure's (`Fin`) |
| `lein test` (or a program) ends with SIGSEGV and no output | RESULTS S1: jank crashes at exit after printing an exception, and the buffered output is lost; fix the failing test, or run the tests in a REPL to see them |
| `native_decide` doesn't show `Lean.ofReduceBool` among a theorem's axioms | Lean 4.35 adds an axiom of its own, `<theorem>._native.native_decide.ax_1` |
| `(catch :default e ...)` gets `nil` | jank 0.1 binds nothing there; `(catch jank.runtime.object_ref e ...)` gets the `ex-info` (lean-sys turns its C++ errors into `ex-info`s) |

## Veil from jank (`veil`)

| Symptom | Cause, and what to do |
|---|---|
| `failed to synthesize ... EnumClass` in a term built outside the module | The module's enum instances are scoped to its namespace: elaborate the term inside `open Veil M in` |
| `unexpected token 'theory'` (or `'action'`) in Lean code elaborated after `import Veil` | Veil makes `theory` and `action` keywords (and `trace` in modules), even as structure fields: rename them |
| A counterexample to induction without a post-state | The primary (weakest-precondition) condition's counterexample has none; its `_tr` alternative's has one (`veil/prove` takes it from there) |
| `Unknown identifier veilInst.thread` in a quotation | The quotation's `let` binder is hygienic: use `mkIdent` for the binder too |
| `verification interrupted: specification owner was canceled` | Veil ties a module's proof run to the info tree of the command that prepared it: a session must keep earlier info trees alive (lean-sys does) |
| `... has already been declared` when a model or file is loaded again | Modules can't be redeclared in a session: veil loads it again under a name with a number |
| `#model_check` in a loaded file takes minutes | Veil's default mode also builds a compiled checker with Lake; `VEIL_ONLINE_ENV` (veil sets it) keeps it interpreted |
| A theory or instance term elaborated while another module is open doesn't type-check (`kind_t_IndT` against `veilInst.kind_t`) | Names resolve in the open module's namespace first; veil's elaborators make the checked module's namespace the current one |
| Exploring a model's states from jank, step by step, is slow | Each step converts the state between Lean and jank; `veil/reachable-states` searches in Lean and returns the states once |
| `#check_invariants`'s rows with no status | They are Veil's alternative formulations (`_tr`), tried only when the primary fails: count them with their primary (`veil/proved?`) |

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
| A sum or product of numbers is wrong, with no error | RESULTS S10: arithmetic on two integers that fit in 32 bits wraps at 32 bits. Do it in C++ (`cpp/raw`) when it can pass 2^31 |
| `(if c 1 true)` returns `1` | RESULTS S7: don't mix a number literal and a boolean literal in the branches of one `if` |
| `case` with a `true`, `false` or number default doesn't compile when the function is first called | RESULTS S8: give every value a branch, or make the default a non-literal |
| `(- (count x) n)` is huge, or compares wrongly | RESULTS S9: `count`'s arithmetic is unsigned; compare before subtracting (`h/tail`) |
| `(first (sort []))` crashes | RESULTS S5: check `seq` before sorting what can be empty |
| An optional regex group is `""` | RESULTS S6: jank gives `""` where Clojure gives `nil`; test with `seq` |
| Reading jank's internals (binding frames, thread ids) | `cpp/raw` a C++ function over `jank::runtime::__rt_ctx` (`repro/binding-frames-never-freed.jank`) |
