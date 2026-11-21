# Formal models of jank

Models of parts of jank 0.1, written in [Veil](https://github.com/verse-lab/veil)
(a Lean 4 framework for transition systems), each tested against the real
jank. See [PLAN.md](PLAN.md) for the approach, [RESULTS.md](RESULTS.md)
for what was found, and [AGENTS.md](AGENTS.md) for how the work is done here and
Veil's and jank's rough edges, with workarounds. New to this?
[TUTORIAL.md](TUTORIAL.md) walks through two small models (a real failure and
a proof) and the reasoning behind the nREPL one; [tutorial.jank](tutorial.jank)
is the same document as a jank file, to read and run in a REPL: it runs the
Veil checks and replays their counterexamples on jank.

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

Each harness runs scenarios on the installed `jank` (or `$JANK`), writes what
jank showed as a generated Lean file under `JankSpecs/Conformance/`, and builds
it, which checks it against the model.

```sh
python3 conformance/module_cache/run.py --random 20     # traces, replayed step by step
python3 conformance/concurrency/bindings.py --random 150
python3 conformance/concurrency/atom.py --runs 5000     # outcome sets
python3 conformance/concurrency/once.py --runs 3000
python3 conformance/nrepl/run.py --random 20 --seed 3 --repeat 3
python3 conformance/blind/vars.py --runs 2000 --blocks 200     # outcome sets, and Clojure
python3 conformance/multi/run.py --programs 300                # replay, and Clojure
python3 conformance/transients/run.py --programs 500           # table, and differential vs Clojure
python3 conformance/transients/arraymap.py --programs 500      # replay, entry by entry
```

The phase 2 harnesses also run their programs on Clojure (`clojure` on the
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
- **Outcome sets** (atoms, delay/promise/lazy seq, nREPL, vars, `require`): for concurrent
  programs only the end result can be observed; the model enumerates every
  result its interleavings allow, and every result jank shows must be one of
  them.

Each harness also runs the model checker's counterexamples (read from the
build log) or a scenario built to reach them, so every violation is reproduced
on jank. Scratch files go to `conformance/out/` (ignored by git).

## Reproductions

[repro/](repro/README.md) has one file per finding: `.cljc` files that run on
jank and on Clojure (`jank run --module-path . <file>.cljc`), and `.py`
scripts for what needs several processes or an nREPL client.

## Calling the models from jank

`specs/` is also a lein project (`project.clj`, `jank-build.bb`) that calls a
Veil model from jank, in the same process, through [lean-sys](../lean-sys).
`JankSpecs/Native/TinyAtom.lean` exports the executable `swap!` model
(`Tutorial/TinyAtom.lean`) as C functions, and
`native/src/jank_specs/native.jank` uses it as a test oracle: it takes random
runs of the model's steps, does each step on an atom too (`deref`,
`compare-and-set!`), and compares the model's state with the atom's after every
step.

```sh
cd lean-sys && lein install                                   # once
cd specs && lake build +JankSpecs.Native.TinyAtom:dynlib       # the model, as shared libraries
cd specs && lein run
```

`lein repl` in `specs/` (or CIDER's jack-in from a file there, such as
`tutorial.jank`) gives a REPL with the model loaded: `(require
'[jank-specs.native :as native])`, `(native/init!)`, then `(native/enabled [])`,
`(native/model-state ["load 0"])` or `(native/random-run)`.
