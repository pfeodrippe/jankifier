#!/usr/bin/env bash
# The harness inside a sandbox: `./sandbox.sh`, with harness.sh's arguments. An example of the
# sandboxing that is left to whoever starts the process: the model's tools (eval, the shell,
# the file tools) and everything they start can write only in the work directory
# (HARNESS_WORK, ./work when not set) and reach only this machine over the network.
# sandbox.sb has the rules. macOS only (sandbox-exec).
set -euo pipefail
cd "$(dirname "$0")"
here=$(pwd -P)
work=${HARNESS_WORK:-$here/work}
mkdir -p "$work" "$here/target" "$HOME/.cache/jank"
work=$(cd "$work" && pwd -P)
# Offline: the build must not ask a repository for anything (the network is closed).
export HARNESS_OFFLINE=1
exec sandbox-exec \
  -D HOME="$HOME" \
  -D WORK="$work" \
  -D TARGET="$here/target" \
  -D JANK_CACHE="$(cd "$HOME/.cache/jank" && pwd -P)" \
  -D PORT_FILE="$here/.nrepl-port" \
  -f "$here/sandbox.sb" \
  "$here/harness.sh" "$@"
