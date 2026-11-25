# Elle's closed-predicate checker in Lean

Elle checks histories of database transactions for consistency anomalies. Its closed-predicate
checker, `elle/closed_predicate.clj`, infers from what each transaction read and wrote a graph of
dependencies between the transactions, and reports the graph's cycles as anomalies. Its
namespace docstring (lines 1 to 95) explains the idea: a predicate read sees a version of every
key, including the keys it did not match, so it depends on writes it never returned.

## The work

In `lean/`, a Lean 4 project:

1. **The translation**, `lean/ElleCP/ClosedPredicate.lean`: `closed_predicate.clj` from `xor`
   (line 113) to `check` (line 689), function by function, as Elle wrote it. It must give the
   same result as Elle for every history, including anything that looks wrong: a translation
   that corrects Elle hides what this work is looking for. Name each `def` after its Clojure
   function, with the line it comes from in a comment. The entry point:

   ```lean
   def check (opts : Elle.Opts) (h : Elle.History) : Elle.Outcome
   ```

   The generators after line 716 are not needed.

2. **The specification**, `lean/ElleCP/Spec.lean`: what the checker should report, written from
   the definitions and not from the code: the namespace docstring (`elle/DOCSTRING.md`, the
   only part of Elle's file the specifier reads), the base's types, and Adya's dependency
   graphs (Adya, *Weak Consistency*, 1999):
   - each key's versions in history order: the `:init` op's value first, then each committed
     transaction's writes; a key that does not exist yet has an unborn version before its first
     write, and a delete makes a dead version;
   - **ww**: from the writer of a version to the writer of the next version of the same key;
   - **wr**: from the writer of a version to a transaction that read it;
   - **rw**: from a transaction that read a version to the writer of the next version;
   - for a predicate read (`[:rp pred {k v ...}]`): the version set it saw, one version of every
     key, matching the predicate or not; a **predicate read dependency** from the writer of a
     version in that set, and a **predicate anti-dependency** to the writer of a later version
     that changes whether the predicate matches;
   - a cycle of these edges is an anomaly: only ww edges is G0; ww and wr is G1c; exactly one
     anti-dependency is G-single; more than one is G2.

   Give it a function that says, for a history, which anomalies exist, in whatever form makes
   comparing easy.

3. **The comparison**: run both on many small histories (a `lean/ElleCP/Compare.lean` with
   `#eval`, or a small executable) and look at every history where they disagree. For each
   disagreement, find the smallest history that shows it, and write it in `REPORT.md`: the
   history, what the translation says, what the specification says, and which lines of
   `closed_predicate.clj` make the difference. A disagreement can be a mistake in the
   translation, a mistake in the specification, or something Elle does: check the translation
   against the Clojure, line by line, before saying it is Elle's.

4. Optional: theorems about the translation or the specification, with their proofs (no `sorry`).

## What is given

`lean/Elle/*.lean`: the rest of Elle, already translated. Do not change these files. Of Elle's
Clojure only `closed_predicate.clj` is here (looking for the rest finds nothing): to see what a
function it calls from `elle.txn` or `elle.core` does, read its translation in `Txn.lean` or
`Core.lean`, whose comments name the Clojure lines.

- `Basic.lean`: histories. `Val` (nil, an integer, a map of keys to values, unborn, dead), `Mop`
  (a micro-op `[f k v]`; `f` is `.r .w .insert .delete .rp`; for `.rp`, `pred` holds the
  predicate and `v` the read map), `Op` (index, type `.invoke .ok .fail .info`, process, `f`
  `.txn` or `.init`, value: its mops), `History` (an `Array Op`, an op's index is its position).
  An `:init` op's value is its map written as `[:w k v]` mops.
- `Graph.lean`: `Rels` (the edge kinds as bits: `Rels.WW`, `WR`, `RW`, `WWP`, `WRP`, `RWP`,
  `PROCESS`, `REALTIME`), `Graph` and `link g a b r` (an edge between op indices).
- `Core.lean`: `Analysis` (`{graph, explain, anomalies}`, as Elle's `{:graph :explainer
  :anomalies}`), `combine` (core.clj's).
- `Txn.lean`: Elle's txn pipeline: `Opts`, `additionalGraphs`, `extraAnalysesOf` (the process
  and real-time graphs the options ask for), `cyclesE` (the cycle search and classification),
  `addCases`, `resultMap`, `Outcome`. `closed_predicate.clj`'s `check` calls the same functions
  of `elle.txn` and `elle.core`.

What `closed_predicate.clj` calls from outside, and where it is in Lean:

| Clojure | Lean | What it does here |
|---|---|---|
| `h/client-ops` | (none needed) | keeps the ops whose process is a number: every op of these histories |
| `h/possible` | `Elle.possible` | the `:ok` and `:info` ops |
| `h/oks` | `Elle.oks` | the `:ok` ops |
| `h/filter-f` | `List.filter` on `Op.f` | the ops with that `:f` (`.init`, `.txn`) |
| `g/op-digraph` | `({} : Graph)` | an empty graph |
| `g/link` | `link g a b r` | adds the edge a → b of kind `r` (op indices) |
| `b/linear`, `b/forked` | (none needed) | Bifurcan's mutable and persistent modes: no difference in Lean |
| `elle/combine` | `combine` | `Core.lean` |
| `ct/additional-graphs` | `additionalGraphs`, `extraAnalysesOf` | `Txn.lean` |
| `ct/cycles!` | `cyclesE an {}` (an `Except`) | `Txn.lean`; `{}` is the default order of the graph's vertices |
| `ct/result-map` | `resultMap` | `Txn.lean` |

The explainers (`RWExplainer`, `WRExplainer`, `WWExplainer`, records of `elle/DataExplainer`) are
in Lean an analysis's `explain : Nat → Nat → Option Step` (op indices in, as
`explain-pair-data`'s `a` and `b`): `none` for Clojure's `nil`, else a `Step` with `type` the
map's `:type` as a string (`"rw"`, `"rwp"`, ...), `key` its `:key`, and `predicate` true when the
map has `:predicate? true` (the cycle classification reads it). The map's other keys and
`render-explanation` only make the text of an explanation: not needed.

Two Clojure forms the file uses often:

- `loopr` (from the dom-top library, `dt/loopr`): `(loopr [acc init ...] [x coll ...] body final?)`
  goes through the elements of the collections (several bindings nest, as in `for`), with the
  accumulators bound. In the body, `(recur new-acc ...)` goes on to the next element with new
  accumulator values; **any other value in tail position returns at once** from the whole
  `loopr`. When the elements run out, it returns `final` if there is one (it can use the
  accumulators), else: nothing for no accumulator, the accumulator itself for one, a vector of
  them for several. So `(loopr [found false] [v vs] (if (= v x) true (recur found)))` is true
  when `x` is in `vs`, and when it isn't, returns `found`, false.
- `transient`, `conj!`, `assoc!`, `persistent!`: Clojure's in-place building of a collection.
  In Lean they are the ordinary immutable operations.

A history in Lean, for example: an init creating keys 0 and 1, then a transaction that inserts
key 2 and one that reads key 1 and every key whose value is 5:

```lean
open Elle in
def example1 : History := #[
  { index := 0, type := .invoke, process := 0, f := .init, value := [⟨.w, 0, .int 0, .tru⟩, ⟨.w, 1, .int 0, .tru⟩] },
  { index := 1, type := .ok, process := 0, f := .init, value := [⟨.w, 0, .int 0, .tru⟩, ⟨.w, 1, .int 0, .tru⟩] },
  { index := 2, type := .invoke, process := 1, value := [⟨.insert, 2, .int 5, .tru⟩] },
  { index := 3, type := .ok, process := 1, value := [⟨.insert, 2, .int 5, .tru⟩] },
  { index := 4, type := .invoke, process := 2, value := [⟨.r, 1, .nil, .tru⟩, ⟨.rp, 0, .nil, .eq 5⟩] },
  { index := 5, type := .ok, process := 2, value := [⟨.r, 1, .int 0, .tru⟩, ⟨.rp, 0, .kmap [(2, .int 5)], .eq 5⟩] }]
```

## Building

```sh
cd lean
$LAKE build                          # the whole project
$LAKE env lean ElleCP/Compare.lean   # one file, with its #eval output
```

`$LAKE` is Lean's build tool (Lean 4.35). An error names the file, line and column.
