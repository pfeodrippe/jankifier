# play

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
(cd ViZDoom && mkdir build && cd build && cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_PYTHON=OFF && ninja)
git clone --depth 1 https://github.com/NetHack-LE/nle.git                # NetHack General Public License
(cd nle && mkdir build && cd build && cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release && ninja nethack nethackdl rlmain)
```

Built from ViZDoom 9d44650 and NLE 2319f29, with Homebrew's boost and sdl2. ViZDoom's engine
is a program it starts (on macOS `build/bin/vizdoom.app/Contents/MacOS/vizdoom`); link
`build/bin/libvizdoom.a` with boost_filesystem, boost_thread and boost_chrono (the dylib
exports nothing).

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

- Super Tilt Bro. (WTFPL), a fighting game for two: not built yet. Its C sources need a 6502
  GCC built from source (gcc-6502-bits) and a fork of the xa assembler; it has no releases
  on GitHub.

`brew install cc65` gives ca65 and ld65. `test/shot.cpp` runs a game with a plan of buttons
and saves its picture every 120 frames (PPM), to see where it is.
