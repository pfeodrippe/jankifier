# veil

[Veil](https://github.com/verse-lab/veil) models from jank, in-process. A model
is jank data; Veil runs in the jank process, through
[lean-sys](../lean-sys); its model checker, invariant proofs and executable
systems return their results as jank data: counterexample traces made of the
model's own states, the status of each proof obligation, the steps a state
allows.

## Usage

Add this project to your Leiningen `:dependencies` vector:

```clojure
[jankifier/veil "0.1.0-SNAPSHOT"]
```

Veil itself comes from a Lake project that depends on it, built with its
packages' shared libraries (in this repository, `specs/`:
`lake build +JankSpecs.Native.TinyAtom:dynlib` builds them).

```clojure
(require '[veil.core :as veil])

(def vs (veil/session {:lake-project "path/to/lake/project"}))   ; a few seconds

(veil/defmodel naive-atom NaiveAtom
  (type thread)
  (enum pc_t idle loaded done)
  (individual value Nat)
  (function pc [thread] pc_t)
  (function seen [thread] Nat)
  (individual swaps Nat)
  (after-init
    (set! value 0)
    (set! (pc T) :idle)
    (set! (seen T) 0)
    (set! swaps 0))
  (action load [t thread]
    (require (= (pc t) :idle))
    (set! (seen t) value)
    (set! (pc t) :loaded))
  (action store [t thread]
    (require (= (pc t) :loaded))
    (set! value (+ (seen t) 1))
    (set! swaps (+ swaps 1))
    (set! (pc t) :done))
  (safety no_lost_update (= value swaps)))

(veil/model-check vs naive-atom {:instance {:thread 2}})
;=> {:result :foundViolation, :violation :safetyFailure, :violates [:no_lost_update],
;    :trace [{:action :after_init, :state {:value 0, :pc {0 :idle, 1 :idle}, :seen {0 0, 1 0}, :swaps 0}}
;            {:action :load, :args {:t 0}, :state {...}}
;            ...
;            {:action :store, :args {:t 1}, :state {:value 1, :pc {0 :done, 1 :done}, ..., :swaps 2}}]}

(veil/prove vs naive-atom)
;=> [... {:vc :store_no_lost_update, :status :disproven, :action :store, :property :no_lost_update,
;         :counterexample {:pre-state {...} :action :store :args {...} :post-state {...}}} ...]

(def sys (veil/system vs naive-atom {:instance {:thread 2}}))
(veil/initial-states sys)
;=> [{:value 0, :pc {0 :idle, 1 :idle}, :seen {0 0, 1 0}, :swaps 0}]
(veil/successors sys {:value 0 :pc {0 :loaded 1 :idle} :seen {0 0 1 0} :swaps 0})
;=> [{:action :load, :args {:t 1}, :state {...}} {:action :store, :args {:t 0}, :state {...}}]
(veil/properties sys {:value 1 :pc {0 :done 1 :done} :seen {0 0 1 0} :swaps 2})
;=> {:no_lost_update false}
```

A model is a map (`{:name "NaiveAtom" :decls [...]}`), so it can be built and
changed with jank functions: `(update model :decls ...)` removes an invariant to
see what the proof needs it for. `veil/source` gives its Veil text.

Existing `.lean` models load too, and the functions then take the module's
name:

```clojure
(veil/load-file! vs "JankSpecs/Tutorial/TinyArrayMap.lean")   ; Veil's messages, as data
(veil/model-check vs "TinyArrayMap" {:instance {:obj 3 :arr 3 :key 1 :val 2}
                                     :theory {:copyOnTransient false}})
```

Temporal properties are declared in the model, in Lentil's LTL, as
s-expressions, then model checked or proved for every run:

```clojure
(veil/defmodel consensus Consensus
  ...
  (temporal success (=> (wf choose) (eventually (state someChosen)))))

(veil/check-temporal vs consensus 'success {:instance {:value 3}})
;=> {:result :holds, :explored-states ...}
(veil/prove-temporal vs consensus 'success "tclear hInv\ntintro hwf\n...")
;=> {:proved? true, :axioms [propext Classical.choice Quot.sound], :messages [...]}
```

A failing temporal property gives a run that violates it, as states:
`{:result :fails :stem [...] :loop [...]}`.

## Functions

- `session`: Lean with Veil imported, from `:lake-project`.
- `defmodel`, `model`, `source`: models as data (`defmodel`'s docstring lists
  the declarations, statements and terms).
- `load!`: elaborates a model into the session, as a module left open.
  `load-file!`: elaborates a `.lean` file.
- `model-check`: Veil's model checker, for an `:instance` (`{:thread 2}` is
  `Fin 2`), a `:theory` and a `:max-depth`; `:parallel` searches with several
  sub-tasks, and `:compiled` compiles the checker to native code first
  (`lean-sys.session/compile!`).
- `simulate`: Veil's simulator: random runs, checking the properties in each
  state.
- `check-temporal`: Veil's liveness model checker on a temporal property: it
  holds, or a run (a stem and a loop of states) violates it.
- `prove-temporal`: a temporal property proved for every run, by Lean tactics,
  with Veil's `prove_temporal_by`.
- `prove`, `proved?`: the invariants by induction, as `#check_invariants`,
  with the solver's counterexample to induction for each failure;
  kernel-checked when the model sets `(set-option veil.smt.trust false)`.
- `system`, `initial-states`, `successors`, `properties`,
  `reachable-states`: the executable transition system, on states from the
  model or written in jank (`:compiled` for native code).

## Tests

```sh
cd veil && lein test     # with ../specs built (its Veil packages' shared libraries), else rendering only
```

## How it works

`include/veil_jank/source.hpp` has Lean code that veil elaborates into each
session: term elaborators that build, from Veil's public API, what Veil's own
commands build (`veil_find_reachable%` the model checker's search,
`veil_simulate%` the simulator's, `veil_check_temporal%` the liveness
checker's, `veil_system%` the executable system, `veil_properties%` the
property checks), `JankVeil.reachableStates`, and `JankVeil.checkInvariants`,
which runs `#check_invariants`'s check and returns a summary of its
`VerificationResults`. lean-sys calls them and reads their results by their
Lean types.

A model is elaborated as a Veil module with `#gen_spec` and `#gen_executable`
added, and left open (proofs need it open); loading another closes it. A model
or file loaded again gets a module name with a number. `#model_check` commands
in loaded files run interpreted: veil sets `VEIL_ONLINE_ENV` in its process,
which keeps Veil from also building a compiled checker with Lake.

[specs/tutorial_jank_models.jank](../specs/tutorial_jank_models.jank) writes
three models in jank and goes through each of these functions;
[specs/tutorial.jank](../specs/tutorial.jank) does the same with `.lean` files.
