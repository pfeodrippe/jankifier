# Modelling jank in Veil

This document goes through three models, with their real output:

1. a model of jank's array map transients, which finds the bug where a
   transient changes the map it came from;
2. a model of `swap!` on atoms, which is model checked and then proved for any
   number of threads;
3. the model of jank's nREPL server (`JankSpecs/Nrepl.lean`), described in the
   order it was built, including the corrections that testing against jank
   required.

[tutorial.jank](tutorial.jank) has the same text as a jank file, with forms to
evaluate in a REPL: `(veil "JankSpecs.Tutorial.TinyArrayMap")` builds a model
and prints what Veil found, other forms replay each counterexample on jank, and
part 2 calls the `swap!` model from jank through lean-sys. Its header says how
to start that REPL.

The Veil files of parts 1 and 2 are in `JankSpecs/Tutorial/`. To build them:

```sh
cd specs
lake build JankSpecs.Tutorial.TinyArrayMap JankSpecs.Tutorial.NaiveAtom JankSpecs.Tutorial.TinyAtom
```

## Veil and TLA+

Veil's constructs and their TLA+ counterparts:

| TLA+ | Veil |
|---|---|
| `VARIABLES` | `individual` (one value), `function`, `relation` (a set of tuples) |
| `CONSTANTS` | `type` and `immutable` fields, given per instance |
| `Init` | `after_init { ... }` |
| `Next == A1 \/ A2 \/ ...` | one `action` each; any enabled action, with any arguments, can be the next step |
| an action's enabling condition | `require` |
| an invariant checked by TLC | `safety [name] ...` |
| TLC on a finite model | `#model_check { thread := Fin 3 } { ... }` |
| a TLAPS proof | `#check_invariants`: SMT, for any size, checked by Lean's kernel |

The same step in both:

```tla
Load(t) == /\ pc[t] = "idle"
           /\ seen' = [seen EXCEPT ![t] = value]
           /\ pc' = [pc EXCEPT ![t] = "loaded"]
           /\ UNCHANGED <<value, swaps>>
```

```lean
action load (t : thread) {
  require pc t = idle
  seen t := value
  pc t := loaded
}
```

In Veil, fields an action doesn't assign stay unchanged, so there's no
`UNCHANGED`.

## 1. Array map transients

### jank's code

Three facts from jank 0.1's C++:

- a small map (up to 8 entries) is an *array map*: a pointer to an array of
  key/value slots;
- `(transient m)` copies that pointer, not the array;
- `assoc!` of a key that's already there overwrites its slot in place.

### The property

The property comes from `transient`'s docstring ("Returns a new, transient
version of the collection") and was written before looking for any bug: a
persistent map always holds what it should.

What a map should hold isn't anywhere in jank, so the model keeps it as ghost
state: a field that records the intended contents, updated by each step as the
docs say.

### The model

In the model, maps point to arrays and arrays hold the entries, as in the C++
(`JankSpecs/Tutorial/TinyArrayMap.lean`, with one slot per array):

```lean
relation points : obj → arr → Bool            -- map o points to array a
relation slot   : arr → key → val → Bool      -- array a holds k v
relation should : obj → key → val → Bool      -- ghost: what o should hold

action transient (p : obj) (t : obj) (a : arr) {
  ...
  points t A := points p A                    -- jank: the same array
  should t K V := should p K V
}

action assocBang (t : obj) (k : key) (v : val) {
  require ∃ A V, points t A ∧ slot A k V      -- the key is there
  slot A K V := decide ((points t A ∧ K = k ∧ V = v) ∨ (¬ points t A ∧ slot A K V))
  should t K V := decide (K = k ∧ V = v)
}

safety [maps_hold_what_they_should]
  persistentMap O → ((∃ A, points O A ∧ slot A K V) ↔ should O K V)
```

`literal` makes a map `{k v}` in a new array, and `persistentBang` gives the
result the transient's array.

### Model checking

