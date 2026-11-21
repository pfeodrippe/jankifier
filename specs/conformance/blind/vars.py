#!/usr/bin/env python3
"""Conformance of jank's vars and `require` with JankSpecs/Blind/Vars.lean and
JankSpecs/Blind/Require.lean, by outcome sets: each program runs many times
in one jank process, and every outcome it shows must be one
`JankSpecs/Conformance/VarsOutcomes.lean` computes from the models. Clojure
runs the same programs, for comparison.

    python3 conformance/blind/vars.py [--runs N]

Programs (futures start together, on a promise):
- three futures `(alter-var-root #'x inc)` from 0: the root (V1);
- two futures `(with-redefs [y 50] ...)` of a var whose root is 3: the root
  afterwards (V5);
- two futures `(defonce dN (do (swap! evals inc) 7))`, on a new var each
  run: how many times the expression ran (V4);
- two futures `(require 'rN)`, on a new lib each run, whose body counts its
  runs (V7);
- once, in a future, `(alter-var-root #'z (fn [v] (alter-var-root #'z inc)
  (inc v)))`: whether it has returned after 3 seconds.
"""

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPECS = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from jank_harness import jank_args, run_jank, scratch_dir  # noqa: E402

COMMON = r'''
(def x 0)
(defn alters []
  (alter-var-root #'x (constantly 0))
  (let [go (promise)
        fs (doall (for [_ (range 3)] (future @go (alter-var-root #'x inc))))]
    (deliver go true)
    (doseq [f fs] @f)
    (str "root=" x)))

(def y 3)
(defn redefs []
  (alter-var-root #'y (constantly 3))
  (let [go (promise)
        fs (doall (for [_ (range 2)] (future @go (with-redefs [y 50] (SLEEP)))))]
    (deliver go true)
    (doseq [f fs] @f)
    (str "root=" y)))

(def evals (atom 0))
(def loads (atom 0))

(doseq [[o n] (frequencies (repeatedly RUNS alters))] (println "ALTERS" o n))
(doseq [[o n] (frequencies (repeatedly RUNS redefs))] (println "REDEFS" o n))
'''

DEFONCE = r'''(let [go (promise) before @evals
      fs (doall (for [_ (range 2)] (future @go (defonce dN (do (swap! evals inc) 7)))))]
  (deliver go true)
  (doseq [f fs] @f)
  (println "DEFONCE" (str "evals=" (- @evals before) " root=" dN)))
'''

REQUIRE = r'''(let [go (promise) before @loads
      fs (doall (for [_ (range 2)] (future @go (require 'rN))))]
  (deliver go true)
  (doseq [f fs] @f)
  (println "REQUIRE" (str "runs=" (- @loads before))))
'''

# jank's `(deref f ms timeout-val)` is a stub returning nil at once, so this
# waits 3 seconds and asks `realized?`.
NESTED = r'''
(def z 0)
(let [f (future (alter-var-root #'z (fn [v] (alter-var-root #'z inc) (inc v))))]
  (WAIT)
  (println "NESTED" (if (realized? f) (str "returned root=" z) "stuck")))
'''


def program(lang, runs, blocks):
    head = ("(ns vars-scenario)\n(cpp/raw \"#include <unistd.h>\")\n(cpp/raw \"#include <cstdio>\")\n"
            if lang == "jank" else "(ns vars-scenario)\n")
    sleep = "cpp/usleep 50" if lang == "jank" else "Thread/sleep 0 50000"
    body = COMMON.replace("RUNS", str(runs)).replace("(SLEEP)", f"({sleep})")
    body += "".join(DEFONCE.replace("dN", f"d{i}") for i in range(blocks))
    body += "".join(REQUIRE.replace("rN", f"r{i}") for i in range(blocks))
    body += NESTED.replace("(WAIT)", "(cpp/usleep 3000000)" if lang == "jank" else "(Thread/sleep 3000)")
    # The nested alter-var-root's thread never ends in jank: leave without
    # waiting for it.
    tail = "(cpp/fflush cpp/stdout)\n(cpp/_exit 0)\n" if lang == "jank" else "(shutdown-agents)\n(System/exit 0)\n"
    return head + body + tail


def outcomes(out, tag):
    found = re.findall(rf"^{tag} (.*?)(?: (\d+))?$", out, re.M)
    counts = {}
    for o, n in found:
        counts[o] = counts.get(o, 0) + (int(n) if n else 1)
    return counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=2000)
    ap.add_argument("--blocks", type=int, default=200, help="defonce and require runs")
    ns = ap.parse_args()
    work = scratch_dir("vars-")
    for i in range(ns.blocks):
        for ext in ("jank", "clj"):
            with open(os.path.join(work, f"r{i}.{ext}"), "w") as f:
                f.write(f"(ns r{i})\n(swap! vars-scenario/loads inc)\n(def a 1)\n(def b 2)\n")
    with open(os.path.join(work, "vars_scenario.jank"), "w") as f:
        f.write(program("jank", ns.runs, ns.blocks))
    with open(os.path.join(work, "vars_scenario.clj"), "w") as f:
        f.write(program("clj", ns.runs, ns.blocks))

    rc, out_j = run_jank(["run", "vars_scenario.jank"] + jank_args(module_path=[work]), work, timeout=3600)
    if not re.search(r"^NESTED", out_j, re.M):
        print(out_j[-3000:])
        sys.exit(1)
    p = subprocess.run(["clojure", "-Sdeps", '{:paths ["."]}', "-M", "vars_scenario.clj"], cwd=work,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=1800)
    out_c = p.stdout

    tags = [("ALTERS", "alterOutcomes", "three futures alter-var-root"),
            ("REDEFS", "redefsOutcomes", "two futures with-redefs"),
            ("DEFONCE", "defonceOutcomes", "two futures defonce"),
            ("REQUIRE", "requireOutcomes", "two futures require"),
            ("NESTED", "nestedOutcomes", "nested alter-var-root")]
    checks = []
    print(f"== jank and Clojure ({work})")
    for tag, fn, label in tags:
        oj, oc = outcomes(out_j, tag), outcomes(out_c, tag)
        print(f"   {label}: jank {oj}; Clojure {oc}")
        observed = "[" + ", ".join(f'"{o}"' for o in oj) + "]"
        checks.append(f'#eval check "{label}" {fn} {observed}\n')

    gen = os.path.join(SPECS, "JankSpecs", "Conformance", "VarsObserved.lean")
    with open(gen, "w") as f:
        f.write("-- Generated by conformance/blind/vars.py: outcomes of the real jank.\n"
                "import JankSpecs.Conformance.VarsOutcomes\n\nopen Vars.Outcomes Require.Outcomes JankSpecs.Outcomes\n\n"
                + "".join(checks))
    pb = subprocess.run(["lake", "build", "JankSpecs.Conformance.VarsObserved"], cwd=SPECS,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = re.findall(r"(?:info|error): JankSpecs/Conformance/VarsObserved\.lean:\d+:\d+: (.*)", pb.stdout)
    print("\n== against the models")
    for l in lines:
        print("   " + l[:400])
    ok = pb.returncode == 0 and len(lines) == len(tags) and all("conforms" in l for l in lines)
    print("\nOK" if ok else "\nFAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
