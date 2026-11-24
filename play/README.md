# play

## Watching the games

```sh
make            # lib/libplay.dylib, once the games in vendor/ are built (below)
./play.sh       # the REPL and its window (or: cider-jack-in with :jack-in-cmd "bash play.sh")
```

Then, in the REPL, one game at a time (each is a card at the top of the window: the game's
picture as it is played, and what a model is told of it):

```clojure
(require '[play.nova :as nova] '[play.wnw :as wnw] '[play.nethack :as nethack] '[play.doom :as doom])

(nova/watch!)  (nova/start!)  (nova/play! 400)        ; Nova the Squirrel, level 1-1
(wnw/watch!)   (wnw/start!)   (wnw/play! 200)         ; Witch n' Wiz, its first room
(nethack/watch!) (nethack/start! 7) (nethack/play! 300)  ; NetHack, seed 7
(doom/watch!)  (doom/start! 7) (doom/play! 400)       ; Doom (Freedoom's MAP01), seed 7

(nova/told)    ; what a model is told now, as text
(nova/stop!)   ; the scripted player stopped
```

`play!` runs a scripted player (Nova: right, jumping over what is in the way; Witch n'
Wiz: at random; NetHack: random steps, answering what it is asked; Doom: turns to an enemy
in view and shoots, else walks and opens doors). A model takes its place through the same
function: `(nova/play! 400 (fn [state] action))`.

What each game tells a model comes from the game itself:
- Nova and Witch n' Wiz: their RAM, at the addresses their builds name (Nova's debug.dbg,
  Witch n' Wiz's labels.txt), and their blocks' meaning from their sources
  (tools/nova_blocks.py, tools/wnw_tiles.py write src/play/nova_blocks.jank and
  src/play/wnw_tiles.jank);
- NetHack: its terminal, its bottom lines' numbers, its last message and its inventory;
- Doom: ViZDoom's game variables and the objects in view, with each one's distance and
  direction.

Games for a model to play through the decision API (see `../todo.md`), each run from C++ so
that jank can drive it in the process:

- NES games: `include/play/nes.hpp` loads a libretro core with dlopen, loads a game, runs
  frames one at a time with the controller's buttons given, and reads back the console's
  RAM, its picture, and its whole state (to go back to it).
- Doom: ViZDoom, a Doom engine made for programs to play it (the player's state, the
  objects in view with their positions, the screen), with Freedoom's free game data, which
  ViZDoom carries (`src/freedoom1.wad`, `src/freedoom2.wad`).
- NetHack: the NetHack Learning Environment's C core (the 24x80 screen, the map's glyphs,
  the messages, the player's stats, the inventory), a step for each key.

All three are built from source in `vendor/`, which this repository doesn't keep.

## A model playing

`play.decide` makes a model a player: the game is told as text, and the model's answer is
scored as each allowed action's name, so it gives a probability for every action and can't
answer anything else (about a second a choice). A player's settings are in an atom, read at
every choice, so they change while a game goes on:

```clojure
(require '[inkling.core :as ink] '[play.decide :as decide] '[play.replay :as replay])
(def m (ink/open "../inkling/models/inkling-2-mini.ink"))

(def p (wnw/model-player m))              ; nova/, wnw/, nethack/, doom/ each have one
(decide/tune! p {:think 800})             ; it thinks up to 800 tokens before each choice
(def team (mapv (fn [i] (wnw/model-player m {:think 800 :seed i})) (range 3)))
(wnw/play-model! team 100 {:combine :vote})   ; a committee: its members think together
```

The settings: `:think` (tokens of thinking first, 0 for none), `:effort`, `:temperature`,
`:style` (how to think, said with the rules; the model's thinking keeps its own way of
writing whatever it is told), `:answer`
(`:scored`, or `:free`: it writes its answer and the first action named is taken),
`:memory` (`:fresh`, each choice from the rules; or `:conversation`, one conversation
started again when the context is nearly full), `:seed`, `:recent` (its last actions it is
told). A committee's members that think do it in one forward a token (`generate-batch!`):
the same thoughts as alone, sooner.

`play.agent` makes the game a harness agent's task: its own conversation, thinking as long as
it likes, and three tools: `look`, `act` (actions in a row, stopped at one that changes
nothing) and `notes` (what it keeps across compactions). A game can name actions that aren't
meant to change anything (`:still`: Nova's attack and wait), and can refuse an action that
only harms, saying why (`:caution`: Nova's step into a pit whose edge is nearer than a step
walks). Its conversation is shown above the game as the harness shows any agent
(`harness.cards`).

```clojure
(require '[play.agent :as agent])
(def run (agent/play! :wnw m {:minutes 10}))   ; a future of the result
```

On Witch n' Wiz from power-on (23 Nov 2026): the agent finished 4 rooms in 10 minutes, a
committee of three thinking players and one thinking player 2 rooms each, and the player
without thinking none in 3 minutes. The decision players start every choice afresh and in
room 3 fell into the same pocket again and again; the agent remembered it.

On Nova the Squirrel's first level (24 Nov 2026, inkling-2-mini, 30 minutes a run, seeds 83
to 102): the level is three areas (the game's intro_a, garden and intro_b; RAM 0xA7 reads 0,
49 and 45), the exit door at x 219 of the third. Every run since seed 98 reached the third
area, the fastest in 9.5 minutes without a death (seed 100); the furthest was x 123.5 there
(seed 86). None reached the exit. What was left: a FIRE_WALK pacing a pen in the first area
(about a hit a run), enemies met in the air after a spring, and a wall at x 113 of the third
area whose way on goes left, down a ladder and under it (the text now gives that way, from a
search of the map; no run has reached it since). The text's advice for each spot came from
playing the recorded runs again from that spot with many plans of actions, and keeping the
plan that worked across them.

