# inkling

An inference engine for [Inkling 2 Mini](https://huggingface.co/thinkingmachines)
(Thinking Machines' `Inkling2LoopForConditionalGeneration`, 26.4B parameters,
text only here), written to be run and inspected from jank.

- C++ with a Metal backend, no dependencies. The model, its tensors, a
  session's caches and every intermediate value of a forward pass are plain
  C++ structs (`include/inkling/inkling.hpp`) that jank includes directly.
- A session keeps its caches, so a conversation never reprocesses its prefix.
- Two paths compute the same thing: a CPU reference written to be read, and
  the GPU kernels. `check-gpu` compares them stage by stage.

The code was written by an AI model (Claude), from the checkpoint's
configuration and tensors and with Ollama's MLX implementation of the model
as the reference for the architecture.

## Status

Measured on an Apple M3 Max (40 GPU cores, 48 GB), 2026-11-23 (Ollama's and
the long-context rows 2026-11-22):

| | inkling | Ollama 0.40.17 (same machine) |
|---|---|---|
| Generation, short context | about 45 tokens/s | about 32 tokens/s (with its draft model) |
| Generation with the draft model (`--dspark 7`), writing code | about 64 tokens/s (3 tokens a forward) | |
| Generation with the draft model, counting to 60 | about 99 tokens/s (6.9 tokens a forward) | |
| Generation, rewriting text of the context, drafts from the context | about 80 tokens/s (5.8 tokens a forward) | not measured |
| Generation at 20,000 tokens of context | about 33 tokens/s | not measured |
| Prompt processing, 3,650 tokens | about 625 tokens/s | about 400 tokens/s (3,400 tokens) |
| CPU reference path | about 8 tokens/s | |

Not done:

- images (the checkpoint's vision encoder);
- a chat template, an HTTP server, samplers beyond temperature, top-p and top-k;
- a prompt is evaluated in chunks of 512 tokens; a chunk runs the routed
  experts by expert (`route_count`, `route_place`, then matrix products over 32 of an
  expert's routes and 64 rows, `gate_up_grouped`, `down_grouped` and their
  MXFP8 versions), so that each expert's weights are read once a chunk: a
  3,652-token prompt went from 176 to 628 tokens/s (with the convolutions a thread a token, the routes grouped by many threads, the small projections as matrix products from 384 tokens, and 128 threads a group for the elementwise kernels). A chunk's sums are not in
  one token's order (as its other matrix products' aren't), so its numbers
  differ from evaluating the tokens one at a time within `gpucheck`'s
  tolerance;
- single-token attention over a long context is split across the keys (the
  global layers' attention in chunks, then merged: `att_split`, `att_merge`)
  from 2,048 tokens on, by default (`:split-attention false` turns it off).
  It passes `check-gpu` (one token at position 1,362: nothing beyond
  tolerance, as the plain kernel), and is proved to compute the same softmax
  (specs/models/SoftmaxMerge.lean). Decoding alone, tokens a second, plain
  against split: 34.0 and 35.9 at 2,000 tokens of context, 26.3 and 35.1 at
  8,000, 19.3 and 33.1 at 20,000;
- only Apple Silicon.

## What was checked

- The tokenizer gives the same ids as Hugging Face `tokenizers` on 16 texts
  (scripts, emoji, combining marks, contractions, white space, special tokens).
- Against Ollama, on three prompts of 60 generated tokens each: the engine's
  most likely token is Ollama's greedy token at 171 of 180 positions on the
  GPU path (173 on the CPU path), and the log-probability of Ollama's token
  differs by 0.002 to 0.03 (median).
  This model amplifies rounding: changing only the summation order of one
  kernel moves the engine's own log-probabilities by up to 0.13, and Ollama
  differs from itself by a mean of 0.03 on the chat-formatted prompt. So the
  comparison bounds the error; it can't show bit equality.
- The GPU path against the CPU path with `check-gpu`: every stage of every
  visit on identical inputs. On a 219-token prompt (4 chunks, 719 million
  values) nothing is beyond tolerance, the quantized values and the chosen
  experts are equal, and every other difference is a single BF16 rounding.
- Models and proofs of the stateful logic (cache ring, residual stream
  bookkeeping, convolution history, thread pool) are in `specs/`.

A 3,400-token prompt (past the 1,024-token window of the local layers) was
only checked by its answer being right, not against a reference.

## Building

`make` needs jank (its clang and libc++ are used, so that the C++ types are
the ones jank sees), Xcode's SDK and Python 3 (for the Unicode table).

```sh
make                       # lib/libinkling.dylib and bin/inkling
```

The model file is made once from a checkpoint: a directory of safetensors
files with `config.json` and the tokenizer files, or a manifest listing
tensor blobs (Ollama's store works as a source):

```sh
bin/inkling convert ~/.ollama/models/manifests/registry.ollama.ai/library/inkling-2-mini/latest models/inkling-2-mini.ink
```

It is 20 GB: the checkpoint's tensors unchanged, page aligned, with the
configuration and tokenizer files embedded.

## Command line

```sh
bin/inkling info models/inkling-2-mini.ink
bin/inkling tokenize models/inkling-2-mini.ink "Hello <|end_message|>"
bin/inkling run models/inkling-2-mini.ink -p "The capital of France is" -n 50
bin/inkling run models/inkling-2-mini.ink -p "..." --cpu            # the reference path
bin/inkling gpucheck models/inkling-2-mini.ink "The capital of France is"
bin/inkling rowcheck models/inkling-2-mini.ink "The capital of France is" 16
bin/inkling tapcheck models/inkling-2-mini.ink "The capital of France is"
bin/inkling bench models/inkling-2-mini.ink 1 2 4 8 16   # milliseconds of a forward over W rows
bin/inkling batchcheck models/inkling-2-mini.ink 8 32    # sessions decoded together, against alone
```

`INK_GPU_PROFILE=1` prints the GPU time of each kernel per forward (every
dispatch then runs alone, so the total is slower than normal). `INK_SKIP=label,label`
(labels as that prints them) leaves those dispatches out, for timing what they
cost in a normal forward (the results are then wrong). `INK_GPU_TIMING=1` prints
each forward's encoding and GPU time, and each draft's.

## Drafting

`speculate` (and `bin/inkling run --draft N`) samples the next token, then
looks for the end of the sequence earlier in it (at least N tokens matching):
the tokens that followed there are a draft, checked with the next token in one
forward over up to 16 rows (`all_logits`), and kept while each equals the
token sampled at its place; the session is rolled back past the first that
doesn't (`truncate`). Each place is sampled with the seed it would have had
one token at a time, so the tokens are the same as without drafts, sampled or
greedy: `rowcheck` checks that each row of one forward is the same bits as a
token evaluated alone, and that rolling back and going on is too.

Rewriting a short piece of code from the context, greedy: 40.0 tokens/s
without drafts, 82.4 with (`--draft 3`, 5.8 tokens a forward); sampled at
temperature 1: 39.3 and 78.7. On text that doesn't repeat the context there is
rarely a draft, and nothing is lost (41.6 and 41.9).

With the checkpoint's draft model (`use_draft_model`, `run --dspark K`,
`draft-model!` from jank), when the context has no match, a small model drafts
up to K tokens from hidden states of the main model (the partial sums entering
visits 5, 23 and 41 and the final norm's output, which the session keeps for
every position: `keep_taps`, checked by `tapcheck`): three layers over a
window of 1,023 positions, then a Markov head that picks the drafts one at a
time (docs/drafting.md; `native/draft.cpp` is the CPU version, the reference;
the GPU version is in `native/metal.mm`). The depth of each check is chosen
from the measured time of each depth and the measured acceptance at each
place (0, plain steps, when drafting doesn't pay). Greedy, 200 tokens, plain
against drafted: a Python function 44.0 and 63.2 tokens/s (3.1 tokens a
forward), a C function 44.5 and 63.8 (3.0), counting to 60 44.4 and 99.0
(6.9), a short story 44.4 and 43.0 (the depth falls to 0; the first checks,
which measure depths 3 and 1, cost a little). A draft takes 7.5 ms at one
token and 8.6 ms at three; a forward over 2 rows costs 6 ms more than over
one, over 8 rows 44 ms more, mostly the routed experts of the extra tokens.
`draftcheck` compares the GPU drafter with the CPU version from the same
hidden states (the same first proposal in 48 of 48, all seven in 47).

The approach follows [oMLX](https://github.com/jundot/omlx)'s for this model:
drafts copied from the context (#5528), verify rows that are the bits of a
decode step, so that drafts never change the output (#5531), its draft model's
cycle (the context ring, the block of an anchor and masks, the Markov head
with the output head folded into it) and its adaptive depth.

## From jank

```sh
jank -I include -L lib -l $PWD/lib/libinkling.dylib --module-path src repl
```

```clojure
(require '[inkling.core :as ink])

(def m (ink/open "models/inkling-2-mini.ink"))
(def s (ink/session m 8192))                ; a sequence of up to 8192 tokens

(ink/eval! s "The capital of France is")
(ink/top s 3)
;=> [{:id 152717, :piece " Paris", :logit 27.3, :logprob -1.32} ...]
(ink/detokenize m (ink/generate! s 20))
```

The model:

```clojure
(ink/config m)                              ; sizes, loop, clips, softcaps
(ink/plan m)                                ; the 48 visits: {:visit :layer :pass :local}
(ink/tensors m)                             ; {:name :dtype :shape :bytes}
(ink/layer m 6)                             ; a layer's weights, by tensor name
(ink/tensor-values m "model.llm.norm.weight" 4)
```

A session, and what an eval computed:

```clojure
(ink/tokens s) (ink/position s) (ink/logits s)
(ink/cache s 12 :keys)                      ; a visit's cache; also :values and the conv histories

(ink/trace! s true)                         ; the next evals run on the CPU and keep
(ink/eval! s " a")                          ; named values of their last token
(ink/trace s "v12.attn.weights")            ; attention of each head of visit 12
(ink/trace s "v12.ffn.experts")

(ink/capture! s true)                       ; every stage of every visit, every token
(ink/eval! s " city")
(ink/captured s 12 :experts 0)              ; visit 12, token 0 of the chunk
(ink/captured s 12 :attended 0)
```

Checking and experiments:

```clojure
(ink/check-gpu s " in France.")             ; => {:ok true, :compared 17468266, :beyond 0, :rows [...]}
(ink/set-option! m :gpu false)              ; everything on the CPU reference
(ink/ablate! m 47 #{:feed-forward})         ; switch parts of a visit off (CPU path)
(ink/ban-experts! m 20 [3 17])              ; experts the router may not choose
(ink/copy! s2 s)                            ; fork a session
```

Several sessions, a token each, in one forward:

```clojure
(ink/eval-batch! [s1 s2 s3] [id1 id2 id3])  ; each as after (ink/eval! s [id]), sooner
```

Each session's rows go through the projections, norms and experts together;
its own cache, convolution histories and attention are its own (the forward
runs in segments of rows by session). `batchcheck` decodes N sessions, at
different positions, one at a time and together, and compares every logit of
every step: the same bits. Decoding 8 sessions together gives about 100-110
tokens/s in all (one session alone: 46), 16 sessions about the same (each row
reads its own experts, so 16 rows cost twice 8). A forward takes 16 sessions at
most: over 16 rows its matrix-product and grouped-expert kernels add in
another order, and the bits would not be each session's alone (larger batches
are made forwards of 16). Sessions that can't share a forward (on the CPU,
keeping every row's logits, capturing, drafting) are evaluated one at a time.

Without asking: evals of one token from different threads, on different
sessions, are made one forward when they meet (`:auto-batch`, on by default).
A token that comes while a forward runs waits, and the next forward takes every
token waiting, so agents each on its own thread share forwards with nothing
changed in them. `batchcheck`'s last part does this with a thread a session:
8 threads 86 tokens/s in all, 32 threads 80, the same bits as alone.

`ink/model-ptr` and `ink/session-ptr` give the C++ objects for direct
interop:

```clojure
(cpp/.-pos (cpp/* (cpp/unbox (:* inkling.session) (ink/session-ptr s))))            ;=> 5
(cpp/.-hidden (cpp/.-cfg (cpp/* (cpp/unbox (:* inkling.model) (ink/model-ptr m))))) ;=> 2304
```

`test/inkling/smoke.jank` runs all of the above.

`tutorial.jank` goes through the whole API a form at a time, with what each
form gave: read and evaluate it in the REPL.

## The window

`viz/` starts the REPL with a window that draws every evaluation as a card
(the `cards` library next to this one):

```sh
(cd ../cards && lein install)     # once
cd viz && ./viz.sh                # its nREPL port in viz/.nrepl-port
```

Connect once the window is open: `lein run` first starts a bare `jank` that
writes the port file too, and the window's REPL writes it again when it
starts.

`(ink/top s 6)` is a bar a token, `(ink/plan m)` the 48 visits by layer and
pass, `(ink/pieces m ids)` a chip a token, `(ink/routing s)` and
`(ink/trace s "v12.attn.weights")` heat maps, `(ink/check-gpu s " text")` the
verdict with the fields that differ, `(ink/logits s)` all of them as a
series. The session last made or worked on (an `eval!`, a `reset!`, a `copy!`
from the REPL; `ink/used-session!` says which) is shown above the cards: where
it is, the end of its text and its next tokens. `(inkling.cards/watch! s)`
chooses one, and `(inkling.cards/generate! s n)` generates with that following
each token. Pinned cards, layouts, handlers and drawing with ImGui itself are
the library's: `../cards/README.md` and its `tutorial.jank`, and section 9 of
this tutorial.

A video goes through the whole tutorial, the editor on the left and the window
on the right: `~/Documents/jankifier/jankifier-inkling-tutorial.mp4` (and
`jankifier-cards-tutorial.mp4` for the library's). They are made by
`~/Documents/jankifier/takes/take.py`, which evaluates the tutorial's forms one
by one in Emacs while the hidden window records itself.

## How it works

The decoder has 24 layers and runs 48 visits: layers 6 to 17 are run three
times, each pass starting again from the stream as it was before the loop and
mixing in the previous pass's output through gated controllers. Sublayers
don't read one residual stream: they read an attention-weighted mix of the
blocks of it finished so far. Attention has no rotary embedding; it uses
learned relative-position logits, a short convolution over time on keys and
values, a sink logit and an output gate. Twenty layers attend to the last
1,024 tokens only. The feed-forward is 128 experts of which 8 are routed per
token; their weights are 4-bit (NVFP4) or 8-bit (MXFP8, the last four
layers), and their inputs are quantized the same way.

`native/cpu.cpp` is that, in order, in plain loops: read it first.

| | |
|---|---|
| `include/inkling/inkling.hpp` | the model, session, cache and capture structs; the API |
| `include/inkling/jank.hpp`, `src/inkling/core.jank` | the jank layer |
| `native/model.cpp` | model file (convert, open), configuration, plan, thread pool |
| `native/tokenizer.cpp` | byte-level BPE, with the pre-tokenizer's split pattern by hand |
| `native/cpu.cpp` | the forward pass on the CPU (the reference), sessions, sampling |
| `native/kernels.metal`, `native/metal.mm` | the forward pass as Metal kernels |
| `native/check.cpp` | `check_gpu`: the GPU against the CPU, stage by stage |
| `native/cli.cpp` | the `inkling` command |
| `tutorial.jank` | the API, a form at a time |
| `viz/` | the REPL with its window: inkling's cards (`src/inkling/cards.jank`) |
| `specs/` | Veil models, proofs and conformance tests of the stateful logic |

### Numerics

Values are FP32, rounded to BF16 where the reference rounds them. Three
things differ from the checkpoint's reference on purpose:

- the caches hold the BF16-rounded keys and values in IEEE halves, so a
  value below 2^-17 in magnitude loses its last bits (both paths do this);
- batches of 16 tokens or more multiply by half-float copies of the
  projection weights, of which 0.02% (those below 7.6e-6) are rounded, by
  less than 3e-8; single tokens and the CPU path use the BF16 weights;
- sums are in the engine's own order.

### Memory

One forward pass runs at a time on a model: evals of its sessions from
different threads wait for each other.

The model file is mapped, not read. On top of it: 1.3 GB of half-float
weight copies once a batch has run; one set of working buffers for the model's
forwards (they run one at a time), with up to 0.5 GB of attention scratch; and
per session, its caches: 8 global visits hold `context` positions of 4 KB each
(270 MB at 8,192 tokens, 8.6 GB at 262,144), and the local visits a ring of
their window and a chunk each (about 230 MB whatever the context).

## Changing a kernel

`check-gpu` (or `bin/inkling gpucheck`) is the test: run it on a one-chunk
prompt and on one longer than 64 tokens, which uses the batched kernels. It
forces the CPU's values into the GPU after every stage, so a failure names
the stage that is wrong. A new rounding point inside a stage needs its own
capture field, or one rounding flip will be amplified past the tolerance.
