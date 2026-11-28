#!/usr/bin/env bash
# The example's REPL with its window: `./run.sh`, then connect an editor (CIDER's connect, to
# the port in .nrepl-port) and evaluate tutorial.jank. `./run.sh --hidden --record <video.mp4>`
# draws without showing the window. The first start compiles Dear ImGui's packages and
# SuperCollider: as C++17, by the Command Line Tools, and outside jank-build's sandbox
# (ImGui's build asks Homebrew where GLFW is).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
export CXXFLAGS=${CXXFLAGS:--std=c++17}
rm -f .nrepl-port
# With the :local profile: the repository's own bomsom, cards and jankifier sources, not the
# published ones (BOMSOM_PUBLISHED=1 for those).
if [ -n "${BOMSOM_PUBLISHED:-}" ]; then
  exec lein run --disable-sandbox -- "$@"
fi
exec lein with-profile +local run --disable-sandbox -- "$@"
