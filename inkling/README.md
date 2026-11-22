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

Measured on an Apple M3 Max (40 GPU cores, 48 GB), 2026-11-22:

| | inkling | Ollama 0.40.17 (same machine) |
|---|---|---|
| Generation, short context | 38 to 40 tokens/s | about 32 tokens/s (with its draft model) |
| Generation at 3,400 tokens of context | about 29 tokens/s | not measured |
| Prompt processing, 3,400 tokens | 160 tokens/s | about 400 tokens/s |
| CPU reference path | about 8 tokens/s | |

Not done:

- images (the checkpoint's vision encoder), and the draft model used for
  speculative decoding;
- a chat template, an HTTP server, samplers beyond temperature, top-p and top-k;
- prompt processing is 2.5 times slower than Ollama's: three quarters of it
  is the routed experts, which run one route at a time (running the routes by
  expert, to decode an expert's weights once for several tokens, was tried
  and was slower);
- single-token attention over a very long context: `(ink/set-option! m
  :split-attention true)` splits the global layers' attention across the keys
  and merges the chunks (`att_split`, `att_merge`). It passes `check-gpu` (one
  token at position 1,362: nothing beyond tolerance, as the plain kernel). At
  19,812 tokens it took 480 us a global visit against 2,709 us for the plain
  kernel (profiled while another process used the GPU); at 1,364 tokens it is
  slower (two chunks). Off until it is measured alone at several lengths, to
  choose where it starts;
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
```

`INK_GPU_PROFILE=1` prints the GPU time of each kernel per forward (every
dispatch then runs alone, so the total is slower than normal).

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
weight copies once a batch has run; per session, the caches (8 global visits
hold `context` positions of 4 KB each: 270 MB at 8,192 tokens, 8.6 GB at
262,144) and up to 0.5 GB of attention scratch.

## Changing a kernel

`check-gpu` (or `bin/inkling gpucheck`) is the test: run it on a one-chunk
prompt and on one longer than 64 tokens, which uses the batched kernels. It
forces the CPU's values into the GPU after every stage, so a failure names
the stage that is wrong. A new rounding point inside a stage needs its own
capture field, or one rounding flip will be amplified past the tolerance.
