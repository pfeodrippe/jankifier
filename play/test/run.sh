#!/usr/bin/env bash
# Builds and runs the frontend's test against the core in vendor/.
set -euo pipefail
cd "$(dirname "$0")/.."
core=vendor/libretro-fceumm
clang++ -std=c++20 -O1 -Iinclude -I$core/src/drivers/libretro/libretro-common/include test/nes_test.cpp -o target/nes_test
./target/nes_test $core/fceumm_libretro.dylib
