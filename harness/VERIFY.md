# Code checked against its model

When you are asked for verified work, the harness doesn't take your word for it: before
your answer is accepted, it checks your file with the `verify` tool, and if anything fails,
it tells you what and you go on. Run `verify` yourself as you go.

The work is two files: a jank namespace with the code and a map `verification`, and a Veil
model of the code, a Lean file (`.lean`) that the map names. `examples/parking.jank` and
`examples/parking.lean` are a complete pair that passes: read them first. VEIL.md is the
guide to writing Veil, with more examples in `examples/veil/`.

## What `verification` holds

```clojure
(def verification
  {:model     "examples/parking.lean"    ; the Veil file: its module's actions are the code's operations
   :instance  {:spot 2}                  ; each `type` of the model and how many values it has
   :sometimes {:full "∀ s, taken s"}     ; states the code must be able to reach, as Veil terms
   :start     (fn [] (new-lot 2))        ; a fresh real system
   :step      {:park (fn [lot {:keys [s]}] (park! lot s))     ; one per action of the model
               :leave (fn [lot {:keys [s]}] (leave! lot s))}
   :view      (fn [lot] {:taken (:taken @lot) :parked (count (:taken @lot))})   ; the real state as the model's
   :max-depth 8})                        ; how many steps the model checker looks
```

## What the check does

1. The model must elaborate, keep its `safety` properties for `:max-depth` steps, and reach
   each `:sometimes` state.
2. Random runs: the real system starts with `:start`; at each step the harness picks an
   action the model allows, with arguments (`{:s 0}`: a `type`'s values are 0, 1, ...,
   an enum's are keywords), calls your `:step` function for it, and compares `(:view sys)`
   with the model's state after that step. They must be equal, at every step.
3. The model's own run to each `:sometimes` state is done on the real code, and must match.
4. Your assertions (below) must hold.
5. Copies of your code with a deliberate bug (`<` made `<=`, `inc` made `dec`, a `when`
   inverted) are checked the same way: at least half of them must fail. A model and a view
   that look closely catch them.

So: every operation of the code is an action of the model, with the same arguments; the
model's `require` says when the operation is allowed; and the view gives exactly the
model's state.

## The model

A Veil file, in Lean: VEIL.md says how to write one. What the check needs of it:

- `veil module Name`, the state (`type`, `relation`, `function`, `individual`),
  `#gen_state`, `after_init` setting every field, an `action` for each operation of the
  code, with the same arguments, its `require` saying when it is allowed, and `safety`
  properties; then `#gen_spec`, `#gen_executable`, and `end Name`.
- The model's state is the same data the `:view` gives (below).
- `#model_check { key := Fin 2 }` lines in the file are left out by the check (it model-checks
  at `:instance` itself), but they let you run the file on its own.

## What the view must give

The model's state is a map of its fields, as jank data:

| field | value | example |
|---|---|---|
| `relation taken : spot → Bool` | the set of what it holds | `#{0 1}` |
| `relation linked : a → b → Bool` | a set of pairs | `#{[0 1]}` |
| `function owner : spot → colour` | a map with every argument | `{0 :red 1 :blue}` |
| `function weight : a → b → Nat` | a map keyed by pairs | `{[0 0] 0 [0 1] 2 ...}` |
| `individual parked : Nat` | the value | `2` |

A `type`'s values are 0, 1, ... (as many as `:instance` says); an enum's are keywords
(`enum colour = { red, blue }`: `:red`, `:blue`).

When the check says they part, it shows each field, real and model: fix whichever is
wrong, the code, the model or the view.

## Assertions in the code

```clojure
(:require [harness.observe :refer [always! sometimes! reachable! unreachable!]])

(always! "never more cars than spots" (<= (count taken) spots) {:taken taken})  ; every time
(sometimes! "the lot is full" (= (count taken) spots))                          ; at least once
(reachable! "the lot is empty again")                                           ; reached once
(unreachable! "a car parks on a taken spot")                                    ; never reached
```

Each has a name (a string). Put them where the code decides something: they are checked on
every random run.

## How to work

1. Write the code (the .jank file) and the model (the .lean file) together, small, with the
   write_file tool. `verify` loads both itself; to try a function by hand, send code to the
   eval tool.
2. Run `verify` on the .jank file. Fix what it says, one problem at a time: Veil's own
   messages name the line of the .lean file.
3. Answer once `verify` passes; the harness checks again before accepting.
