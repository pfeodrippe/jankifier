#!/usr/bin/env bash
# The games in a REPL with its window of cards: `./play.sh`, or `./play.sh --hidden` to draw
# without showing it. Its nREPL port is written to .nrepl-port. Build lib/libplay.dylib
# first (`make`, after the games in vendor/: README.md), and install the cards library once
# (`lein install` in ../cards).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
export CXXFLAGS=${CXXFLAGS:--std=c++17}
rm -f .nrepl-port
exec lein run --disable-sandbox -- "$@"
