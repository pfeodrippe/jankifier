# bomsom

Sound from jank. SuperCollider's server (`libscsynth`, from
[supercollider-sys](../supercollider-sys)) runs inside the jank process on the audio device,
and the REPL drives it with the server's own commands
([Server Command Reference](https://doc.sccode.org/Reference/Server-Command-Reference.html)).
There's no abstraction over them yet.

It's jank, except for `include/bomsom/server.hpp`: the two functions the server calls on its own
threads (one for each reply, one for each printout) and the queues and the wait for `/synced`
they share with jank. They're C++ because the server takes C function pointers and because no
jank code should run on its threads (jank's GC doesn't know them). Starting the server, OSC's
encoding and decoding, sending (`World_SendPacket`, called from jank with a `std::vector<char>`
it fills) and SynthDefs are in `bomsom.core`.

## The folders

| | |
|---|---|
| `.` | the library, `jankifier/bomsom` (`bomsom.core`) |
| `viz/` | its cards for the cards window, `jankifier/bomsom-viz` (`bomsom.cards`): the server's counts and CPU, levels, a scope, a spectrum and the synths with a slider for each main control, drawn every frame |
| `example/` | a project that uses them as a dependency, as one's own would: `./run.sh` opens the window, which serves the REPL; connect to it (`cider-connect-clj`, not jack-in: a jacked-in REPL has no window) and evaluate `src/bomsom_example/tutorial.jank` a form at a time |

## Setup

Each library is installed once (and again after changing it), in this order:

```sh
cd ../supercollider-sys && lein install
cd ../cards && lein install
cd ../bomsom && lein install
cd viz && lein install
cd ../example && ./run.sh                 # the window and its REPL; connect an editor
```

`lein run` here starts the server, plays an A for a second at amp 0.1 and stops (`lein run 0`
is silent).

`lein run` starts the server, loads the SynthDef `bomsom-sine`, plays it, prints the server's
replies and stops. The first run builds SuperCollider (about 15 s).

## From the REPL

Jack in from a file in `bomsom/` (CIDER's jack-in, or `lein repl :headless`), then:

```clojure
(require '[bomsom.core :as b])

(b/start!)                       ; the default audio device: 2 outputs, no inputs
(b/load-sine!)                   ; the SynthDef bomsom-sine (controls freq and amp), and waits

(b/send! "/s_new" "bomsom-sine" 1000 0 0 "freq" 330 "amp" 0.1)   ; node 1000, at the head of group 0
(b/send! "/n_set" 1000 "freq" 440)
(b/send! "/n_free" 1000)

(b/send! "/status") (b/sync!) (b/replies!)
;; [["/status.reply" 1 4 1 1 1 0.068 0.358 44100.0 44099.97] ["/synced" 3]]

(b/stop!)
```

`send!` sends any command: integers go as OSC int32, other numbers as float32, strings and
keywords as strings, `(b/blob bytes)` as a blob. `sync!` waits until the server has done
everything sent before; loading a SynthDef or reading a sound file takes a moment, and a synth
started before that fails with "SynthDef not found". `replies!` returns the server's replies
since the last call, each as `[address & args]`, and `log!` what it printed (its printouts also
go to the process's stdout, in CIDER the `*nrepl-server*` buffer).

### What's playing

```clojure
(b/controls 1000)          ; {:freq 330.0, :amp 0.1}: a synth's controls now, nil once it ended
(b/synths)                 ; [{:id 1000 :synthdef "bomsom-sine" :controls {...}} ...]
```

Both ask the server for its node tree (`/g_queryTree` with the controls) and wait for it; the
reply doesn't go to `replies!`. For a few controls, `/s_get` answers with an `/n_set`:
`(b/send! "/s_get" 1000 "freq")`, then `(b/sync!)` and `(b/replies!)`.

### SynthDefs as data

`b/sine` is the SynthDef `bomsom-sine` as jank data, which `b/synthdef-bytes` writes in
SuperCollider's file format (version 2) and `b/load-synthdef!` sends with `/d_recv`:

```clojure
{:name "bomsom-sine"
 :constants [0.0]
 :controls [["freq" 440.0] ["amp" 0.1]]
 :ugens [{:name "Control" :rate :control :inputs [] :outputs [:control :control]}
         {:name "SinOsc" :rate :audio :inputs [[0 0] [:const 0]] :outputs [:audio]}
         {:name "BinaryOpUGen" :rate :audio :special 2 :inputs [[1 0] [0 1]] :outputs [:audio]}
         {:name "Out" :rate :audio :inputs [[:const 0] [2 0] [2 0]] :outputs []}]}
```

An input is `[ugen-index output-index]` or `[:const constant-index]`; a UGen's outputs are their
rates; `:special` is the UGen's special index (for BinaryOpUGen, the operator: 2 is `*`).

Reloading `bomsom.core` keeps the running server. Its C++ (`include/bomsom/server.hpp`) is
compiled once per process: a change to it needs a new REPL.

### Sonic Pi's synths

Compiled SynthDefs load with `/d_load`. Sonic Pi's (121 of them in
`~/dev/vybe/sonic-pi/etc/synthdefs/compiled`) take MIDI notes:

```clojure
(b/send! "/d_load" "/Users/pfeodrippe/dev/vybe/sonic-pi/etc/synthdefs/compiled/sonic-pi-beep.scsyndef")
(b/sync!)
(b/send! "/s_new" "sonic-pi-beep" -1 0 0 "note" 60 "release" 2)
```

`sonic-pi-beep` was tried; a SynthDef that uses UGens outside SuperCollider's own (sc3-plugins)
fails to load, and `(b/log!)` says which.

### Other clients

`(b/start! 57110)` also opens UDP port 57110, so sclang or the IDE can use the same server:
`s = Server.remote(\bomsom, NetAddr("127.0.0.1", 57110));` in the IDE.