```
❌ Violation: safety_failure (violates: maps_hold_what_they_should)
  State 1 (via literal(o=0, a=2, k=0, v=1)):   map 0 is {0 1}, in array 2
  State 2 (via transient(p=0, t=2, a=0)):      transient 2 points to array 2 too
  State 3 (via assocBang(t=2, k=0, v=0)):      array 2 now holds {0 0}: map 0 changed
```

The build log prints every field of each state; the right column summarizes
them. The checker explores breadth first, so this 3-step trace is the shortest
counterexample.

### Reproduction on jank

A counterexample is a statement about the model, so it has to be checked on
jank:

```clojure
(let [m {:a 1}] (persistent! (assoc! (transient m) :a 2)) m)
;; jank 0.1: {:a 2}     Clojure: {:a 1}
```

It reproduces (`repro/transient-array-map-mutates-source.cljc`), so it's a
jank bug. Had it not reproduced, the model would have been wrong and needed a
fix.

### The fix

The same file has `copyOnTransient`, a switch for a `transient` that copies
the array. With it on, the checker reports `✅ No violation (explored 715
states)`. This checks a proposed fix before it's written in C++.

### Why the first transient model missed it

My first transient model only tracked whether each transient was still active.
The bug is in the storage, which that model didn't describe, so it couldn't
find it. A model only finds bugs in what it describes; this one describes which
object points to which array. A differential test against Clojure found the bug
first, and this model then finds it in 3 steps.

## 2. `swap!` on atoms

jank's `swap!` reads the value, computes the new one, then does a
compare-and-set: if the atom changed in the meantime, it starts again.

### The model

```lean
individual value : Nat
function pc : thread → pc_t                   -- idle, loaded, done
function seen : thread → Nat                  -- what the thread read
individual swaps : Nat                        -- ghost: swap!s that took effect

action load (t : thread) { require pc t = idle; seen t := value; pc t := loaded }

action cas (t : thread) {
  require pc t = loaded
  if value = seen t then                      -- unchanged since the read
    value := seen t + 1
    swaps := swaps + 1
    pc t := done
  else
    pc t := idle                              -- read again
}

safety [no_lost_update] value = swaps
```

### Model checking a `swap!` without compare-and-set

`NaiveAtom.lean` stores without the compare (`value := seen t + 1` always).
With two threads:

```
❌ Violation: safety_failure (violates: no_lost_update)
  State 1 (via load(t=1)):    value = 0
  State 2 (via load(t=0)):    value = 0, both read 0
  State 3 (via store(t=1)):   value = 1, swaps = 1
  State 4 (via store(t=0)):   value = 1, swaps = 2   ← one update lost
```

For jank's `swap!` (`TinyAtom.lean`) with three threads, the checker reports
`✅ No violation (explored 71 states)`. That covers every interleaving of three
threads, and no more.

### Proof for any number of threads

A proof here is induction over steps:

1. the properties hold in the initial state;
2. in any state where all of them hold, any step keeps them holding.

Then they hold in every reachable state, for any number of threads and any
interleaving. `#check_invariants` asks an SMT solver both questions, for every
action, and Lean's kernel checks the answers (`set_option veil.smt.trust
false`).

The model has a second property: each `swap!` returns more than every `swap!`
before it. A ghost flag `stale` is set if one returns a value no larger than
the largest returned so far (`maxReturned`):

```lean
safety [results_increase] ¬ stale
```

The first attempt printed:

```
  cas
    no_lost_update ... ✅
    results_increase ... ❌
      Pre-state:  value = 0, swaps = 0, maxReturned = 1, stale = false, thread 0 loaded 0
      Action: cas(t=0)
      Post-state: value = 1, swaps = 1, maxReturned = 1, stale = true
