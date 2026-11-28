# bomsom

Sound from jank. SuperCollider's server (`libscsynth`, from
[supercollider-sys](../supercollider-sys)) runs inside the jank process on the audio device,
and the REPL drives it with the server's own commands
([Server Command Reference](https://doc.sccode.org/Reference/Server-Command-Reference.html)).
There's no abstraction over them yet.

## Setup

```sh
cd ../supercollider-sys && lein install   # once, and after changing it
cd ../bomsom && lein run                  # an A for a second at amp 0.1; `lein run 0` is silent
```

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
;; ["/status.reply 1 4 1 1 1 0.065 0.361 44100.0 44100.0" "/synced 3"]

(b/stop!)
```

`send!` sends any command: integers go as OSC int32, other numbers as float32, strings and
keywords as strings. `sync!` waits until the server has done everything sent before; loading a
SynthDef or reading a sound file takes a moment, and a synth started before that fails with
"SynthDef not found". `replies!` and `log!` return the server's replies and what it printed
since the last call (its printouts also go to the process's stdout, in CIDER the
`*nrepl-server*` buffer).

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
