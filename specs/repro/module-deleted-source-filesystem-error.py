#!/usr/bin/env python3
"""RESULTS.md M4.

A running process indexed `lib` (its source and object file); then the
source is deleted. `(require 'lib)` fails with a C++ filesystem error from
`last_write_time` on the missing source, instead of saying the module (or its
source) can't be found.

    python3 module-deleted-source-filesystem-error.py
"""
import os
from _setup import Server, jank_args, run_jank, scratch_dir, write

w = scratch_dir("repro-m4-")
src = os.path.join(w, "src")
os.makedirs(src)
args = jank_args([src], os.path.join(w, "build"))
write(os.path.join(src, "lib.jank"), "(ns lib)\n(defn hi [] :hi)\n")
run_jank(args + ["compile-module", "lib"], w)
srv = Server(w, args)
try:
    c = srv.connect()
    os.remove(os.path.join(src, "lib.jank"))
    r = c.eval("(require 'lib)", timeout=300)
    print("expected an error saying lib or its source isn't found; jank:", (r["err"] or " ".join(r["ex"])).strip()[:300])
finally:
    srv.stop()
