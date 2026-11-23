# Specifications of the inkling engine

Veil models of the engine's stateful logic, with their proofs and model checks,
and tests that compare each model with the engine itself (`libinkling`), all
run from jank: Veil runs in the jank process (through the `veil` and `lean-sys`
libraries of this repository), and the engine is loaded in the same process.

What is covered is mostly the bookkeeping: where each position's keys and
values are kept and which ones a token reads, what the convolutions remember
between chunks, how the residual stream's slots are reused, how the thread
pool hands a job to its workers, how the router chooses experts, and what the
session API does. Of the arithmetic, the attention kernels' softmax and the
router's weights are proved in exact arithmetic (`SoftmaxMerge.lean`,
`RouterWeights.lean`); that the floats come out close to that is for `check-gpu`
(the GPU against the CPU, stage by stage) and the comparison with the
reference implementation.

## Layout

- `models/`: the Veil models (`.lean`), one per subject, each with a header
  saying which C++ it follows; `PoolProof.lean` and `StreamProof.lean` are the
  proved versions of `Pool.lean` and `Stream.lean`; `RingLemmas.lean`,
  `SoftmaxMerge.lean` and `RouterWeights.lean` are plain Lean theorems.
- `src/inkling_specs/`: one jank namespace per subject (`ring`, `conv`,
  `stream`, `pool`, `attention`, `router`, `session`, `session-model`),
  `core` (the Veil session, `check`, the engine's model), `check` (the command
  line) and `pool_stress` (the pool's stress test as a program).
- `include/inkling_specs/harness.hpp`: the tests' C++ (reading caches,
  captures and events from sessions; the pool's stress tests).
- `check-lean`: elaborates a model with `lean` alone, without jank, for
  editing a model.

## Running

Once: `lean-sys` and `veil` installed (`lein install` in each), the Lake
project in `../../specs` built with Veil's shared libraries
(`lake build +JankSpecs.Native.TinyAtom:dynlib` there; nothing of that project
is used but its build of Veil), the engine built (`make` in `..`), and the
model file in `../models/inkling-2-mini.ink`. No other program should hold the
model on the GPU at the same time.

From the command line, in this folder:

```sh
lein run -m inkling-specs.check                 # everything (about 30 minutes; the models alone, the -model names, about 11)
lein run -m inkling-specs.check ring conv       # some subjects
lein run -m inkling-specs.check ring-model      # a subject's models only, without the engine
./check-lean models/Ring.lean                   # one model, with lean alone
```

From a REPL (`lein repl` here, or CIDER's jack-in from a file of
`src/inkling_specs/`):

```clojure
(require '[inkling-specs.core :as c]
         '[inkling-specs.ring :as ring]
         '[inkling-specs.conv :as conv]
         '[inkling-specs.stream :as stream]
         '[inkling-specs.pool :as pool]
         '[inkling-specs.session :as session]
         '[inkling-specs.attention :as attention]
         '[inkling-specs.router :as router]
         '[inkling-specs.session-model :as session-model])

(c/check "Ring.lean")            ; elaborates a model: its proofs and model checks, as Veil prints them
(ring/model-checks)              ; the model checker on the namespace's instances, as data
(ring/too-few-slots)             ; a variant of the model that must fail, with its counterexample
(ring/ring-contents {})          ; a test on the engine
(ring/run)                       ; all of a subject; (ring/run {:engine false}) for the models alone
```

Every function returns data; `run` prints each result and returns `{:ok ...}`.
`c/vs` is the Veil session and `c/engine` the engine's model, both created on
first use. `(veil/model-check @c/vs "Ring" {...})` and the other functions of
`veil.core` work on a module once its file is loaded (`c/load-model!`).

## What is modelled, proved and tested

"Proved" means `#check_invariants`: every property holds initially and every
action preserves all of them, for any sizes and any number of sessions, with
the SMT solver's answers checked by Lean's kernel (`veil.smt.trust false`).
"Model checked" means every reachable state of the listed instances was
explored. The engine tests ran against `lib/libinkling.dylib` on the GPU
unless they say CPU. Every proof uses only Lean's standard axioms (`propext`,
`Classical.choice`, `Quot.sound`); none has `sorry`.

