# Code checked against its model

When you are asked for verified work, the harness doesn't take your word for it: before
your answer is accepted, it checks your file with the `verify` tool, and if anything fails,
it tells you what and you go on. Run `verify` yourself as you go.

The file is a jank namespace with the code, a Veil model of it, and a map `verification`
that ties them. `examples/parking.jank` is a complete one that passes: read it first.

## What `verification` holds

```clojure
(def verification
  {:model     model                      ; (veil/defmodel model Name ...), below
   :instance  {:key 2 :val 2}            ; each `type` of the model and how many values it has
   :sometimes {:full '(forall [s spot] (taken s))}   ; states the code must be able to reach
   :start     (fn [] (new-thing ...))    ; a fresh real system
   :step      {:put (fn [sys {:keys [k v]}] (put! sys k v))   ; one per action of the model
               :del (fn [sys {:keys [k]}] (del! sys k))}
   :view      (fn [sys] {:stored ... :present ...})           ; the real state as the model's
   :max-depth 10})                       ; how many steps the model checker looks
```

## What the check does

1. The model must elaborate, keep its `safety` properties for `:max-depth` steps, and reach
   each `:sometimes` state.
2. Random runs: the real system starts with `:start`; at each step the harness picks an
   action the model allows, with arguments (`{:k 0 :v 1}`: a `type`'s values are 0, 1, ...,
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

## The model (veil.core/defmodel)

```clojure
(veil/defmodel model ParkingLot
  (type spot)                      ; a kind of value; :instance gives how many
  (enum colour red blue)           ; named values: :red :blue
  (relation taken [spot])          ; true or false for each spot
  (function owner [spot] colour)   ; a value for each spot
  (individual parked Nat)          ; one value (Nat, Bool, or a type)
  (after-init                      ; the start: set EVERY field here
    (set! (taken S) false)         ; a capital letter: for all spots
    (set! (owner S) :red)
    (set! parked 0))
  (action park [s spot]            ; an operation and its arguments
    (require (not (taken s)))      ; when it is allowed
    (set! (taken s) true)
    (set! parked (+ parked 1)))
  (safety enough_spots (<= parked 2)))   ; true in every state
```

Statements: `(require t)`, `(set! place t)`, `(let [x t] ...)`, `(if t a b)`,
`(when t ...)`, `(do ...)`. Terms: `(= a b)`, `(not= a b)`, `<`, `<=`, `+`, `-`, `(and ..)`,
`(or ..)`, `(not a)`, `(=> a b)`, `(if c a b)`, `(forall [x T] t)`, `(exists [x T] t)`,
`(taken s)`, numbers, `true`, `false`, `:enum-value`. Names are letters, digits and `_`.

## What the view must give

The model's state is a map of its fields, as jank data:

| field | value | example |
|---|---|---|
| `(relation taken [spot])` | the set of what it holds | `#{0 1}` |
| `(relation linked [a b])` | a set of pairs | `#{[0 1]}` |
| `(function owner [spot] colour)` | a map with every argument | `{0 :red 1 :blue}` |
| `(function weight [a b] Nat)` | a map keyed by pairs | `{[0 0] 0 [0 1] 2 ...}` |
| `(individual parked Nat)` | the value | `2` |

When the check says they part, it shows each field, real and model: fix whichever is
wrong, the code, the model or the view.

## Assertions in the code

```clojure
(:require [harness.observe :refer [always! sometimes! reachable! unreachable!]])

(always! "never above capacity" (<= (count items) capacity) {:items items})  ; every time
(sometimes! "the cache is full" (= (count items) capacity))                  ; at least once
(reachable! "an entry is evicted")                                           ; reached once
(unreachable! "a torn record is used")                                       ; never reached
```

Each has a name (a string). Put them where the code decides something: they are checked on
every random run.

## How to work

1. Write the code and the model together, small, with the write_file tool. `verify` loads
   the file itself; to try a function by hand, send code to the eval tool.
2. Run `verify` on the file. Fix what it says, one problem at a time.
3. Answer once `verify` passes; the harness checks again before accepting.
