#!/usr/bin/env bash
# The harness inside a sandbox: `./sandbox.sh`, with harness.sh's arguments. An example of the
# sandboxing that is left to whoever starts the process: the model's tools (eval, the shell,
# the file tools) and everything they start can write only in the work directory
# (HARNESS_WORK, ./work when not set) and reach only this machine over the network.
# HARNESS_HIDE, directories and files separated by ':', can't be read at all (a directory's
# files and listing; a directory can still be written): what the model mustn't see, such as the answers a trial
# grades it against, and where trials keep their results. sandbox.sb has the rules. macOS only (sandbox-exec).
set -euo pipefail
cd "$(dirname "$0")"
here=$(pwd -P)
work=${HARNESS_WORK:-$here/work}
mkdir -p "$work" "$here/target" "$HOME/.cache/jank"
work=$(cd "$work" && pwd -P)
# Offline: the build must not ask a repository for anything (the network is closed).
export HARNESS_OFFLINE=1
profile="$here/sandbox.sb"
if [ -n "${HARNESS_HIDE:-}" ]; then
  # The rules, then one more a directory hidden (by its real path: /tmp is /private/tmp).
  profile="$(mktemp -t harness-sandbox).sb"
  cp "$here/sandbox.sb" "$profile"
  IFS=':' read -r -a hidden <<< "$HARNESS_HIDE"
  for d in "${hidden[@]}"; do
    [ -z "$d" ] && continue
    if [ -f "$d" ]; then
      # A file: hidden, and left as it is.
      real="$(cd "$(dirname "$d")" && pwd -P)/$(basename "$d")"
      printf '(deny file-read-data (literal "%s"))\n' "$real" >> "$profile"
    else
      mkdir -p "$d"
      real=$(cd "$d" && pwd -P)
      printf '(deny file-read-data (subpath "%s"))\n(allow file-write* (subpath "%s"))\n' "$real" "$real" >> "$profile"
    fi
  done
fi
exec sandbox-exec \
  -D HOME="$HOME" \
  -D WORK="$work" \
  -D TARGET="$here/target" \
  -D JANK_CACHE="$(cd "$HOME/.cache/jank" && pwd -P)" \
  -D PORT_FILE="$here/.nrepl-port" \
  -f "$profile" \
  "$here/harness.sh" "$@"
