#!/usr/bin/env python3
"""RESULTS.md M3.

A running process indexes the module path when it starts, and rebuilds the
index only when a lookup misses. A module it already indexed (its source)
keeps loading from source after an object file for it is compiled
elsewhere, although the object file is newer.

    python3 module-repl-never-sees-new-object.py
"""
import os
from _setup import Server, jank_args, run_jank, scratch_dir, write

w = scratch_dir("repro-m3-")
src = os.path.join(w, "src")
os.makedirs(src)
args = jank_args([src], os.path.join(w, "build"))
write(os.path.join(src, "late.jank"),
      "(ns late)\n(defmacro aot? [] (boolean clojure.core/*compile-files*))\n(defn compiled-ahead? [] (aot?))\n")
srv = Server(w, args)
try:
    c = srv.connect()
    run_jank(args + ["compile-module", "late"], w)
    r = c.eval("(require 'late) (late/compiled-ahead?)", timeout=300)
    print("expected true, late was loaded from the object file compiled after the REPL started:", r["value"][-1:])
finally:
    srv.stop()