How a game is told matters more than how the model is asked: a map of characters makes it
count them, so the levels can also be told as runs of things with their positions
(`(reset! wnw/telling {:map :runs})`, the same for Nova), with what each move from where the
player is would do.

## Recordings and replays

A game played by a model can be kept (`replay/record!`, and `agent/play!` always) in
`~/Documents/jankifier/replay/games/`: each step's action, what the model was told, its
probabilities, votes and thinking, and an agent's conversation beside it. The games are
deterministic, so a replay plays the game again from its start:

```clojure
(replay/open! "/Users/.../wnw-20261123-183740.edn")   ; the game's card, the conversation above it
(replay/play!)      ; an agent's game played on at the game's own pace, its conversation moved
                    ; to each step's call (the conversation's play button does the same)
(replay/play! :conversation)  ; or its conversation's timeline at the agent's own pace: the
                    ; game waits while the agent thinks
(replay/go! 20)     ; to step 20
(replay/stop!)
```

Dragged or stepped by hand, the conversation's timeline takes the game to the actions whose
calls it shows.

The NES's frames are queued and shown at the game's own speed while what plays runs as fast
as it goes (a model never waits for the screen); a jump shows its step at once.

## The core

fceumm, built from source (GPL-2.0; not kept in this repository):

```sh
mkdir -p vendor && cd vendor
git clone --depth 1 https://github.com/libretro/libretro-fceumm.git
cd libretro-fceumm && make -f Makefile.libretro platform=osx -j4   # fceumm_libretro.dylib
```

Built from commit fb919fb6fa881aaa6279b765d480220579e5c606.

## Doom and NetHack

```sh
cd vendor
git clone --depth 1 https://github.com/Farama-Foundation/ViZDoom.git     # GPL-2.0; Freedoom: BSD
git -C ViZDoom apply ../../patches/vizdoom-use-specials.patch
(cd ViZDoom && mkdir build && cd build && cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_PYTHON=OFF && ninja)
git clone --depth 1 https://github.com/NetHack-LE/nle.git                # NetHack General Public License
(cd nle && mkdir build && cd build && cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release && ninja nethack nethackdl rlmain)
```

Built from ViZDoom 9d44650 and NLE 2319f29, with Homebrew's boost and sdl2. ViZDoom's engine
is a program it starts (on macOS `build/bin/vizdoom.app/Contents/MacOS/vizdoom`); link
`build/bin/libvizdoom.a` with boost_filesystem, boost_thread and boost_chrono (the dylib
exports nothing). `patches/vizdoom-use-specials.patch` gives each line the action a player's
use sets off and whether it works from the line's back side (ViZDoom gives a line's ends and
whether it blocks), so that a closed door, a lift, the exit switch and other switches can be
told from a wall, from the side they work from: without it, every sector whose floor meets
its ceiling looked like a door.

## Checking it

`test/run.sh` builds `test/nes_test.cpp` and runs it: it writes a small NES program of its
own (it reads the controller into RAM and counts frames), runs it with buttons held, and
checks the RAM, and that a restored state runs again to the same place.

`test/doom.sh` plays Freedoom's first level a few hundred tics with a fixed plan of
buttons, prints the state as a model would be given it, and plays it again with the same
seed to the same place. `test/nethack.sh` plays three NetHack games of random moves to
their end.

## Games

None are kept here. A game is an iNES file (`.nes`) given to `nes::load`. Free ones, built
from their sources in `vendor/games/`:

- Nova the Squirrel, a platformer (code GPL-3.0, art CC BY-NC 4.0); the closest to Super
  Mario Bros., and its RAM can be read from its sources' labels. A tool-assisted run of it
  exists (TASVideos), to compare with.

  ```sh
  git clone --depth 1 https://github.com/NovaSquirrel/NovaTheSquirrel.git && cd NovaTheSquirrel
  python3 NtS1LevelConvert.py levels
  ca65 src/nova.s -o src/nova.o -l nova.lst -g && ld65 -C src/nova.x src/nova.o -o nova.nes -m map.txt --dbgfile debug.dbg
  ```

- Witch n' Wiz, a puzzle platformer (MIT). Its music and map converters are Windows
  programs and the Tiled editor, so the build uses their output, which its repository
  keeps:

  ```sh
  git clone --depth 1 https://github.com/mhughson/mbh-A53-witchnwiz.git && cd mbh-A53-witchnwiz/game
  # its script wants `python` and `wine` on PATH (wine isn't run with AUDIO=0)
  AUDIO=0 MAPS=0 ./compile_master.sh      # BUILD/main.nes
  ```

- Squirrel Domino, a falling-pill puzzle game for one or two (code zlib; its README asks
  that its background graphics not be reused in other projects), by Nova the Squirrel's
  author. Two models play it against each other (`play.domino`), on the NES's two
  controllers.

  ```sh
  git clone --depth 1 https://github.com/NovaSquirrel/SquirrelDomino.git && cd SquirrelDomino
  ca65 squirrel_domino.s -o squirrel_domino.o -l squirrel_domino.lst -g
  ld65 -C nrom128.x squirrel_domino.o -o squirrel_domino.nes --dbgfile squirrel_domino.dbg
  ```

  Built from commit 96557700ffe3009f7800da3e76abd95af375bb74.

- Super Tilt Bro. (WTFPL), a fighting game for two: not built yet. Its C sources need a 6502
  GCC built from source (gcc-6502-bits) and a fork of the xa assembler; it has no releases
  on GitHub.

`brew install cc65` gives ca65 and ld65. `test/shot.cpp` runs a game with a plan of buttons
and saves its picture every 120 frames (PPM), to see where it is.
