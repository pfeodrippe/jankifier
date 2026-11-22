# harness

An agent's harness written in jank, on the [inkling](../inkling) engine. The
model, the engine and the harness run in one jank process: a tool is a
function of that process, and one of the tools evaluates code in the process's
own nREPL.

The code was written by an AI model (Claude).

**Nothing here is sandboxed.** A tool runs with the process's rights, the
`eval` tool runs whatever code the model writes, and nothing is asked before
either acts. Whoever starts the process decides what it may touch: a
container, a sandboxed shell, another user. The tools are a plain value given
to an agent, so `eval` or `shell` can be left out.

```sh
(cd ../inkling && make)            # the engine, once
(cd ../cards && lein install)      # the window library, once
./harness.sh                       # a REPL with its window; its nREPL port in .nrepl-port
./harness.sh --bench               # the bench instead, no window
./sandbox.sh                       # the same process inside a sandbox (macOS): see below
HARNESS_PROFILES=extras ./harness.sh    # with an HTTP library and Veil for the model's code
```

Connect an editor once the window is open.

```clojure
(require '[inkling.core :as ink] '[harness.core :as h]
         '[harness.tools :as tools] '[harness.cards :as hc])

(def m (ink/open "../inkling/models/inkling-2-mini.ink"))
(def a (hc/watch! (h/agent m {:tools (tools/defaults) :system tools/situation})))

(h/ask! a "How many layers does the model you run on have? Look; don't guess.")
(h/answer a)
;=> "The model has **24 layers** ..."
```

`tutorial.jank` goes through all of it a form at a time, with what each form
gave. `demo.jank` is five sessions, each an agent of its own: a question the
model answers by looking at itself, a simple task, a web server in jank, a
web server in Python written and checked inside the sandbox, and a Veil model
of jank's small maps. The model has not completed the last one: in the attempt
of 2026-11-22 its session filled up before it had written a model, and it had
read finished models of the same storage in `../specs`, which the sandbox lets
it read. As the task stands, completing it wouldn't show that the model can
write one by itself.

## Tools

A tool is a function with a name, a description and parameters.

```clojure
(defn add
  "Adds two integers and returns their sum."
  [^long a ^long b]
  (+ a b))

(h/wrap #'add)                       ; the var's name, docstring and parameters

(h/tool {:name "shout"               ; or a map: :fn gets the arguments as a map
         :doc "Returns a text in capital letters."
         :params {:text {:type "string" :doc "the text"}}
         :fn (fn [{:keys [text]}] (clojure.string/upper-case text))})
```

