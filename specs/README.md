# Formal models of jank

Models of parts of jank 0.1, written in [Veil](https://github.com/verse-lab/veil)
(a Lean 4 framework for transition systems), each tested against the real
jank. See [PLAN.md](PLAN.md) for the approach, [RESULTS.md](RESULTS.md)
for what was found, and [AGENTS.md](AGENTS.md) for how the work is done here and
Veil's and jank's rough edges, with workarounds. New to this?
[TUTORIAL.md](TUTORIAL.md) walks through two small models (a real failure and
a proof) and the reasoning behind the nREPL one. Two jank files go through it
in a REPL, with Veil running in the REPL's process and the forms replaying its
counterexamples on jank: [tutorial.jank](tutorial.jank), the same document
with the models of its `.lean` files, and
[tutorial_jank_models.jank](tutorial_jank_models.jank), with the same models
written in jank, as data.

Phase 1 modelled three parts whose code had been read first. Phase 2 added
"blind" models (`JankSpecs/Blind/`): their properties were written from the
docstrings before their code was read, so that what the checker finds isn't
shaped by suspicions.

| Model | File | What it covers |
|---|---|---|
| Module loader and cache | `JankSpecs/ModuleCache.lean` | the module index, `find` (source or object file), `load_o`, `compile-module` |
| Dynamic bindings and futures | `JankSpecs/Concurrency/Bindings.lean` | binding frames per OS thread id, conveyance, `future-cancel` |
| Atoms | `JankSpecs/Concurrency/Atom.lean` | `swap!`, `reset!`, `compare-and-set!`, watches |
| Delay, promise, lazy seq | `JankSpecs/Concurrency/Once.lean` | run-once values under concurrent derefs |
| nREPL server | `JankSpecs/Nrepl.lean` | connections, eval and its output capture, `*1`, sessions, response ids, unknown ops |
| Vars (blind) | `JankSpecs/Blind/Vars.lean` | `alter-var-root`, `def`, `with-redefs`, `defonce`, interning vars, namespaces, keywords |
| `require` (blind) | `JankSpecs/Blind/Require.lean` | concurrent `require` of one lib |
| Multimethods (blind) | `JankSpecs/Blind/Multi.lean` | `derive`, `defmethod`, `prefer-method`, dispatch, next to Clojure's dispatch loop |
| Transients (blind) | `JankSpecs/Blind/Transients.lean` | which operations check that a transient is still active |
| Array maps (blind) | `JankSpecs/Blind/ArrayMap.lean` | the storage of maps up to 8 entries, shared between persistent maps and transients |

## Building

Needs elan (Lean `v4.35.0` is installed from `lean-toolchain`); Veil `v4.35.0`
is fetched by Lake.

```sh
cd specs
lake build          # every model, its checks, and the recorded jank runs
```

Building a model runs its checks:

- `#model_check`: explicit-state model checking of finite instances.
- `#check_invariants`: proofs for all instances (any number of threads,
  requests, modules...). The SMT solver's answers are reconstructed into Lean
  proofs that Lean's kernel checks (`set_option veil.smt.trust false`), and
  `#guard_msgs` pins the table of results, so the build fails if a proof
  breaks.
- `sat trace`: SMT reachability.

A property that is expected to hold fails the build if it's violated; each
expected violation is checked on its own (the `focus` theory value) and fails
the build if the model checker *doesn't* find it. Its counterexample is
printed to the build log.

## Testing against jank

The harnesses are jank code (`src/jank_specs/conformance/`), run from the
specs/ lein project: each runs scenarios on the installed `jank` and calls the
model's Lean checker, loaded into the same process (lean-sys and veil), on
what jank showed, as data. Nothing is generated and `lake build` isn't run.

```sh
cd specs
lein run -m jank-specs.conformance                   # every harness
lein run -m jank-specs.conformance bindings nrepl    # some of them
```

or, in the specs/ REPL, with each harness's options:

```clojure
(require '[jank-specs.conformance :as c])
(c/check "module-cache" {:random 20 :prove? true})   ; traces, replayed step by step
(c/check "bindings" {:random 150})
(c/check "atoms" {:runs 5000})                       ; outcome sets
(c/check "once" {:runs 3000})
(c/check "nrepl" {:random 20 :seed 3 :repeat 3})
(c/check "vars" {:runs 2000 :blocks 200})            ; outcome sets, and Clojure
(c/check "multi" {:programs 300})                    ; replay, and Clojure
(c/check "transients" {:programs 500})               ; table, and differential vs Clojure
(c/check "arraymap" {:programs 500})                 ; replay, entry by entry
```

The harnesses which run jank in fresh processes (all but atoms and once, which
run in this one) use `$JANK` when it's set, so they can test another jank,
such as the latest build published at
`https://cache.jank-lang.org/jank_0.1-1_aarch64.tar.gz` unpacked somewhere:

```sh
JANK=/path/to/jank lein run -m jank-specs.conformance bindings nrepl
```

Give that jank its own `XDG_CACHE_HOME` (a wrapper script): builds of the same
version share a cache key, and so a precompiled header, with the installed
jank. The reproductions' Python scripts read `$JANK` too.

Each returns `{:harness ... :ok? ... :results [...]}`, with the scratch
directory of its programs (`:work`, under `conformance/out/`, ignored by
git). Several harnesses also run their programs on Clojure (`clojure` on the
`PATH`), to tell what jank shares with Clojure from what's its own.

- **Traces** (module cache, bindings): every step of a jank run is an action of
  the model with what jank showed; the run conforms if the model can take the
  same steps and show the same things.
- **Program replay** (multimethods, array maps): a program's setup steps are
  actions of the model; each call's result (multimethods, over every order of
  the method table) or each map's entries (array maps, exactly) must be what
  the model gives.