### The key/value ring (`Ring.lean`, `RingLemmas.lean`, `inkling-specs.ring`)

A visit's cache has `min(context, window + max_chunk)` slots (all of the
context in a global visit), and position `p` is in slot `p % slots`. A forward
pass writes the keys and values of all of a chunk's tokens, then each token
attends to its window.

- Property (`window_held`): when a token attends, every position of its window
  (every earlier position, in a global visit) is in its slot with the current
  sequence's data, however the tokens were split into chunks, through `reset`
  and `copy` (which copies `min(slots, pos)` rows).
- Proved: 64 obligations, for any window, chunk size, context and number of
  sessions. The model keeps the position-to-slot map abstract and assumes two
  facts about it; `RingLemmas.lean` proves them for `p % slots`, and that the
  engine's number of slots is enough (Lean theorems; axioms `propext`,
  `Quot.sound`).
- Model checked: 11 instances with the engine's rule for the number of slots
  (windows and chunks of 1 to 3, contexts that wrap the ring twice, a context
  shorter than the ring, global visits, two sessions with `copy`): 60 to 7,921
  states each.
- The number of slots matters: without the assumption about it, and with
  `window + max_chunk - 2` slots, the checker finds a token attending to a
  position its own chunk overwrote (`too-few-slots`). The engine has one slot
  more than the least that works.
- Engine, `ring-contents`: 1,300 tokens in chunks of 1 to 64 (a local visit's
  ring has 1,088 slots, so it wraps), logging the rows each position is given
  in each of the 48 visits as it is written; after every chunk, every position
  the last token attends to is looked up at `position % slots` in every visit
  and compared bit for bit with its logged rows. Also with the last tokens
  evaluated on the CPU over the caches the GPU filled.
- Engine, `visit-0-references`: the rows a wrapped ring holds in visit 0
  against rows computed by a new session from four tokens alone (visit 0's
  keys at a position depend on that token and the three before).
- Engine, `read-window`: which positions the last token reads after the ring
  wrapped, found by changing one token and seeing which of visit 0's attention
  weights change (traced on the CPU): a token just outside the window changes
  none, the next one changes the oldest key only, and a token inside changes
  the four keys it reaches.

### The short convolutions' history (`Conv.lean`, `inkling-specs.conv`)

Each visit has four causal convolutions over four positions, and a session
keeps their last three inputs. `cpu.cpp` builds `history ++ chunk`; the Metal
kernels keep three registers per channel.

- Properties: an output reads its own input and the three before it
  (`taps`), and between chunks the history is the last three inputs
  (`history`), for every chunking, through `reset` and `copy`.
- Proved: 36 obligations, for both implementations, any chunk size and
  context.
- Model checked: 8 instances (both implementations, chunks up to 4, two
  sessions): up to 34,397 states.
- Engine, `chunking-independence`: the same tokens in five chunkings on the
  CPU leave the same state bit for bit (every visit's keys, values and
  convolution histories, and the logits). On the GPU, chunks of different
  sizes use different kernels and round differently, so the states are
  compared by distance.
