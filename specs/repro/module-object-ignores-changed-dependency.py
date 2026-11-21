#!/usr/bin/env python3
"""RESULTS.md M1.

A module's object file is loaded although it was compiled against an older
version of a dependency: `find` only compares a module's `.o` with its own
source. `app` (which requires `lib` and uses its macro) is compiled; then
`lib` is edited; running `app` loads `lib` from its new source, but `app`
from its old `.o`, with the old macro's expansion. `jank compile-module app`
doesn't fix it: `app` loads from its fresh-looking `.o`, so nothing is
rewritten.

    python3 module-object-ignores-changed-dependency.py
"""
import os
from _setup import jank_args, lines, run_jank, scratch_dir, write

w = scratch_dir("repro-m1-")
src = os.path.join(w, "src")
os.makedirs(src)
args = jank_args([src], os.path.join(w, "build"))
write(os.path.join(src, "lib.jank"), "(ns lib)\n(defmacro ver [] 1)\n")
write(os.path.join(src, "app.jank"),
      "(ns app (:require [lib]))\n(defn seen [] (lib/ver))\n"
      '(defn -main [& _] (println "expected 2, the version of lib\'s macro app runs with:" (seen)))\n')
run_jank(args + ["compile-module", "app"], w)
write(os.path.join(src, "lib.jank"), "(ns lib)\n(defmacro ver [] 2)\n")
print(lines(run_jank(args + ["run-main", "app"], w)[1]))
run_jank(args + ["compile-module", "app"], w)
print("after `jank compile-module app` again:")
print(lines(run_jank(args + ["run-main", "app"], w)[1]))