```

`no_lost_update` is proved. For `results_increase`, the solver shows a state
where the property holds and one step breaks it. No run reaches that state:
`maxReturned = 1` while no `swap!` is done. Step 2 of the induction considers
every state where the properties hold, reachable or not. This is why model
checking passed (it only visits reachable states) while the proof failed.

The proof needs the fact that rules this state out. The question is why
`maxReturned = 1, swaps = 0` can't happen, and the answer is that the largest
value returned always equals the number of `swap!`s:

```lean
invariant [max_is_swaps] maxReturned = swaps
```

With this invariant, every row is ✅, for `load` and `cas`, and the new
invariant is proved too. In general, a missing invariant is found this way:
read the counterexample to induction, find why its state is unreachable, and
add that fact as an invariant.

### Scope of the proof

The proof is about the model: every interleaving of any number of threads doing
`swap!` as a load followed by a compare-and-set loses no update and returns
increasing values. It assumes the model matches the C++, where one
compare-and-set is one atomic step. The full model (`Concurrency/Atom.lean`) is
also checked against 5000 runs of jank.

## 3. The nREPL server model

Editors talk to jank through its nREPL server, often over several connections
at once. This section describes how `JankSpecs/Nrepl.lean` was built.

### 1. Properties

The properties come from nREPL's documentation and from what CIDER expects:

- N1 every request gets an answer;
- N2 every response carries its request's `id` and `session`;
- N3 `done` comes in its own message;
- N4 an eval's `:out` holds what that eval printed, and only that;
- N5 when no eval runs, the server's stdout is its own again;
- N6 `*1` is the session's last value;
- N7 an unknown op is reported as one.

### 2. Shared state in the code

From `nrepl/server/core.jank`, `capture.jank` and `evaluate.cpp`:

- each connection gets a thread, which takes its requests one at a time; if
  handling one throws, the thread's loop ends;
- to capture an eval's output, `capture.jank` saves file descriptor 1 (`dup`),
  flushes C's stdout buffer, points descriptor 1 at a temp file (`dup2`), runs
  the eval, flushes again, points descriptor 1 back to the saved one, reads the
  temp file and deletes it;
- `*1` is a binding of the connection's thread.

Descriptor 1 and C's stdout buffer belong to the process, not the connection.
So everything a connection's thread does alone can be one step, but every
operation on the shared descriptor or buffer must be a step of its own, because
another connection's steps can come in between.

### 3. Actions

Each eval goes through phases, with one action per operation on shared state:

```
queued ─take─> taken ─redirect─> capturing ─evaluate─> evaluated ─endFlush─> flushed ─release─> released ─respond─> answered
        dup the backup   fflush, dup2 the temp   prints go to the buffer   fflush       dup2 back, delete temp       (or lost, when it threw)
```

```lean
action take (c : conn) (r : req) {
  require alive c ∧ ¬ busy c                            -- one request at a time per connection
  require reqConn r = c ∧ phase r = queued
  require ∀ Q, reqConn Q = c ∧ phase Q = queued → le r Q  -- in order
  if isEval r then
    busy c := true
    backupTo r Q := stdoutTo Q                          -- dup: save where fd 1 points now
    phase r := taken
  ...
}

action redirect (r : req) {
  require phase r = taken
  flush                                                 -- fflush(stdout)
  stdoutTo Q := decide (Q = r)                          -- dup2: fd 1 -> r's temp file
  phase r := capturing
}

action release (r : req) {
  require phase r = flushed
  stdoutTo Q := backupTo r Q                            -- dup2 back to the backup
  deleted r := true                                     -- the temp file is deleted
  ...
}
```

### 4. State

The state has only what the properties need:

- where descriptor 1 points (`stdoutTo r`: `r`'s temp file; nowhere: the
  process's own stdout), each eval's backup (`backupTo`), deleted temp files;
- what is in C's stdout buffer (`buffered r`: `r` printed and it isn't flushed
  yet). `flush` moves it to wherever descriptor 1 points at that moment;
- ghost state for the observations: where each print ended up (`printedIn r q`:
  `r`'s print went to `q`'s output; `printedTerminal`, `printedLost`);
- per connection: alive, busy, `*1`.

The requests are constants (the theory): which connection sends each, what it
is (an eval that prints, one that throws, `*1`, a bad argument, an unknown
op...), and in which session. The instance has two connections and four
requests.

### 5. Properties in Veil

```lean
safety [n4_output_isolation]
  focus = 4 → ((printedIn X R → X = R) ∧ ¬ printedLost X ∧ ¬ printedTerminal X)