- Engine, `gpu-against-cpu`: the same tokens and chunking on both paths.
  Visit 0's key and value histories (projections of the embeddings) agree
  within rounding; later ones drift, since the model's routing and
  quantization amplify rounding differences (`inkling check` compares the two
  paths stage by stage, with the CPU's values forced in).

### The attention's softmax and the split attention (`SoftmaxMerge.lean`, `SplitAttention.lean`, `inkling-specs.attention`)

`attention` (a threadgroup a head, each thread a strided share of the keys
with a running softmax) and `att_split` then `att_merge` (one token over a
long context: the keys in chunks, a chunk's simdgroups each a strided share,
records merged within the threadgroup, then across chunks with the sink).

- Proved in Lean (`SoftmaxMerge.lean`): both compute exactly the softmax of
  the keys' scores and the sink logit applied to the keys' values and a zero
  (`attention_exact`, `split_attention_exact`), so they compute the same
  (`split_equals_plain`), for any split of the keys among threads, simdgroups
  and chunks, any order within a thread, and any choice of the running maxes
  and comparisons (the maxes only keep `exp` in range in floats). Also the
  engine's chunking: `splits = min(64, keys / 512)`, `chunk = ceil(keys /
  splits)` cover the keys in order, with at least two chunks and none empty,
  for `keys ≥ 1024` (`chunks_cover`, `engine_chunks`); the strided shares are
  a permutation of their keys (`shares_perm`). Over ℝ this needs Mathlib
  (`Real.exp`), which the Lake project in `../../specs` doesn't have (it uses
  Veil's `v4.35.0-veil-no-mathlib`). So the theorems are over any field (Lean
  core's `Lean.Grind.Field`) with a function `E` such that `E (x + y) = E x *
  E y` and `E x ≠ 0`: `Real.exp` is one, and with Mathlib the real theorems are
  these with `Real.exp_add` and `Real.exp_ne_zero`. They also assume the
  softmax's denominator isn't zero (in ℝ, `exp` is positive).
- Proved in Veil (`SplitAttention.lean`, 132 obligations, any number of keys,
  chunks and simdgroups): every key is read once, by the simdgroup whose next
  place it is, and none past `p0`; every key has been read when `att_merge`
  starts; each chunk's record is written once and added once by the merge,
  after it was written; reads are from the key's slot, inside the context (the
  ring's slots, as `Ring.lean` proves). Its assumptions about where keys are
  (their chunk, simdgroup and place, how many each simdgroup reads) are the
  chunk arithmetic, proved in `SoftmaxMerge.lean` (`chunk_owner`,
  `chunk_disjoint`, `strided_repr`, `strided_unique`, `strided_len`).
- Not covered by these: rounding. `check-gpu` covers the floats: with
  `:split-attention` on, one token at position 1,030 (1,031 keys, past the
  1,024 where the split starts; the session filled on the CPU), 4,422,314
  values compared stage by stage against the CPU, none beyond tolerance; the
  global visits' attention outputs at most 0.98 of their tolerance. The same
  token with the split off gives different differences in two global visits,
  so the split kernels ran.

### The residual stream's bookkeeping (`Stream.lean`, `StreamProof.lean`, `inkling-specs.stream`)

`cpu.cpp` keeps the stream's blocks, partial sum, prelude and previous pass by
value; `metal.mm` keeps them in numbered slots taken from a free list. The
model runs both side by side.

- Properties: the slot version reads the values the by-value version reads
  (`reads_agree`, `prelude_kept`), never reads a released slot or writes one
  that is still a block, a message source or the prelude
  (`no_read_after_release`, `no_write_to_live_slot`), has slots left
  (`slots_enough`), and its lists fit the kernels' parameters (`sources_fit`,
  `previous_fit`).
- Proved (`StreamProof.lean`, 598 obligations): for every plan the engine
  runs on the GPU, at any number of layers, blocks, loop passes and slots. The
  plan is the theory; of the block boundaries the proof uses only that the
  loop starts on one (`parse_config` requires it). `metal_open`'s count of
  blocks, previous sources and live slots is ghost state, updated where
  `metal_open` updates it, and the run stops where `metal_open` would refuse
  the plan, so the properties are about the plans that run. Each property is
  a ghost boolean, checked at the read, write, take or restart it is about.
  The invariants relate the two versions' lists and contents, the free list
  (a stack: free slots at distinct positions, every position below its size
  taken) and the engine's count (`live = 1 + blocks + previous`), and track
  where the prelude's slot is (the partial sum until the loop's first layer
  pushes it, then that block). Run on Inkling 2 Mini's plan, the proof's model
  ends in one state, after the output, with the plan accepted
  (`proof-instance`): its assumptions aren't empty.
- Model checked (`Stream.lean`): the run of a plan is deterministic, so a
  check covers that plan completely. Inkling 2 Mini's plan (24 layers, blocks
  of 6, layers 6 to 17 three times; 265 states) has no violation, and needs 7
  of the engine's 12 slots. So do 108 other plans of the same kind.
- The engine's checks of a plan (`parse_config`'s and `metal_open`'s, copied
  in `harness.hpp`) against the model, on 415 plans with loops of every
  alignment: every plan the engine would run on the GPU is without violation
  in the model (`engine-against-model`).
- Engine, `conformance`: the model's events for the engine's plan (slots
  taken, pushed, released, restarted from, read and written, with their
  visits) are the events `metal_forward` records in `session::events`, in
  order, for a single token and for a chunk of 20.

### The thread pool (`Pool.lean`, `PoolProof.lean`, `inkling-specs.pool`)

`pool::run`, `pool::work`, `pool::worker_loop` and `~pool`, with every access
to a shared variable as a step.

- Properties: no worker touches a job after its `run` returned
  (`no_use_after_scope`); the task runs at most once per index
  (`at_most_once`) and on every index before `run` returns
  (`all_ran_at_return`); every run of the program ends, the destructor
  included (no reachable state without a step other than the end).
- Proved (`PoolProof.lean`, 957 obligations, any number of workers, indices,
  chunk size and runs): the four properties, for the engine's pool as it is
  now (sequentially consistent hand-off, `seen` from construction). There the
  two counters are sets: `active` is the set of workers between announce and
  retire, `remaining` the indices not yet finished (each worker adds and later
  subtracts 1, each chunk is subtracted once after its task, so the counters
  are those sets' sizes); the solver can't count, and the proof needs their
  relation with what the threads are doing. "No stuck state" is about each
  state having a step; it says nothing about runs that go on forever.
- Model checked, with the counters themselves (`Pool.lean`): 2 workers and 3
  indices in chunks of 1 or 2, two runs and the destructor at any point
  (236,113 and 101,297 states); 3 workers, 2 indices, one run.
- The model keeps the pool's two earlier versions as variants, and still tells
  them apart (see Findings).
- Engine: `churn` makes and destroys pools at once, and with a job in
  between; `stress-in-subprocess` runs 20,000 jobs of random sizes and grains
  on 3 workers, several times, each in a jank process of its own, and counts
  the jobs after which some index wasn't processed exactly once.

### The session API (`inkling-specs.session`)

No model of its own. A script of `eval!`, `reset!`, `copy!` and `trace!` on
two sessions, against a reference in jank (a session is its list of tokens):
after every operation the position and tokens agree, and at the end each
session's state equals a new session's given the same tokens (bit for bit on
the CPU, by distance on the GPU and when the `:gpu` option is flipped before
every operation). `edges`: `eval!` past the context, `copy!` between contexts,
`sample` without logits, and token ids outside the vocabulary all throw and
leave the session as it was.

### The router (`Router.lean`, `RouterWeights.lean`, `inkling-specs.router`)

Per token, an expert's score is `sigmoid(logit) + bias`, a banned expert's
(`ban-experts!`) `-inf`, and the first `k` in the order "higher score, or
equal and lower index" are chosen; their weights are their `sigmoid(logit)`,
normalized and times the route scale.

- Proved (`Router.lean`, 14 obligations, any number of experts and `k`): the
  chosen experts are distinct, come before every other in that order, and a
  banned one is chosen only when every allowed one is. In Lean
  (`RouterWeights.lean`): the weights add up to the route scale (normalized,
  to 1), over any field, when the `sigmoid`s' sum isn't zero.
- Not provable as asked, "never a banned one": `ban-experts!` doesn't limit
  how many are banned, and with more than `experts - k` banned the choice must
  include banned experts. The model with that property gives a counterexample
  (3 experts, 2 banned, `k = 2`: `banned-chosen`).
- Engine (CPU, 6 tokens, every visit, 288 routes, from the routing captures):
  without bans, and with layer 8's first choices banned, every route has `k`
  distinct experts, no unchosen expert scores above a chosen one, they are in
  order, banned ones aren't chosen, and the weights add up to the route scale
  within 1.4e-6 (each within 6e-7 of the formula). With all but 7 of layer 8's
  experts banned, each of layer 8's 18 routes chooses one banned expert (the
  counterexample on the engine), and the other rules still hold.

### The session API's model (`SessionApi.lean`, `inkling-specs.session-model`)

One action per outcome of a call: `eval` (1 or 2 ids; past the context, or
with an id outside the vocabulary, it throws and changes nothing; both checks
before any id is evaluated), `reset`, `copy` (throws between contexts),
`sample` (throws without logits), `generate!` of 2 tokens (throws at once
without logits; with one position left it evaluates the first token and then
throws, keeping it).

- Proved (48 obligations, any number of sessions, tokens and contexts): a
  session's position never passes its context, and it has logits exactly when
  its position isn't 0, so `sample` and `generate!` succeed exactly when the
  session has evaluated a token since it was made or reset.
- Engine (CPU): 6 random runs of 16 steps of the model on three sessions of
  contexts 3, 3 and 4, a kind of call chosen first (every kind came up but
  `generate!` with no position left): each call threw exactly when the model's
  action is a throwing one, and afterwards every session's position, logits
  and tokens were the model's (tokens kept in jank as the actions say). And
  `generate!` of 2 with one position left throws and keeps one token.

## Findings

Found with these models and tests, and fixed in the engine since:

1. **A worker could use a job after `run` returned.** `run` stored null in
   `current` and then read `active`; a worker added to `active` and then read
   `current`; all with release and acquire orders, which don't order a store
   before a later load of another variable. The built library had `stlur` then
   `ldapur`, which the processor may reorder. The model with `weak` finds it
   in 22 steps; the stress test under jank ended with a segmentation fault in
   `worker_loop` (calling the task of a dead job), and a standalone build of
   the same loop hung. Fixed by making the four operations sequentially
   consistent (`fixed seq_cst` in the model).
2. **The destructor could wait forever.** A worker's first statement was
   `seen = generation.load()`; a thread that started after the destructor's
   increment never saw the generation change, and slept while the destructor
   joined it. `{ inkling::pool p{ 3 }; }` hung at the first try. The model had
   16 states without a step that weren't the end. Fixed by taking `seen` when
   the pool makes the thread (`fixed seen_at_construction`).
3. **Unchecked assumptions of the Metal bookkeeping**, none of them broken by
   Inkling 2 Mini's plan: a loop starting inside a block made the Metal
   version add into the prelude's slot; a loop over more than two blocks read
   past `vec_params::prev`; more than five blocks overflowed
   `vec_params::src`. `parse_config` now refuses loops that don't cover whole
   blocks, and `metal_open` leaves the other plans to the CPU.
4. **`sample` without logits returned token 0, and `eval` didn't check token
   ids.** Both throw now.

Found with these models and tests, not fixed yet (recorded in
`jankifier/todo.md`):

5. **Banned experts can be chosen.** With more than `experts - k` experts of a
   layer banned, the router's top `k` includes banned ones, with a normal
   weight (`router/engine-routing {:ban {8 (range 121)}}`: all 18 routes of
   layer 8 choose one).
6. **`generate!` isn't atomic.** It is `sample` then `eval!`, `n` times; when
   the context fills first, it has evaluated the tokens that fit when the next
   `eval!` throws, the session keeps them, and the exception loses the ids it
   generated.
7. **`copy` of a session onto itself** calls `memcpy` with the same source and
   destination, which is undefined behaviour (harmless in practice; read, not
   run).

Checked and found right: `copy` of a ring that has wrapped (the first
`min(slots, pos)` rows are all it needs, proved); the ring's size; the
convolutions' histories; the slot reuse for the model's plan.

## Limits

- `StreamProof.lean` is about the plans the engine runs on the GPU; the ones
  it refuses or leaves to the CPU are `Stream.lean`'s (model checked).
- `PoolProof.lean` has the pool's two counters as sets (see above); the
  counters themselves are only model checked. The pool's models take the
  engine's remaining release and acquire accesses (`generation`, the job's
  `remaining`) as immediately visible; only the hand-off is modelled under
  weak memory.
- `SoftmaxMerge.lean` and `RouterWeights.lean` are over any field with an
  exponential-like `E`, not over ℝ (Mathlib isn't available); floats are for
  `check-gpu`.
- The router model takes the choice as `k` picks of the first remaining
  expert; that `std::partial_sort` and the Metal kernel's ranks give the same
  experts is by reading (the comparator is a strict total order), and is
  checked on the engine's CPU path only (the GPU was in use by other work).
- The models say which values are read and written, not what is computed from
  them: a wrong coefficient order in a convolution, for instance, is for
  `inkling check` to find, not for these.
- The ring's reads are tested in visit 0 only (the other visits' inputs depend
  on attention, so one token changes every key); the other visits use the same
  kernel with the same parameters.
- `harness.hpp`'s `plan_verdict` is a copy of the engine's two plan checks, to
  be kept in step with `model.cpp` and `metal.mm`.
