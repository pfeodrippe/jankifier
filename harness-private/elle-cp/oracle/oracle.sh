#!/bin/sh
# Starts the Elle oracle on DIR (created if missing). It runs in the foreground; to run it in the
# background: `oracle.sh DIR > oracle.log 2>&1 &`. DIR/ready appears once Elle is loaded;
# `touch DIR/stop` makes it exit. See README.md.
[ $# -eq 1 ] || { echo "usage: $0 DIR" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$1" || exit 1
# A stop or ready file left by an earlier oracle that was killed.
rm -f "$1/stop" "$1/ready"
# headless: loading Elle's plotting code (rhizome) would otherwise start AppKit on macOS.
exec java -Xmx2g -Djava.awt.headless=true -cp "$("$here/classpath.sh")" clojure.main "$here/oracle.clj" "$1"
