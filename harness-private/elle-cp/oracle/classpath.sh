#!/bin/sh
# Prints the classpath of real Elle (jepsen-io/elle, commit 4e359e5): its jars, its compiled Java
# classes and its Clojure source, in the order runner/elle.sh uses.
# deps/classpath.txt was written when the tree was at ~/dev/determinismo-mine-private/lean/elle;
# the sed points its entries at the tree's current place. Set ELLE_HOME to use another tree.
elle=${ELLE_HOME:-/Users/pfeodrippe/lean-work/elle}
printf '%s:%s:%s\n' \
  "$(sed "s#/Users/pfeodrippe/dev/determinismo-mine-private/lean/elle#$elle#g" "$elle/deps/classpath.txt")" \
  "$elle/upstream/target/classes" \
  "$elle/upstream/src"
