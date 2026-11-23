# play

An NES emulator in the process, for a model to play games through the decision API
(see `../todo.md`): `include/play/nes.hpp` loads a libretro core with dlopen, loads a game,
runs frames one at a time with the controller's buttons given, and reads back the console's
RAM, its picture, and its whole state (to go back to it).

## The core

fceumm, built from source (GPL-2.0; not kept in this repository):

```sh
mkdir -p vendor && cd vendor
git clone --depth 1 https://github.com/libretro/libretro-fceumm.git
cd libretro-fceumm && make -f Makefile.libretro platform=osx -j4   # fceumm_libretro.dylib
```

Built from commit fb919fb6fa881aaa6279b765d480220579e5c606.

## Checking it

`test/run.sh` builds `test/nes_test.cpp` and runs it: it writes a small NES program of its
own (it reads the controller into RAM and counts frames), runs it with buttons held, and
checks the RAM, and that a restored state runs again to the same place.

## Games

None are kept here. A game is an iNES file (`.nes`) given to `nes::load`.
