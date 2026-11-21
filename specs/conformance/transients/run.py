#!/usr/bin/env python3
"""Conformance of jank's transients with JankSpecs/Blind/Transients.lean, and
a differential test against Clojure.

    python3 conformance/transients/run.py [--programs N] [--seed S]

1. After `persistent!`: for each kind of transient and each operation it has,
   jank runs the operation on a finished transient; whether it threw must be
   what `JankSpecs/Conformance/TransientsCheck.lean` predicts from the model
   (T3 says it should always throw). Clojure's result is printed next to it.
2. Random programs (T1, T2, T4, T5), on vectors, maps (small, so array maps,
   and growing past 8 keys, so hash maps) and sets: two transients made from
   one source, a third from the first result, each with random operations.
   Each program prints the source afterwards, each result, the same
   operations done persistently, and the first result after the third
   transient's operations. Within each language they must agree (the source
   unchanged, each result equal to its persistent version, the first result
   unchanged); and jank must print what Clojure prints.
"""

import argparse
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPECS = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from jank_harness import run_jank, scratch_dir  # noqa: E402

# Kinds, in the order of the model's instance, and a one-element source.
KINDS = [("vector", "[0]"), ("arrayMap", "{0 0}"), ("hashMap", "(zipmap (range 20) (range 20))"),
         ("hashSet", "#{0}"), ("sortedMap", "(sorted-map 0 0)"), ("sortedSet", "(sorted-set 0)")]

# Operations on a finished transient `t`, per kind (the model's `supported`).
MAP_OPS = {"conjOp": "(conj! t [9 9])", "assocOp": "(assoc! t 9 9)", "dissocOp": "(dissoc! t 0)",
           "persistentOp": "(persistent! t)", "countOp": "(count t)", "getOp": "(get t 0)",
           "getFallbackOp": "(get t 0 :nf)", "containsOp": "(contains? t 0)", "findOp": "(find t 0)",
           "callOp": "(t 0)", "callFallbackOp": "(t 0 :nf)"}
SET_OPS = {"conjOp": "(conj! t 9)", "disjOp": "(disj! t 0)", "persistentOp": "(persistent! t)",
           "countOp": "(count t)", "getOp": "(get t 0)", "getFallbackOp": "(get t 0 :nf)",
           "containsOp": "(contains? t 0)", "callOp": "(t 0)", "callFallbackOp": "(t 0 :nf)"}
VEC_OPS = {"conjOp": "(conj! t 9)", "assocOp": "(assoc! t 0 9)", "dissocOp": "(dissoc! t 0)",
           "popOp": "(pop! t)", "persistentOp": "(persistent! t)", "countOp": "(count t)",
           "getOp": "(get t 0)", "getFallbackOp": "(get t 0 :nf)", "nthOp": "(nth t 0)",
           "nthFallbackOp": "(nth t 0 :nf)", "containsOp": "(contains? t 0)", "findOp": "(find t 0)",
           "callOp": "(t 0)"}
OPS = {"vector": VEC_OPS, "arrayMap": MAP_OPS, "hashMap": MAP_OPS, "hashSet": SET_OPS,
       "sortedMap": MAP_OPS, "sortedSet": SET_OPS}


def table_src(catch):
    out = []
    for k, (kind, src) in enumerate(KINDS):
        for op, form in OPS[kind].items():
            out.append(f'(println "AFTER {k} {op}" (try (let [t (transient {src})] (persistent! t) {form} :returned) {catch}))')
    return out


