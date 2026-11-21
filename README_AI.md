# Jankifier: reference

This file is written and kept up to date by an AI assistant, as a reference for
the project and how to use it. [README.md](README.md) is the author's own.

Jankifier is a small library for [jank](https://jank-lang.org) which lets you
write more jank and less C++:

- `jankifier.core`: macros which define C++ structs and functions from jank
  (`defcstruct`, `defcstructs`, `defcfn`), and which let C++ interop use their
  jank names (`cpp-type`, `cpp-cast`, `cpp-fn`).
- `jankifier.nrepl`: a development-only plugin for jank's nREPL server, which
  adds the ops CIDER (and other cider-nrepl clients) use for completion, docs
  and running tests.
- `jankifier.cpp`: helpers which turn jank data into C++ source, used by the
  macros.

It's also shipped with [clj-kondo](https://github.com/clj-kondo/clj-kondo)
hooks for its macros.

## Contents

- [Installing](#installing)
- [A first example](#a-first-example)
- [Types](#types)
- [defcstruct](#defcstruct)
- [defcstructs](#defcstructs)
- [defcfn](#defcfn)
- [cpp-type, cpp-cast and cpp-fn](#cpp-type-cpp-cast-and-cpp-fn)
- [REPL support: jankifier.nrepl](#repl-support-jankifiernrepl)
- [clj-kondo](#clj-kondo)
- [Developing jankifier](#developing-jankifier)
- [Limitations](#limitations)

## Installing

Jankifier is a source library: jank compiles its `.jank` files along with your
project. It has no dependencies other than jank.

It will be published to Clojars as `io.github.pfeodrippe/jankifier`. Until
then, add it as a git submodule (or any checkout) and put its `src` in your
project's `:source-paths`:

```clojure
(defproject my-app "0.1.0"
  :plugins [[org.jank-lang/lein-jank "2026.10-1"]]
  :middleware [leiningen.jank/middleware]
  :source-paths ["src" "lib/jankifier/src"])
```

On macOS, if `xcode-select -p` points to `/Applications/Xcode.app`, builds
which run in lein-jank's sandbox (such as `-sys` packages using CMake) need
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

## A first example

```clojure
(ns my.app
  (:require [jankifier.core :refer [cpp-fn defcfn defcstruct]]))

(defcstruct Vec2
  "A 2D vector."
  [[:x :f64]
   [:y {:default 0.0} :f64]
   (fn length-squared :f64 [] (+ (* x x) (* y y)))])

(defcfn move :void
  "Moves p by v."
  [[p [:& Vec2]]
   [v [:& [:const Vec2]]]]
  (cpp/= (.-x p) (+ (.-x p) (.-x v)))
  (cpp/= (.-y p) (+ (.-y p) (.-y v))))

(defn -main [& args]
  (let [p (Vec2 {:x 3.0 :y 4.0})]
    (move p (Vec2 {:x 1.0}))
    (println (.length_squared p))))   ; 32.0
```

`Vec2` is the real C++ struct `my::app::Vec2`, and `move` is the real C++
function `my::app::move(Vec2 &, Vec2 const &)`, whose body is jank. C++ code
can use both, e.g. a C++ API taking a callback can be given `(cpp-fn move)`.

[README.md](README.md#example) has a bigger example, the same
[flecs](https://github.com/SanderMertens/flecs) program in C++, in jank with
`cpp/raw`, and in jank with jankifier.

## Types

The macros take types as data:

| Type | C++ |
|---|---|
| `:void` `:bool` `:char` | `void` `bool` `char` |
| `:i8` `:i16` `:i32` `:i64` | `int8_t` … `int64_t` |
| `:u8` `:u16` `:u32` `:u64` | `uint8_t` … `uint64_t` |
| `:f32` `:f64` | `float` `double` |
| `:isize` `:usize` | `ptrdiff_t` `size_t` |
| `Vec2`, a symbol naming a `defcstruct` | its C++ name, e.g. `my::app::Vec2` |
| a string or another symbol, e.g. `"ecs_iter_t"` | that C++ type, as written |
| `[:* t]` | a pointer to `t` |
| `[:& t]` | a reference to `t` |
| `[:const t]` | `t const` |

`cpp-type` and `cpp-cast` also take template instantiations, see below.

Values cross between C++ and jank by value for keyword types, which jank
converts. Structs and other named C++ types cross by pointer or reference
(`[:* T]`, `[:& T]`) and arrive in jank as pointers, so `(.-x p)` reads a field
and `(cpp/= (.-x p) 1.0)` writes it.

Names are turned into C++ ones by replacing `-` with `_`, so `max-mp` is
`max_mp`. Names which aren't valid C++ identifiers (`alive?`) or are C++
keywords (`new`) are errors.

## defcstruct

```clojure
(defcstruct Name doc? {attrs}? [members])
```

Defines a C++ struct in the C++ namespace of the jank namespace (`my.app` →
`my::app`), and the macro `Name`, which builds one from a literal map of its
fields:

```clojure
(defcstruct Vec2
  "A 2D vector."
  {:layout :packed}
  [[:x :f64]
   [:y {:doc "Vertical component" :default 0.0} :f64]
   [:dims {:const 2} :i32]
   [:created {:var 0} :i32]
   (fn scaled :f64 "Squared length times k." [[k :f64]] (* k (+ (* x x) (* y y))))])

(Vec2 {:x 3.0 :y 4.0})   ; my::app::Vec2{3.0, 4.0}
(Vec2 [3.0 4.0])         ; the same, with the values in field order
(Vec2 {:x 3.0})          ; :y takes its default
(Vec2 [3.0])             ; the same: trailing fields with defaults can be left out
(Vec2)                   ; only if every field has a default
```

Leaving out a field without a default, giving an unknown one, or giving more
values than there are fields, is an error when the call expands. Integer
values work for float fields (`(Vec2 [4 1])`).

### Structs as jank maps

Each struct also gets a `jank::runtime::convert` specialization, which jank
uses when a struct value is given where a jank value is expected. The struct
becomes a map of its instance fields with keyword or struct types, keyed by
their names, so at runtime:

```clojure
(let [v (Vec2 [3 4])]
  (:x v)          ; 3.0
  (get v :y)      ; 4.0
  (keys v)        ; (:x :y)
  (= {:x 3.0 :y 4.0} (into {} v)))   ; true

(Vec2 [3 4])      ; in a REPL: {:x 3.0, :y 4.0}
```

Nested struct fields become nested maps. The map is a copy: changing it
doesn't change the struct, so write fields with `(cpp/= (.-x v) 1.0)`.
Static members and fields with other C++ types (pointers, strings with a C++
type) aren't in the map.

It works the other way too: a jank map given where C++ expects the struct,
e.g. to a C++ function taking a `Vec2`, becomes the struct. Fields left out
take their default value, or zero.

`(:x v)` and `(get v :x)` don't build the map: jank compiles them to a call
to `jank::runtime::get`, and each struct gets `get` overloads which C++ picks
by the static type of `v`, a struct or a pointer to one (so `(:x p)` works on
`defcfn` pointer arguments too). They read the field and box it, which costs
about the same as `(:x m)` on a jank map, around 5× a `(.-x v)` read, which
stays unboxed. Use `.-x` in hot code, and to write fields: the overloads
return `object_ref const`, so `(cpp/= (:x p) 1.0)` is a compile error rather
than a write to a temporary which silently does nothing (as it is for jank
maps).

Attributes:

- `:layout` is `:normal` (the default), `:packed` (`__attribute__((packed))`)
  or `:extern`, which currently generates the same struct as `:normal`.

Members, all in one vector:

- `[name type]` or `[name {props} type]`: an instance field. Props are
  `:default` (its default value, also a C++ default member initializer) and
  `:doc` (a C++ comment).
- `[name {:const value} type]`: a `static constexpr` member.
- `[name {:var value} type]`: a `static inline` member.
- `(fn name ret doc? [[arg type] ...] body...)`: a method, written in jank.
  - Its body sees the struct's instance fields with keyword types as locals,
    as copies, and its arguments.
  - Fields typed as another struct or as raw C++ aren't visible, since jank
    can't convert them.
  - `ret` is a keyword type or `:void`.
  - It becomes the private jank function `Name-method` (`Vec2-scaled`), which
    the C++ method calls, so `(.scaled v 2.0)` works from jank and C++.
  - Its body can't use the struct's own type, since it's defined together with
    the struct.

Default, `:const` and `:var` values are numbers, booleans, strings or nil.

The var `Name` keeps the struct's description in its metadata, under
`:jankifier/struct`, which is how other macros resolve `Name` to its C++ name.

## defcstructs

```clojure
(defcstructs [[Health [[:hp :i32]
                       (fn dead :bool [] (<= hp 0))]]
              [Mana [[:mp :i32] [:max-mp :i32]]]])

(def specs '[[Armor [[:defense :i32]]]])
(defcstructs specs)
```

Defines several structs, as `defcstruct` does, from a vector of
`[Name & declaration]`, or from a symbol naming a var which holds one, so
structs can be described as plain data.

## defcfn

```clojure
(defcfn name ret doc? [[arg type] ...] body...)
```

Defines a C++ function in the C++ namespace of the jank namespace, whose body
is jank:

```clojure
(defcfn move :void
  "Moves p by v."
  [[p [:& Vec2]]
   [v [:& [:const Vec2]]]]
  (cpp/= (.-x p) (+ (.-x p) (.-x v)))
  (cpp/= (.-y p) (+ (.-y p) (.-y v))))
```

- The C++ function is `my::app::move(Vec2 &p, Vec2 const &v)`. It converts
  its arguments and calls the private jank function `move*`, then converts the
  result back to `ret`, a keyword type or `:void`.
- `(move p v)` calls it from jank, and `(cpp-fn move)` (or
  `cpp/my.app.move`) is the C++ function, e.g. for a C++ API which takes a
  callback.
- The var `move` keeps the function's description in its metadata, under
  `:jankifier/fn`.

## cpp-type, cpp-cast and cpp-fn

jank's C++ interop names things by their C++ names (`cpp/my.app.Vec2`, or
`#cpp (flecs.component my.app.Vec2)` for a template). These macros take the
jank names and the types above instead, so structs can be named as in jank.

```clojure
;; flecs::system_builder<Position, Velocity const>(world, "Move").each(move)
(-> ((cpp-type (flecs.system_builder Position [:const Velocity])) w-ptr "Move")
    (.each (cpp-fn move)))

;; static_cast<Position *>(ecs_get_mut_id(world, entity, id))
(->> (cpp/ecs_get_mut_id w-ptr (.id bob) position-comp)
     (cpp-cast [:* Position])
     cpp/*)
```

- `(cpp-type t)` is the C++ type `t` as a `#cpp` value. Call it to construct
  one. Besides the types above, `t` can be a template instantiation
  `(template arg ...)`, whose template is a C++ name and whose arguments are
  types or integers, e.g. `(std.array Vec2 4)`.
- `(cpp-cast t x)` is `(cpp/cast t x)` with `t` written as for `cpp-type`.
  It exists because jank doesn't expand macros where it expects a type as an
  argument, so `(cpp/cast (cpp-type t) x)` can't work. It takes its value last,
  so it fits `->>`.
- `(cpp-fn name)` is the C++ function a `defcfn` defined.
- `jankifier.core/dsl-form` is the function which turns types into jank's C++
  DSL syntax, e.g. `[:* [:const Vec2]]` into `(:* (:const my.app.Vec2))`.

Calling a C++ member function template with explicit template arguments, like
`world.system<Position, Velocity const>("Move")`, isn't possible from jank
today. As above, construct what it returns instead.

## REPL support: jankifier.nrepl

jank's built-in nREPL server only has the core ops (`clone`, `describe`,
`eval`, `load-file`, `lookup` and `completions`), so CIDER can't complete
`alias/` prefixes, show docs or run tests. Requiring `jankifier.nrepl` in a
running REPL adds these ops, under their bare names and their `cider/` names,
which newer CIDER versions use:

| Op | What it does |
|---|---|
| `complete` | Completion, including `alias/` and `full.ns/` prefixes, namespace names and special forms like `cpp/raw`. |
| `info`, `eldoc` | Docs, arglists, and source locations (jank's own namespaces point at its installed sources). |
| `lookup` | Like jank's, but also for qualified symbols. |
| `test`, `test-var-query`, `test-all`, `retest` | Run `clojure.test` tests, with fixtures, fail-fast, selectors, test output, and per-namespace and per-var times. `test-var-query` is what Calva uses. |
| `test-stacktrace` | The error of a failing test, with jank's stack frames. |

They're added to `describe` too.

It also makes `eval` and `load-file` send their final `done` in a message of
its own, as Clojure's nREPL does. jank's server sends it together with
`eval-error`, and CIDER 2.1 then fails while handling the error (in
`nrepl--mark-id-completed`, run from another buffer), so an evaluation which
throws never finishes: its progress spinner stays, one more for every failing
evaluation.

It's a development tool, which uses jank's
internal `jank.nrepl.server.*` namespaces, so only require it in a REPL, never
from code which ends up in a compiled program.

### With CIDER

CIDER reads the server's ops once, when it connects, so the plugin has to be
loaded right after connecting, and the ops read again. This hook does both,
for jank servers only:

```elisp
(defun my/jank-load-cider-ops ()
  (when (nrepl-dict-get nrepl-versions "jank")
    (let ((resp (cider-nrepl-sync-request:eval "(require 'jankifier.nrepl)")))
      (if (nrepl-dict-get resp "err")
          (message "jankifier.nrepl not loaded: %s" (nrepl-dict-get resp "err"))
        (nrepl--init-capabilities (current-buffer))))))
(add-hook 'cider-connected-hook #'my/jank-load-cider-ops)
```

jankifier has to be on the REPL's module path. Tested with CIDER 2.1:
completion, docs and source locations (what `M-.` uses), eldoc, and running a
namespace's tests (`C-c C-t n`) with the test report.

Recent `clojure-mode` versions (5.24 was tested) have a `jank-mode` for `.jank`
files, which CIDER works in.

### Other clients

Calva uses the same cider-nrepl ops, but it's untested: like CIDER, it reads
the ops when it connects, so `(require 'jankifier.nrepl)` has to run before
that, or Calva has to reconnect after it.

## clj-kondo

The jar ships hooks for `defcstruct`, `defcstructs`, `defcfn`, `cpp-type`,
`cpp-cast` and `cpp-fn` under clj-kondo's convention,
`resources/clj-kondo.exports/io.github.pfeodrippe/jankifier/`. Import them into
your project (which needs a `.clj-kondo` directory) with clj-kondo's usual
command, pointing it at the jar or at jankifier's `resources` directory:

```sh
# From Clojars, through your classpath.
clj-kondo --lint "$(lein classpath)" --dependencies --copy-configs --skip-lint

# From a git submodule, whose resources aren't on your classpath.
clj-kondo --lint lib/jankifier/resources --dependencies --copy-configs --skip-lint
```

Either copies them to `.clj-kondo/imports/io.github.pfeodrippe/jankifier/`,
where clj-kondo loads them from.

clj-kondo doesn't lint `.jank` files on its own, so give it the language:

```sh
clj-kondo --lang clj --filename src/my/app.jank --lint - < src/my/app.jank
```

With the hooks, clj-kondo knows what the macros define and which locals their
bodies see, so it reports e.g. unknown struct types, a struct-typed field used
in a method, unused arguments, typos, and calling a struct's macro with the
wrong number of arguments.

Not covered:

- `(defcstructs some-var)`: clj-kondo can't evaluate the var, so those
  structs show as unresolved.
- In `cpp-type` and `cpp-cast`, a bare C++ type without a dot, like `int`, is
  reported as unresolved. Use keyword types (`:i32`) there.
- jank-wide things which aren't about jankifier: `cpp/...` forms are an
  unresolved namespace, `(:include ...)` is an unknown ns option, and jank's
  `format` uses `{}` placeholders rather than `%`.

## Developing jankifier

```
src/jankifier/core.jank       the macros
src/jankifier/cpp.jank        C++ source helpers
src/jankifier/nrepl.jank      the nREPL plugin
test/jankifier/*_test.jank    tests
resources/clj-kondo.exports/  the exported clj-kondo hooks
.clj-kondo/config.edn         points at them, to lint jankifier itself
```

Run the tests with:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools lein test
```

The `jankifier.nrepl` tests run its ops directly, without a server. They build
a namespace with a passing, a failing and an erroring test at runtime, so
`lein test` doesn't run those.

`lein test` overwrites `.nrepl-port` with a port nothing listens on. If a REPL
is connected through it, write the REPL's port back afterwards.

## Limitations

- The C++ is generated into `cpp/raw` forms, so it works in AOT compiled
  programs, but, as with any `cpp/raw`, a struct or function can only be used
  by later top level forms, and can't be redefined in a running process.
- A macro error ends up as a C++ compile error about generated code.
- `defcfn` and method results are keyword types or `:void`, not pointers or
  structs.
- Pointers and references must be to a struct or a named C++ type, not to a
  keyword type.
- Calls between C++ and jank, and structs as maps, use jank runtime internals
  (`find_var`, `convert`, `opaque_box`, `persistent_array_map`), which may change between jank releases.
- jank issues found while building this, which jankifier works around, are
  listed in [todo.md](todo.md).
