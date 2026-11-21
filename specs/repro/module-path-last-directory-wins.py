#!/usr/bin/env python3
"""RESULTS.md M2.

`loader.hpp`: "the first match for a module in the module path is the one
taken". When two directories have the same module, `register_entry`
overwrites the first entry with the later one, so the last directory wins.

    python3 module-path-last-directory-wins.py
"""
import os
from _setup import jank_args, lines, run_jank, scratch_dir, write

w = scratch_dir("repro-m2-")
a, b = os.path.join(w, "a"), os.path.join(w, "b")
os.makedirs(a)
os.makedirs(b)
write(os.path.join(a, "lib.jank"), '(ns lib)\n(defn which [] "a")\n')
write(os.path.join(b, "lib.jank"), '(ns lib)\n(defn which [] "b")\n')
write(os.path.join(a, "app.jank"),
      '(ns app (:require [lib]))\n(defn -main [& _] (println "expected a, with --module-path a:b, lib is from:" (lib/which)))\n')
print(lines(run_jank(jank_args([a, b], os.path.join(w, "build")) + ["run-main", "app"], w)[1]))
