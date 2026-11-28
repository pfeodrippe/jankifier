#!/usr/bin/env bash
# inkling in a REPL with its window of cards: `./viz.sh`, or `./viz.sh --hidden` to draw
# without showing it (for snapshots). Its nREPL port is written to .nrepl-port. Build the
# engine first (`make` in the directory above), and install the cards library once
# (io.github.pfeodrippe/cards, from Clojars). The first start compiles Dear ImGui's packages: as
# C++17, by the Command Line Tools, and outside jank-build's sandbox (its build asks Homebrew
# where GLFW is).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
export CXXFLAGS=${CXXFLAGS:--std=c++17}
rm -f .nrepl-port
exec lein run --disable-sandbox -- "$@"