def random_ops(rng, kind, coll):
    """Random operations on `coll` (a Python model of the collection), as
    (transient form, persistent form) pairs, updating `coll`."""
    ops = []
    for _ in range(rng.randint(1, 12)):
        if kind == "vector":
            choice = rng.choice(["conj", "assoc", "pop"] if coll else ["conj", "assoc"])
            if choice == "conj":
                x = rng.randrange(100)
                ops.append((f"(conj! {x})", f"(conj {x})"))
                coll.append(x)
            elif choice == "assoc":
                i, x = rng.randrange(len(coll) + 1), rng.randrange(100)
                ops.append((f"(assoc! {i} {x})", f"(assoc {i} {x})"))
                if i == len(coll):
                    coll.append(x)
                else:
                    coll[i] = x
            else:
                ops.append(("(pop!)", "(pop)"))
                coll.pop()
        elif kind == "map":
            choice = rng.choice(["assoc", "assoc", "dissoc", "conj"])
            k, v = rng.randrange(12), rng.randrange(100)
            if choice == "assoc":
                ops.append((f"(assoc! {k} {v})", f"(assoc {k} {v})"))
            elif choice == "dissoc":
                ops.append((f"(dissoc! {k})", f"(dissoc {k})"))
            else:
                ops.append((f"(conj! [{k} {v}])", f"(conj [{k} {v}])"))
        else:
            x = rng.randrange(12)
            if rng.random() < 0.7:
                ops.append((f"(conj! {x})", f"(conj {x})"))
            else:
                ops.append((f"(disj! {x})", f"(disj {x})"))
    return ops


def program(n, rng):
    kind = rng.choice(["vector", "map", "set"])
    if kind == "vector":
        items = [rng.randrange(100) for _ in range(rng.randrange(5))]
        src = "[" + " ".join(map(str, items)) + "]"
        coll = list(items)
    elif kind == "map":
        keys = rng.sample(range(12), rng.randrange(10))
        src = "{" + ", ".join(f"{k} {rng.randrange(100)}" for k in keys) + "}"
        coll = None
    else:
        src = "#{" + " ".join(map(str, rng.sample(range(12), rng.randrange(6)))) + "}"
        coll = None
    o1 = random_ops(rng, kind, list(coll) if coll is not None else None)
    o2 = random_ops(rng, kind, list(coll) if coll is not None else None)
    # The third transient starts from the first result (for vectors, its
    # contents keep `assoc!` indexes valid).
    o3 = random_ops(rng, kind, vec_after(coll, o1) if kind == "vector" else None)
    t = lambda ops: " ".join(a for a, _ in ops)
    p = lambda ops: " ".join(b for _, b in ops)
    # Within the language: the source still equals its literal (T1), each
    # result equals its persistent version (T2, T5), the first result is
    # unchanged by the third transient (T4).
    return kind, (f'(let [src {src} r1 (persistent! (-> (transient src) {t(o1)})) r1s (pr-str (norm r1))'
            f' p1 (-> src {p(o1)})'
            f' r2 (persistent! (-> (transient src) {t(o2)})) p2 (-> src {p(o2)})'
            f' r3 (persistent! (-> (transient r1) {t(o3)})) p3 (-> r1 {p(o3)})]'
            f' (println "PROG {n}" (and (= src {src}) (= r1 p1) (= r2 p2) (= r3 p3) (= r1s (pr-str (norm r1))))'
            f' (pr-str (mapv norm [src r1 r2 r3]))))')


def vec_after(coll, ops):
    v = list(coll)
    for t, _ in ops:
        if t.startswith("(conj!"):
            v.append(int(t[7:-1]))
        elif t.startswith("(assoc!"):
            i, x = map(int, t[8:-1].split())
            if i == len(v):
                v.append(x)
            else:
                v[i] = x
        else:
            v.pop()
    return v