The model calls a tool with JSON arguments, the form it was trained on. The
harness decodes them and calls the function with plain values, so a tool never
deals with escaping: the text of a file to write reaches `write_file` as the
text itself. What the function returns is what the model reads (a string as it
is, anything else as it prints, cut at the tool's `:limit` characters), and
what it throws is an error the model is told of.

The default tools (`(tools/defaults)`):

| | |
|---|---|
| `eval` | jank code evaluated in this process's nREPL, form by form: what it printed and each form's value (code that doesn't read says where). `str` is clojure.string, `set` clojure.set. Definitions stay |
| `load_file` | a jank file loaded: its forms evaluated in order, or where it fails |
| `functions`, `describe` | what a namespace defines, and one function's parameters and documentation |
| `read_file`, `write_file`, `edit_file`, `list_dir` | files |
| `shell` | a command line, its output and exit code |

`eval` is an evaluation like one from an editor: it sees the engine
(`inkling.core`), this harness, and through `(harness.core/me)` the
conversation it is asked from, as `{:model :session :agent}`. So the model can
be asked about itself and look: its configuration, the order its layers run
in, which experts handled a token. The same functions change it: an ablation
it sets and forgets stays for every later token, and freeing its own session
ends the conversation.

`tools/situation` is a text that tells the model where it is and how to find
out more; give it as `:system`. It points the model at `JANK.md`: notes on
what differs from the Clojure it knows (32-bit integers, no JVM, `format`)
and on calling C++, each line tried in this process. The model reads the file
when a task needs it.

`shell` gives a command 120 seconds (its `timeout`), then kills it with what
it started. A command that leaves something running in the background ends
when the shell does, so a server can be started and then checked.

## An agent

`(h/agent m opts)` is an atom: a session of the model, its tools, and the
conversation.

| Option | |
|---|---|
| `:tools` | tools; none when not given |
| `:system` | what the model is told first |
| `:effort` | how much it thinks: `:none :minimal :low :medium :high :max` (`:high`) |
| `:context` | tokens the session has room for (16384) |
| `:sampling` | as `ink/sample` takes: `{:temperature :top-p :top-k :seed}` (greedy) |
| `:max-tokens` | tokens a step may generate (4096) |
| `:max-thinking` | tokens one stretch of thinking may take (1536): at that the harness closes the thinking, and the model goes on from what it has thought |
| `:max-steps` | steps a turn may take: a step is the model speaking, then its calls (24) |

| | |
|---|---|
| `(h/ask! a text)` | a person's message, and the model's turn started on a thread of its own: returns at once |
| `(h/answer a)` | waits for the turn, gives what the model last said |
| `(h/stop! a)` | ends the turn after the token being made; the conversation can go on |
| `(h/entries a)` | the conversation: `{:role :user/:thinking/:model/:call/:result/:stopped ... :began :ended}` |
| `(h/recording a)`, `(h/save! a path)`, `(h/load-recording path)` | the conversation as plain data, kept in a file, read back |
| `(h/status a)` | `{:state :position :context :generated :seconds :tokens-per-second}` |
| `(h/close! a)` | its session freed |

A turn cut short (by `stop!`, `:max-tokens`, `:max-steps`, a full session)
keeps what was made, and leaves the session well formed so that `ask!`
continues it.

## A sandbox

`./sandbox.sh` starts the same process inside a macOS sandbox (`sandbox-exec`,
rules in `sandbox.sb`). It is an example of the part left to whoever starts
the process, not something the harness does:

- the process and everything it starts (the model's `eval`, the shell's
  commands, a server the model leaves running) can **write** only in the work
  directory (`HARNESS_WORK`, `./work` when not set), the build's own places
  and the system's temporary directories;
- it can reach **over the network** only this machine;
- **reading** is not restricted: the process reads whatever its user can.

Tried inside it: the model runs on the GPU and the bench's mechanics pass; a
write to the home directory is refused ("Operation not permitted") and the
tool says so; `curl https://example.com` gets no connection.

## What the model's code can use

`HARNESS_PROFILES=extras` loads two more things into the process
(`project.clj`'s `:extras` profile), for tasks that need them:

- `httplib.h` (cpp-httplib, from jank-lang/commons): an HTTP server written
  through `eval`, its requests answered by a jank function. `JANK.md` has one
  that was tried.
- `veil.core` (`../veil`, with Lean in-process): models written and model
  checked from `eval`, their counterexamples returned as data. It must be
  required before `httplib.h` is included: a macOS header that comes with
  httplib defines `nil` as a macro, and lean-sys's header then doesn't
  compile.

## The window

`(hc/watch! a "name")` shows the agent above the cards: a line for each
conversation watched, and the one chosen written out as a terminal shows it,
in its type: a person's messages after a prompt, the model's thinking, each
tool's call with what it gave under it, and what the model said with its
headings, lists, tables, code and bold drawn. A long part (thinking, a call's
arguments, what a tool gave) shows its first three lines and how many more
there are: a click on those words shows it whole, and "show less" (over it
and under it) puts it back
(`(hc/unfold! "name" :all)` shows them all whole). While a part is being
written, its last lines are shown. The newest
is at the bottom; a conversation shorter than the space sits at the bottom of
it. Under it is a line of what is going on ("thinking (12 s)", "running
shell"), or the person's message being typed in a replay, and the timeline.
Clicking a conversation's line chooses it. What the model evaluates with
`eval` is a card below, like any evaluation.

The timeline has:

- a mark for each step: a person's message, a tool's call with what it gave,
  an answer of the model's, and a knob where the conversation is shown up to;
- the time since the conversation began, and what was going on then
  ("1:23 running eval");
- play or pause, from the start, to the next step, and the pace (1, 2, 4 or
  8 times).

The whole is small (380 points) and always as tall, whatever the conversation
holds and however many there are (four lines in view, the wheel over them shows
the others): the timeline stays in its place. "expand", at its right, opens it
over the window as a modal, the cards dimmed beneath; "close", Esc or a click
outside puts it back.

While the end is followed, what comes is shown as it comes. The wheel, or the
bar at the conversation's right, looks back: what is looked at then stays put
while it plays or is sought in, until "Jump to latest" (or scrolling to the
end) follows the end again.

While a turn runs, the end is followed as it is written ("live"). Pause stops
the view there, and the turn itself goes on. A click on the line (or the mouse
held and moved along it) goes to that moment, and plays on from there if it was
playing. A click on a mark goes to that step's end and shows the step from its
start; on the last one, or at the line's end, the end is followed. Playing
follows the turn again when it gets to the end.

A replay doesn't take as long as the conversation did. What the model wrote is
shown at up to 500 characters a second, a thought in 2 seconds at most, a
call in 1, an answer in 3 (the model writes about 16 tokens a second: a long
thought took a minute). Waits are shown short and marked on the line with a
break: a tool running, a result being read (1.2 seconds at most each). The
clock says the time as it was.

## A conversation kept

Every entry has its times (`:began`, `:ended`, seconds since the agent was
made), so a conversation is a recording.

```clojure
(h/save! a "work/question.edn")            ; the conversation, as data
(hc/replay! "work/question.edn" "kept")    ; shown and played from its start
```

`replay!` needs no model: a kept conversation can be looked at in a process
that never opened one, on another machine, or after a bench task failed
(`(hc/replay! {:entries (:entries (first @bench/last-run))} "the task")`).
`(hc/seek! "kept" 0.5)`, `(hc/play! "kept")` and `(hc/follow! "name")` do from
code what the timeline's controls do.

## How the conversation is written

The session holds the conversation as the model was trained on it: frames
opened and closed by special tokens.

```
<|message_system|>tool_declare<|content_xml|>[the tools, as JSON]<|end_message|>
<|message_system|><|content_text|>Thinking effort level: 0.9<|end_message|>
<|message_user|><|content_text|>...<|end_message|>
<|message_model|><|content_thinking|>...<|end_message|>
<|message_model|>name<|content_invoke_tool_json|>{"name":"name","args":{...}}<|end_message|>
<|content_model_end_sampling|>
<|message_tool|>name<|content_text|>the result<|end_message|>
<|message_model|><|content_text|>...<|end_message|><|content_model_end_sampling|>
```

A frame's content is always tokenized as ordinary text, and the model's output
is split by token id. So a special token's spelling in a message, a file or a
tool's result is only text, and nothing has to be escaped to keep the frames
apart. The format was read from Ollama's renderer and parser for this model.

The model also has a frame for a call whose body is raw text
(`<|content_invoke_tool_text|>`). It is not used: with the declarations known
here the model always chose the JSON frame (probability 1.0 in the cases
tried, also when told to send raw text), and it wrote JSON even inside a text
frame forced on it. It escapes JSON correctly in what was tried, nested quotes
and a literal backslash-n included.

Only new tokens are evaluated: the session's caches hold the rest, so a turn
costs its own tokens, and a tool's result costs its length (about 160 tokens a
second to read, 30 to 38 to write).

## The bench

```sh
./harness.sh --bench                       # everything; the exit code says
./harness.sh --bench --only write-exact,edit-one-line --effort low
```

```clojure
(bench/mechanics m)      ; the checks that need no generation
(bench/run! m)           ; the tasks: each in an agent of its own
(println (bench/report (bench/run! m {:only ["itself-plan"]})))
(:entries (first @bench/last-run))         ; a task's conversation
```

Two parts (`src/harness/bench.jank`):

- **Mechanics**, without generating anything: JSON read and written, a special
  token's spelling staying text, a call's arguments reaching the function as
  they are, the errors a model is told (unknown tool, missing argument, bad
  JSON, a tool that throws), a long result cut, `eval` with output, errors
  and a C++ compiler's messages, two evaluations at once, recursion 3000
  deep, the file tools (a refused write included), the shell (its time limit,
  a command left in the background).
- **Tasks** for the model, each with a check of its own: an answer without
  tools, tools of one's own, `eval` computing and failing, a function defined
  and kept, a file written byte for byte (quotes, backslashes, the model's own
  special tokens spelled out), one line of a file edited, a line read from a
  long file, a directory listed, a shell command, questions about the model
  itself answered by looking, and a word remembered across turns.

A task passing says the model and the harness did it once, with greedy
sampling. It doesn't say how often a sampled run would.

## Work checked against its model

The harness can refuse to take the model's word that its code works. With
`HARNESS_PROFILES=extras` (Veil in the process):

```clojure
(require '[harness.verify :as verify])
(verify/report (verify/check "examples/parking.jank"))   ; a file that passes

(def a (h/agent m {:tools (conj (tools/defaults) (verify/tool))
                   :system (str tools/situation "\n\n" (slurp "VERIFY.md"))
                   :obligations (verify/gate "work/lru.jank")}))
```

A file checked is a namespace with the code, a Veil model of it
(`veil/defmodel`), assertions (`harness.observe`: `always!`, `sometimes!`,
`reachable!`, `unreachable!`) and a map `verification` tying them: the
model's types' sizes, states the code must be able to reach, how to start a
real system, how each of the model's actions is done on it, and how its state
is seen as the model's. `verify/check` then asks:

1. the model elaborates, keeps its safety properties as far as the checker
   looks, and reaches each state it must;
2. random runs of the real code match the model step by step: each step is one
   the model allows, and after it the real state, seen as the model's, is one
   the model reaches by that step (Veil's executable system says which);
3. the model's own runs to those states, done on the real code, match too;
4. the code's assertions held;
5. copies of the code with a deliberate bug (a comparison turned, `inc` made
   `dec`, a `when` inverted) fail the same checks, at least half of them.

`:obligations` makes this the end of a turn: when the model answers, the gate
checks the file, and if it fails, what failed is said to the model and the turn
goes on (`:max-checks` times at most). The checks are shown in the
conversation, in green or red. `VERIFY.md` is what the model is told, and
`examples/parking.jank` the example it reads.

The trials (`../harness-private/drive.py`, beside their graders) measure
whether this makes code right more often: each task is asked several times,
sampled, with and without the gate, and the code is graded by a reference the
model never sees (random operations against a reference implementation). The
tasks: an LRU cache, a key-value store kept in a log file that recovers from a
crash tearing its last record, and a bounded queue used by several threads at
once (its grader runs producers and consumers together and checks nothing is
lost, given twice or out of order).

A trial must not let the model see what it is graded against, other runs, or
that it is a trial. So each run is a process of its own, started for it and
ended after it, driven from outside over its REPL:

- it works from a directory of its own outside the project, holding only what
  its mode should read (JANK.md and work/; VERIFY.md and examples/ when
  verified), and the file tools refuse the project;
- once the engine, the model and Veil's session are loaded, the process
  sandboxes itself (`harness.tools/confine!`, macOS's `sandbox_init`): under
  the home directory it can read only what compiling needs (the build's cache
  and headers, Lean's toolchain), not the harness's sources or notes, the
  trials or the results; it writes only to its directory, the results and the
  caches; it reaches only this machine. Everything the model's tools start is
  inside the same sandbox. The driver tries reading those places from inside
  before each run;
- only the task's text is sent with the run; the graders are sent once it has
  ended, and the process is ended after grading.

The run in progress is kept in `../trials-out/live.edn` as it goes; another
window follows it: `(hc/follow-file! "../trials-out/live.edn" "live")`.

## What went wrong, across runs

`harness.review` reads a folder of recordings (from outside the sandbox: the
trial's process can't read `../trials-out`) and sorts what happened into kinds,
to decide what is worth fixing: tool errors by what they say (a missing or
misnamed argument, code that doesn't read, an unresolved symbol, a shell's
exit code, a timeout), calls repeated as they were, long looking around before
writing anything, thinking the harness cut, turns stopped short, failed checks
of the gate, and files read outside the run's folder.

```clojure
(require '[harness.review :as review])
(println (review/report "../trials-out"))   ; each kind: how often, in how many runs, an example
(review/look! "../trials-out/lru-plain-1.edn" 35)   ; that run in the window, at entry 35
```

Reading the run around an example is still what says whether a kind is a
problem of the harness, of the task or of the model.

## Two problems of jank's REPL this needed fixed

Both are fixed in the window library (`cards.repl`, loaded here), for every
evaluation of the process, a person's included:

- jank's nREPL evaluates on threads with a 512 KB stack (macOS). jank's
  compiled frames are large, and a function calling itself thirty deep
  overflows it: `(fib 30)` ended the process (SIGBUS). Evaluations, and each
  tool's call, now run on a thread with a 256 MB stack.
- jank captures an evaluation's output by pointing the process's stdout and
  stderr at a file and back. Two evaluations that overlap without one being
  inside the other restore in the wrong order, and the process is left writing
  to a file that is gone. The captures in progress are now kept together.

## Files

| | |
|---|---|
| `src/harness/core.jank` | tools, frames, the agent, the turn |
| `src/harness/tools.jank` | the default tools |
| `src/harness/json.jank`, `include/harness/native.hpp` | JSON, a command run, a directory listed |
| `src/harness/cards.jank` | the conversations in the window |
| `src/harness/bench.jank` | the bench |
| `src/harness/observe.jank` | assertions a program makes about itself |
| `src/harness/verify.jank` | code checked against its Veil model; the `verify` tool and the gate |
| `src/harness/review.jank` | what went wrong across recorded runs, by kind |
| `VERIFY.md`, `examples/parking.jank` | what the model is told of verified work, and its example |
| `src/harness/main.jank` | the process: the window's REPL, or the bench |
| `JANK.md` | notes on jank for the model: what differs from Clojure, calling C++ |
| `sandbox.sh`, `sandbox.sb` | the process inside a macOS sandbox |
| `tutorial.jank` | all of it, a form at a time |
| `demo.jank` | five sessions, from a question to a Veil model |

## Not done

- One model, one machine: only Inkling 2 Mini on Apple Silicon was tried.
- No way to shorten a conversation that fills its session: it stops, saying
  so.
- A tool's call can't be stopped once it runs (`stop!` ends the turn after it).
- Images, and the model's raw-text call frame.
