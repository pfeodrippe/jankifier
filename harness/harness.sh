#!/usr/bin/env bash
# The harness in a REPL with its window of cards: `./harness.sh`, or `./harness.sh --hidden`
# to draw without showing it. Its nREPL port is written to .nrepl-port; connect once the
# window is open. Build the engine first (`make` in ../inkling) and install the cards library
# once (`lein install` in ../cards). The first start compiles Dear ImGui's packages: as C++17,
# by the Command Line Tools, and outside jank-build's sandbox (its build asks Homebrew where
# GLFW is).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
export CXXFLAGS=${CXXFLAGS:--std=c++17}
rm -f .nrepl-port
# HARNESS_PROFILES=extras adds what project.clj's :extras profile has (an HTTP library, Veil).
# HARNESS_OFFLINE=1 keeps lein from asking a repository for anything.
lein=(lein)
if [ -n "${HARNESS_OFFLINE:-}" ]; then
  lein+=(-o)
fi
if [ -n "${HARNESS_PROFILES:-}" ]; then
  lein+=(with-profile "+$HARNESS_PROFILES")
fi
exec "${lein[@]}" run --disable-sandbox -- "$@"
