#!/usr/bin/env python3
"""RESULTS.md M5.

A REPL loads `lib` from its object file (version 1). The object file is
rebuilt as version 2 elsewhere. `(require 'lib :reload)` finds the new object
file, but `load_o` sees the process already has `jank_load_lib` and calls it
again instead of loading the new file: version 1 runs.

    python3 module-reload-runs-old-object.py
"""
import os
from _setup import Server, jank_args, run_jank, scratch_dir, write

w = scratch_dir("repro-m5-")
src = os.path.join(w, "src")
os.makedirs(src)
args = jank_args([src], os.path.join(w, "build"))
write(os.path.join(src, "lib.jank"), "(ns lib)\n(defn ver [] 1)\n")
run_jank(args + ["compile-module", "lib"], w)
srv = Server(w, args)
try:
    c = srv.connect()
    print("lib's version, loaded from its object file:", c.eval("(require 'lib) (lib/ver)", timeout=300)["value"][-1:])
    write(os.path.join(src, "lib.jank"), "(ns lib)\n(defn ver [] 2)\n")
    run_jank(args + ["compile-module", "lib"], w)
    r = c.eval("(require 'lib :reload) (lib/ver)", timeout=300)
    print("expected 2, after rebuilding lib's object file as version 2 and reloading:", r["value"][-1:])
finally:
    srv.stop()