NORM = "(defn norm [c] (cond (map? c) (into (sorted-map) c) (set? c) (into (sorted-set) c) :else c))"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--programs", type=int, default=500)
    ap.add_argument("--seed", type=int, default=1)
    ns = ap.parse_args()
    rng = random.Random(ns.seed)
    kinds_progs = [program(n, rng) for n in range(ns.programs)]
    kinds = [k for k, _ in kinds_progs]
    progs = [p for _, p in kinds_progs]

    work = scratch_dir("transients-")
    jank_src = ["(ns transients-scenario)", NORM] + table_src("(catch :default _ :threw)") + progs
    clj_src = ["(ns transients-scenario)", NORM] + table_src("(catch Throwable _ :threw)") + progs
    with open(os.path.join(work, "transients_scenario.jank"), "w") as f:
        f.write("\n".join(jank_src) + "\n")
    with open(os.path.join(work, "transients_scenario.clj"), "w") as f:
        f.write("\n".join(clj_src) + "\n")
    rc, out_j = run_jank(["run", "transients_scenario.jank"], work, timeout=3600)
    if rc != 0:
        print(out_j[-3000:])
        sys.exit(1)
    p = subprocess.run(["clojure", "-M", "transients_scenario.clj"], cwd=work, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, timeout=1800)
    if p.returncode != 0:
        print(p.stdout[-3000:])
        sys.exit(1)
    out_c = p.stdout

    # 1. After persistent!, against the model.
    after_j = re.findall(r"^AFTER (\d) (\w+) :(\w+)$", out_j, re.M)
    after_c = {(k, op): r for k, op, r in re.findall(r"^AFTER (\d) (\w+) :(\w+)$", out_c, re.M)}
    print("== after persistent! (jank / Clojure)")
    for k, op, r in after_j:
        if r == "returned":
            print(f"   {KINDS[int(k)][0]} {op}: jank returned, Clojure {after_c.get((k, op), '?')}")
    observed = ", ".join(f"({k}, .{op}, \"{r}\")" for k, op, r in after_j)
    gen = os.path.join(SPECS, "JankSpecs", "Conformance", "TransientsObserved.lean")
    with open(gen, "w") as f:
        f.write("-- Generated by conformance/transients/run.py: what the real jank did.\n"
                "import JankSpecs.Conformance.TransientsCheck\n\nopen Transients Transients.Check\n\n"
                f"#eval checkTable [{observed}]\n")
    pb = subprocess.run(["lake", "build", "JankSpecs.Conformance.TransientsObserved"], cwd=SPECS,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = re.findall(r"(?:info|error): JankSpecs/Conformance/TransientsObserved\.lean:\d+:\d+: (.*)", pb.stdout)
    for l in lines:
        print("   model: " + l[:600])
    table_ok = pb.returncode == 0 and len(lines) == 1 and "conforms" in lines[0]

    # 2. Random programs, within each language and jank against Clojure.
    pj = dict(re.findall(r"^PROG (\d+) (.*)$", out_j, re.M))
    pc = dict(re.findall(r"^PROG (\d+) (.*)$", out_c, re.M))
    cross_bad = [(n, pj.get(str(n)), pc.get(str(n))) for n in range(ns.programs)
                 if pj.get(str(n)) != pc.get(str(n))]
    inner_bad = {lang: [n for n in range(ns.programs) if not (d.get(str(n)) or "").startswith("true ")]
                 for lang, d in (("jank", pj), ("Clojure", pc))}
    print(f"\n== {ns.programs} random programs ({work})")
    for lang, bad in inner_bad.items():
        by_kind = {k: sum(1 for n in bad if kinds[n] == k) for k in ("vector", "map", "set")}
        print(f"   {lang}: source unchanged, results equal to their persistent versions, first result "
              f"unchanged: {ns.programs - len(bad)} of {ns.programs} (failing, by kind: {by_kind})")
    print(f"   jank prints what Clojure prints: {ns.programs - len(cross_bad)} of {ns.programs}")
    for n, sj, sc in cross_bad[:3]:
        print(f"   program {n}:\n     jank    {sj}\n     Clojure {sc}\n     {progs[n][:400]}")
    # jank conforms to the model (the table); the random programs are a
    # differential test, which shows the array map bug (RESULTS.md, A1): it
    # passes when only map programs fail in jank, and every one in Clojure
    # passes.
    only_maps = all(kinds[n] == "map" for n in inner_bad["jank"] + [n for n, _, _ in cross_bad])
    print(f"\nmodel: {'conforms' if table_ok else 'FAILED'}; differential: "
          f"{len(cross_bad)} programs differ from Clojure, {'all on maps' if only_maps else 'NOT only on maps'}")
    ok = table_ok and only_maps and not inner_bad["Clojure"]
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