safety [n5_stdout_restored] focus = 5 → ((∀ C, ¬ busy C) → ¬ stdoutTo Q)
```

`focus` selects which expected-to-fail property a run checks; see
"Conventions" in [AGENTS.md](AGENTS.md).

### 6. Counterexamples

For N4, with two connections each evaluating code that prints (`r0` on
connection 0, `r2` on connection 1):

```
take(r0)  take(r2)            both start capturing
redirect(r0)                  fd 1 -> r0's temp file
redirect(r2)                  fd 1 -> r2's temp file
evaluate(r0)                  r0 prints: into the buffer
endFlush(r0)                  the flush writes r0's print into r2's temp file
```

`r0`'s output shows up in `r2`'s response. For N5:

```
take(r0)  redirect(r0)        r0's backup: the real stdout; fd 1 -> r0's temp
take(r2)                      r2's backup: r0's temp file  (saved while r0 captures)
redirect(r2)                  fd 1 -> r2's temp
...       release(r0)         fd 1 -> the real stdout; r0's temp deleted
          release(r2)         fd 1 -> r0's temp file, which is deleted
```

At the end both evals are done, and the server's stdout points to a deleted
file, so everything printed outside an eval afterwards is lost. Both reproduced
on jank (`repro/nrepl-concurrent-output-swap.py`: output swapped in 20 rounds
of 20, and the late print lost). N1, N3 and N6 were found the same way, each
from its own small instance.

### 7. Conformance testing

The harness ran scripts of four requests on a real server, many times, and
checked that every outcome jank showed (each response's `:out`, value and
status, and what reached the server's stdout) is one the model allows.

At first it wasn't. jank showed a print on the server's own stdout with stdout
working afterwards, which my first model said was impossible. That model
captured output in one atomic step and sent a print to wherever descriptor 1
pointed when it was printed. Working out how that print could reach the real
stdout gave two facts the first model had wrong:

- `println` writes to C's buffer, and the bytes reach descriptor 1 at the next
  `fflush`, done by whichever capture comes next, possibly after another eval
  restored stdout;
- starting a capture is three system calls (`dup`, `fflush`, `dup2`), and
  another connection's steps can come between them.

The model then got the `buffered` state, the `flush` procedure and the split
between `take` and `redirect`, and every outcome conformed (24 scripts, 3 runs
each). The harness had a similar gap: its own check that stdout still works
needed an eval that flushes the buffer.

### 8. Proofs

The checker found no violation of "one eval at a time per connection" or "in
order", but only in the instance. To prove them for any number of connections
and requests, `#check_invariants` needed the reason a connection can't run two
evals at once: `take` requires the connection not to be busy, and it stays busy
until `respond`.

```lean
invariant [eval_busy] inEval R → busy (reqConn R)
```

N7 needed the invariant that only evals are captured (`only_evals_capture`):
the solver's counterexample to induction was an unknown op in a phase that
only evals reach, a state no run gets to. With these, `one_eval_per_connection`,
`in_order`, N2 and N7 are proved.

### 9. Results

The model found five bugs, each with a counterexample and a reproduction on
jank: N1 (a bad argument kills the connection), N3 (`done` comes with the
error), N4 (output crosses connections), N5 (stdout is lost), and N6 (sessions
share `*1`). N4, N5 and N6 are also in determinismo's analysis.

The model also shows where a fix has to go: while captures swap the process's
descriptor 1, concurrent evals interfere. A capture that doesn't touch it
(determinismo's analysis recommends the same) removes N4 and N5, and such a
design can be modelled and checked before it's written, as the copy in part 1
was.

## Summary of the method

1. Write the properties from the docs, before reading the code for bugs.
2. Model each step of the code that touches shared state as an action (a read,
   a compare-and-set, a lock), and model the data layout where bugs can be.
3. Add ghost state for what the properties need (`swaps`, `should`).
4. Model check small instances. Reproduce each counterexample on jank; if it
   doesn't reproduce, fix the model.
5. Use `#check_invariants` to prove the properties that model checking didn't
   violate. For each ❌, read the counterexample to induction, find why its
   state is unreachable, and add that as an `invariant`.
6. Test the model against real runs of jank.
