#!/usr/bin/env bash
# bomsom in a REPL with its window of cards: `./viz.sh`, or `./viz.sh --hidden --record
# <video.mp4>`. Its nREPL port is written to .nrepl-port. supercollider-sys, cards and bomsom come
# from Clojars (or `lein install` in each, for a change not published yet).
# The first start compiles Dear ImGui's packages and SuperCollider: as C++17, by the Command
# Line Tools, and outside jank-build's sandbox (ImGui's build asks Homebrew where GLFW is).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
export CXXFLAGS=${CXXFLAGS:--std=c++17}
rm -f .nrepl-port
exec lein run --disable-sandbox -- "$@"
