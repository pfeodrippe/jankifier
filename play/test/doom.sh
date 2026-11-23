#!/usr/bin/env bash
# Builds and runs the ViZDoom test against the build in vendor/.
set -euo pipefail
cd "$(dirname "$0")/.."
v=vendor/ViZDoom
clang++ -std=c++17 -O1 -I$v/include test/doom_test.cpp $v/build/bin/libvizdoom.a -L/opt/homebrew/lib -lboost_filesystem -lboost_thread -lboost_chrono -o target/doom_test
./target/doom_test "$PWD/$v"
