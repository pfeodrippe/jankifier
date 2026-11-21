# lean-sys

Calling [Lean 4](https://lean-lang.org) from jank: Lean's runtime
(`libleanshared`), its C API (`lean/lean.h`), and a few helpers
(`lean-sys.core`). Built like the `-sys` packages of
[jank-lang/commons](https://github.com/jank-lang/commons) (`flecs-sys`, ...):
`jank-build.bb` gives jank the include and library flags.

## Usage

Add this project to your Leiningen `:dependencies` vector:

```clojure
[jankifier/lean-sys "0.1.0-SNAPSHOT"]
```

## How it works

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

## Example

[example/](example) has a Lake package with three exported functions and a jank
program calling them, also from futures:

```sh
cd lean-sys && lein install          # lean-sys into ~/.m2, for the example
cd example/lean && lake build        # the example's Lean library
cd .. && lein run
```

In this repository, `specs/` also uses it: its lein project calls a Veil model
of `swap!` from jank and uses it as a test oracle for atoms (`specs/README.md`,
"Calling the models from jank").

## Notes

- The Lean version is pinned in `lean-toolchain` (v4.35.0): a Lean shared
  library only works with the runtime of the version it was built with, so
  build yours with the same toolchain. lean-sys finds it under
  `~/.elan/toolchains/`.
- Lean's shared libraries have no rpath, so they must be loaded in order:
  each finds the libraries it depends on only if they're already loaded.
  lean-sys loads Lean's runtime and `Lake_shared` (which a library built by
  Lake depends on) in order; a library that imports other Lake packages needs
  theirs loaded first, dependencies before what uses them (see
  `specs/jank-build.bb`).
- Initializers are named `initialize_<package>_<Module_Name>` (Lean 4.35)
  and take one argument (`builtin`); the first one also starts Lean's runtime.
  lean-sys doesn't mark the end of initialization, so modules can be
  initialized later too.
- A thread that didn't set the runtime up must register with it
  before calling Lean; the helpers do that on each thread's first call.
- An exported function owns its arguments and returns an object
  its caller owns (`lean_object*`, reference counted). The helpers copy
  results into jank values and release them; do the same when calling
  directly.
- The build sandbox can't run Lake (it can't reach `~/.elan`): build the
  Lean side before `lein run`.
