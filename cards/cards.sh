#!/usr/bin/env bash
# The window with the generic cards: `./cards.sh`, or `./cards.sh --hidden --record <video.mp4>`.
# Its nREPL port is written to .nrepl-port. The packages it builds on (jank-lang/commons' Dear
# ImGui) are compiled the first time: as C++17 (ImGui's headers; Apple's clang defaults to
# C++98), by the Command Line Tools, and outside jank-build's sandbox (its build asks Homebrew
# where GLFW is).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
export CXXFLAGS=${CXXFLAGS:--std=c++17}
rm -f .nrepl-port
exec lein run --disable-sandbox -- "$@"