- **Differential** (transients): random programs on jank and Clojure must
  print the same.
- **Outcome sets** (atoms, delay/promise/lazy seq, nREPL, vars, `require`): for
  concurrent programs only the end result can be observed; the model
  enumerates every result its interleavings allow, and every result jank shows
  must be one of them. For atoms and delay/promise/lazy seqs, the model's
  outcomes come from its states (`veil/system` and `veil/reachable-states`,
  compiled to native code) and jank's from running the programs in this
  process.

Each harness also runs the model checker's counterexamples (from
`veil/model-check`, as data) or a scenario built to reach them, so every
violation is reproduced on jank.

### Proposed fixes

Each model has a theory value `fixed`, which turns on proposed fixes of the
findings (the `fix_t` enum at the top of each model says what each one
changes), so that a fix is checked against the model before it's written in
C++: the model checker runs each finding's property with its fix, and where
the model has proofs, `fixed x → property` is proved for all instances.
[RESULTS.md](RESULTS.md#proposed-fixes) lists them, with what was checked.

The harnesses take the fixes too, and then check jank against the fixed
model:

```clojure
(c/check "nrepl" {:fixes [:n1 :n3 :n4n5 :n6]})
(c/check "module-cache" {:fixes [:m1 :m2 :m3 :m4 :m5]})
```

Until a fix is written in jank this fails, on the scenarios which show its
finding; once it's written, it's the regression test.

The `*Observed.lean` and `*Traces.lean` files of `JankSpecs/Conformance/` are
what the earlier Python harnesses recorded; `lake build` still checks them
against the models.

## Reproductions

[repro/](repro/README.md) has one file per finding: `.cljc` files that run on
jank and on Clojure (`jank run --module-path . <file>.cljc`), and `.py`
scripts for what needs several processes or an nREPL client.

## Calling the models from jank

`specs/` is also a lein project (`project.clj`, `jank-build.bb`) whose REPL
runs Lean and Veil in-process, through two libraries of this repository:

- [veil](../veil) (`veil.core`): a session with Veil loaded, models written as
  jank data or loaded from `.lean` files, and Veil's model checker, invariant
  proofs and executable systems, with their results as jank data. The two
  tutorials use it; their shared helpers are in `src/jank_specs/tutorial.jank`.
- [lean-sys](../lean-sys): Lean's runtime and frontend, called from jank. Its
  `lean-sys.session` is what veil is built on; `lean-sys.core` calls exported
  Lean functions.

```sh
cd lean-sys && lein install                                   # once
cd veil && lein install                                       # once
cd specs && lake build +JankSpecs.Native.TinyAtom:dynlib       # Veil, built as shared libraries
cd specs && lein repl                                         # or CIDER's jack-in from a tutorial
```

```clojure
(require '[veil.core :as veil])
(def vs (veil/session {:lake-project "."}))
(veil/load-file! vs "JankSpecs/Tutorial/TinyArrayMap.lean")   ; Veil's messages
(veil/model-check vs "TinyArrayMap" {:instance {:obj 3 :arr 3 :key 1 :val 2}
                                     :theory {:copyOnTransient false}})
;=> {:result :foundViolation, :violates [:maps_hold_what_they_should], :trace [...]}
```

`native/` calls the `swap!` model the other way, through functions the model
exports: `JankSpecs/Native/TinyAtom.lean` exports the executable model
(`Tutorial/TinyAtom.lean`) as C functions on strings, and
`native/src/jank_specs/native.jank` uses them as a test oracle: it takes random
runs of the model's steps, does each step on an atom too (`deref`,
`compare-and-set!`), and compares the model's state with the atom's after every
step (`lein run` in `specs/`). The tutorials do the same with `veil/system`,
for any model, without exported functions.
