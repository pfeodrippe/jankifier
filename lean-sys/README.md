# lean-sys

Calling [Lean 4](https://lean-lang.org) from jank: Lean's runtime and frontend
(`libleanshared`), its C API (`lean/lean.h`), a C++ layer
(`include/lean_sys/`), and two namespaces on top of it:

- `lean-sys.session` runs Lean in-process: it imports modules, elaborates
  commands, and calls Lean functions on jank values, reading their results as
  jank values by their Lean types.
- `lean-sys.core` calls functions that a Lean library exports
  (`@[export c_name]`).

Built like the `-sys` packages of
[jank-lang/commons](https://github.com/jank-lang/commons) (`flecs-sys`, ...):
`jank-build.bb` gives jank the include and library flags.

## Usage

Add this project to your Leiningen `:dependencies` vector:

```clojure
[jankifier/lean-sys "0.1.0-SNAPSHOT"]
```

## Lean in-process (`lean-sys.session`)

```clojure
(require '[lean-sys.session :as lean])

(def s (lean/session {:imports []}))   ; Lean itself; `:lake-project` for a Lake project's modules

(lean/elab! s "
structure Account where
  owner : String
  balance : Int
inductive Op where
  | deposit (n : Nat)
  | withdraw (n : Nat)
def apply (a : Account) : Op → Account
  | .deposit n => { a with balance := a.balance + n }
  | .withdraw n => { a with balance := a.balance - n }")

(lean/call s "apply" {:owner "ana" :balance 10} {:lean/ctor :withdraw :n 25})
;=> {:owner "ana", :balance -15}
(lean/evaluate s "(List.range 5).map (· * 2)")
;=> [0 2 4 6 8]
(lean/elab s "def x : Nat := \"no\"")
;=> [{:severity :error, :line 1, :column 15, :text "Type mismatch ..."}]
```

A session is a Lean environment, as in a file: `elab` elaborates commands into
it (namespaces, options and sections stay open from one call to the next) and
returns their messages as data; `elab!` throws when there are errors. `call`
calls a constant on jank values; `function` gives a jank function calling it;
`evaluate` evaluates a term. An `IO` action is run, and a `CommandElabM`
action is run in the session's command state. Called with fewer arguments
than its parameters, a function gives back the partially applied function,
as an opaque Lean value.

```clojure
(lean/compile! s "apply")          ; native code from now on, same results
(lean/prove-theorem s "∀ n : Nat, n + 0 = n" "by simp")
;=> {:proved? true, :name _lean_sys_theorem_1, :axioms [propext Quot.sound], :messages []}
(lean/axioms s "Nat.add_comm")
;=> []
```

- `compile!` compiles a constant to native code: Lean's compiler emits C for
  it and for the session's definitions it uses, `leanc` compiles it, `cc`
  links it into a shared library (in `$TMPDIR/lean-sys`, reused for the same
  code), and the library is loaded into the process. Calls then run the
  native code: for Veil's model checker on the nREPL model, 0.05 s instead of
  1.4 s, after 2.5 s of compiling.
- `prove-theorem` elaborates a theorem (a proof term, or `by` and tactics) and
  reports whether Lean's kernel accepted it without `sorry`, with the axioms
  it depends on (`axioms`): `sorryAx` for a `sorry`, an axiom of its own for
  `native_decide`, otherwise only Lean's own.

Values are converted by their Lean types:

| Lean | jank |
|---|---|
| `Nat`, `Int`, `UInt8`...`UInt64`, `Fin n` | integer (a big integer when needed) |
| `Float`, `Float32` | double |
| `Bool`, `String`, `Char` | boolean, string, character |
| `Lean.Name` | symbol |
| `Unit`, proofs, types | nil |
| `Option α` | nil or the value |
| `List α`, `Array α` | vector |
| `α × β` | vector of two |
| `Std.TreeMap`, `Std.ExtTreeMap` | map |
| `Std.TreeSet`, `Std.ExtTreeSet` | set |
| `Lean.Json` | the JSON value, objects as maps with keyword keys |
| an enum (constructors without fields) | keyword: `:green` |
| a structure | map of its fields: `{:owner "ana" ...}` |
| another inductive type | `{:lean/ctor :withdraw :n 25}`, or a keyword for a constructor without fields |
| anything else (functions, `IO.Ref`...) | an opaque Lean value, passed back as is |

### How it works

- Lean's frontend is a Lean library in `libleanshared`. The C++ layer
  (`include/lean_sys/lean_sys.hpp`) calls its compiled functions by their C
  symbols (`Lean.importModules`, `Lean.Elab.IO.processCommands`,
  `Lean.Environment.evalConst`...), with their signatures from Lean 4.35's IR.
- Converting a value needs its runtime layout: which constructor fields are
  objects and which are scalars, at which offsets. Lean's compiler knows it, so
  lean-sys elaborates a few definitions into each session
  (`include/lean_sys/source.hpp`) that describe a type's layout from the
  compiler's own (`getCtorLayout`, `hasTrivialStructure?`). The C++ layer reads
  and builds values from those descriptions, into a `Sink` and from a `Source`;
  `include/lean_sys/jank.hpp` implements them with jank's runtime.
- Lean runs on a thread of its own, with a 256 MB stack (elaboration recurses
  deeply); calls from any jank thread wait for it.
- A Lean value jank holds (an opaque one, a session) is released when jank's
  GC collects its box: the box's finalizer queues the release, which Lean's
  thread does before its next job.
- With `:lake-project`, the project's libraries and its packages' are loaded
  (`dlopen`, each after those it depends on), so that their native code runs.
  Without them, Lean interprets the modules' code, which is much slower.

## Calling exported functions (`lean-sys.core`)

1. On the Lean side, mark the functions to call with `@[export c_name]`, and
   build the library as a shared library:

   ```lean
   @[export lean_sys_example_greet]
   def greet (name : String) : String := s!"Hello, {name}, from Lean!"
   ```

   ```sh
   lake build        # with `defaultFacets := #[LeanLib.sharedFacet]` in the lakefile
   ```

   Lake writes `.lake/build/lib/lib<package>_<Lib>.dylib`. A single module can
   be built alone with `lake build +Module.Name:dynlib`
   (`.lake/build/lib/lean/<package>_<Module_Name>.dylib`).

2. On the jank side, depend on lean-sys, and link your library from your
   project's own `jank-build.bb` (a project's directives come after its dependencies',
   so your library loads after Lean's runtime):

   ```clojure
   (util/link-dir "<your Lake package>/.lake/build/lib")
   (util/link-library "leanSysExample_LeanSysExample")
   ```

   Then, once, run the module's initializer, and call:

   ```clojure
   (require '[lean-sys.core :as lean])
   (lean/initialize-module! "leanSysExample" "LeanSysExample")   ; package, module
   (lean/call-string "lean_sys_example_greet" "jank")
   ;=> "Hello, jank, from Lean 4.35.0!"
   ```

   `call-string` and `call-u64` call `String → String` and `UInt64 → UInt64`
   functions by symbol. Anything else can be declared in `cpp/raw` with
   `lean.h`'s types and called directly:

   ```clojure
   (cpp/raw "extern \"C\" uint64_t lean_sys_example_sum_below(uint64_t);")
   (cpp/lean_sys_example_sum_below 1000)
   ;=> 499500
   ```

## Tests

```sh
cd lean-sys && lein test       # conversions, errors, IO, compile!, theorems, releasing values
```

## Example

[example/](example) has a Lake package with three exported functions and a jank
program calling them, also from futures:

```sh
cd lean-sys && lein install          # lean-sys into ~/.m2
cd example/lean && lake build        # the example's Lean library
cd .. && lein run
```

[veil](../veil) is built on `lean-sys.session`: it runs Veil's model checker
and proofs in-process, with their results as jank data. In this repository,
`specs/` uses both namespaces (`specs/README.md`, "Calling the models from
jank").

## Notes

- The Lean version is pinned in `lean-toolchain` (v4.35.0): a Lean shared
  library only works with the runtime of the version it was built with, so
  build yours with the same toolchain. lean-sys finds it under
  `~/.elan/toolchains/`. The C++ layer calls Lean's compiled functions with
  their 4.35 signatures; another version needs them checked again.
- Lean's shared libraries have no rpath, so they must be loaded in order:
  each finds the libraries it depends on only if they're already loaded.
  lean-sys loads Lean's runtime and `Lake_shared` (which a library built by
  Lake depends on) in order; a library that imports other Lake packages needs
  theirs loaded first, dependencies before what uses them (see
  `specs/jank-build.bb`). `lean-sys.session/load-libraries!` finds the order
  by retrying.
- Initializers are named `initialize_<package>_<Module_Name>` (Lean 4.35)
  and take one argument (`builtin`); each also starts Lean's runtime, if it
  isn't started. lean-sys doesn't mark the end of initialization, so modules
  can be initialized and imported later too.
- A thread that didn't set the runtime up must register with it
  before calling Lean; the helpers do that on each thread's first call.
- An exported function owns its arguments and returns an object
  its caller owns (`lean_object*`, reference counted). The helpers copy
  results into jank values and release them; do the same when calling
  directly.
- A session keeps the info trees of everything elaborated into it (some
  elaborators, as Veil's proofs, need them), so a long session grows.
- Errors come back as `ex-info`. In jank 0.1, `(catch :default e ...)` binds
  `nil`; use `(catch jank.runtime.object_ref e ...)` to get the `ex-info`.
- The build sandbox can't run Lake (it can't reach `~/.elan`): build the
  Lean side before `lein run`.
