#!/usr/bin/env python3
"""Conformance of jank's array maps with JankSpecs/Blind/ArrayMap.lean, step
by step.

    python3 conformance/transients/arraymap.py [--programs N] [--seed S]

Random programs of `{}`, `assoc`, `dissoc`, `transient`, `assoc!`, `dissoc!`
and `persistent!` over the keys and values 0 and 1, run on jank; at the end,
every persistent map is printed entry by entry, in the order jank stores them
(`(vec (map vec m))`). `JankSpecs/Conformance/ArrayMapReplay.lean` runs each
program through the model, which must print exactly the same: the same
entries, and the same corruption where the storage is shared.

Programs are built with a copy of the model's steps (below), so that every
step is one the model allows; new objects and arrays take the lowest unused
number, as the replay expects.
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

OBJS, BUFS, SLOTS = 8, 12, 3


class Sim:
    """The model's steps (ArrayMap.lean), to know which steps are allowed."""

    def __init__(self):
        self.objs = {}   # o -> dict(persistent, active, buf, len, cap)
        self.bufs = {}   # b -> [[k, v]] * SLOTS
        self.logical = {}  # o -> what it should hold, {k: v}

    def free_obj(self):
        return next((o for o in range(OBJS) if o not in self.objs), None)

    def free_buf(self):
        return next((b for b in range(BUFS) if b not in self.bufs), None)

    def first(self, o, k):
        d = self.objs[o]
        return next((i for i in range(d["len"]) if self.bufs[d["buf"]][i][0] == k), None)

    def new_empty(self, o, b):
        self.bufs[b] = [[0, 0] for _ in range(SLOTS)]
        self.objs[o] = dict(persistent=True, active=False, buf=b, len=0, cap=0)
        self.logical[o] = {}

    def p_assoc(self, p, k, v, q, b):
        self.logical[q] = {**self.logical[p], k: v}
        src, d = self.bufs[self.objs[p]["buf"]], self.objs[p]
        self.bufs[b] = [list(c) for c in src]
        i = self.first(p, k)
        if i is not None:
            self.bufs[b][i][1] = v
            self.objs[q] = dict(persistent=True, active=False, buf=b, len=d["len"], cap=d["cap"])
        else:
            self.bufs[b][d["len"]] = [k, v]
            self.objs[q] = dict(persistent=True, active=False, buf=b, len=d["len"] + 1,
                                cap=max(d["cap"], d["len"] + 1))

    def p_dissoc(self, p, k, q, b):
        self.logical[q] = {x: y for x, y in self.logical[p].items() if x != k}
        src, d = self.bufs[self.objs[p]["buf"]], self.objs[p]
        self.bufs[b] = [list(c) for c in src]
        i = self.first(p, k)
        n = d["len"]
        if i is not None:
            for j in range(i, n - 1):
                self.bufs[b][j] = list(src[j + 1])
            n -= 1
        self.objs[q] = dict(persistent=True, active=False, buf=b, len=n, cap=d["cap"])

    def to_transient(self, p, t):
        self.logical[t] = dict(self.logical[p])
        d = self.objs[p]
        self.objs[t] = dict(persistent=False, active=True, buf=d["buf"], len=d["len"], cap=d["cap"])

    def t_assoc(self, t, k, v, b):
        self.logical[t][k] = v
        d = self.objs[t]
        i = self.first(t, k)
        if i is not None:
            self.bufs[d["buf"]][i][1] = v
        elif d["len"] < d["cap"]:
            self.bufs[d["buf"]][d["len"]] = [k, v]
            d["len"] += 1
        else:
            self.bufs[b] = [list(c) for c in self.bufs[d["buf"]]]
            self.bufs[b][d["len"]] = [k, v]
            d["buf"] = b
            d["len"] += 1
            d["cap"] = d["len"]

    def t_dissoc(self, t, k):
        self.logical[t].pop(k, None)
        d = self.objs[t]
        i = self.first(t, k)
        if i is not None:
            cells = self.bufs[d["buf"]]
            for j in range(i, d["len"] - 1):
                cells[j] = list(cells[j + 1])
            d["len"] -= 1

    def persistent(self, t, q):
        self.logical[q] = dict(self.logical[t])
        d = self.objs[t]
        d["active"] = False
        self.objs[q] = dict(persistent=True, active=False, buf=d["buf"], len=d["len"], cap=d["cap"])


def random_program(rng):
    sim = Sim()
    labels, forms = [], []
    o, b = sim.free_obj(), sim.free_buf()
    sim.new_empty(o, b)
    labels.append(f".newEmpty {o} {b}")
    forms.append(f"o{o} {{}}")
    for _ in range(rng.randint(3, 12)):
        o, b = sim.free_obj(), sim.free_buf()
        pers = [p for p, d in sim.objs.items() if d["persistent"]]
        act = [t for t, d in sim.objs.items() if d["active"]]
        options = []
        if o is not None and b is not None:
            options += ["passoc", "passoc", "pdissoc"]
        if o is not None:
            options += ["transient", "transient"]
        if act:
            options += ["tassoc", "tassoc", "tassoc", "tdissoc"]
            if o is not None:
                options += ["persistent"]
        if not options:
            break
        k, v = rng.randrange(2), rng.randrange(2)
        choice = rng.choice(options)
        if choice == "passoc":
            p = rng.choice([p for p in pers if sim.objs[p]["len"] < SLOTS] or [None])
            if p is None:
                continue
            sim.p_assoc(p, k, v, o, b)
            labels.append(f".pAssoc {p} {k} {v} {o} {b}")
            forms.append(f"o{o} (assoc o{p} {k} {v})")
        elif choice == "pdissoc":
            p = rng.choice(pers)
            sim.p_dissoc(p, k, o, b)
            labels.append(f".pDissoc {p} {k} {o} {b}")
            forms.append(f"o{o} (dissoc o{p} {k})")
        elif choice == "transient":
            p = rng.choice(pers)
            sim.to_transient(p, o)
            labels.append(f".toTransient {p} {o}")
            forms.append(f"o{o} (transient o{p})")
        elif choice == "tassoc":
            t = rng.choice([t for t in act if sim.objs[t]["len"] < SLOTS] or [None])
            if t is None or b is None:
                continue
            sim.t_assoc(t, k, v, b)
            labels.append(f".tAssoc {t} {k} {v} {b}")
            forms.append(f"_ (assoc! o{t} {k} {v})")
        elif choice == "tdissoc":
            t = rng.choice(act)
            sim.t_dissoc(t, k)
            labels.append(f".tDissoc {t} {k}")
            forms.append(f"_ (dissoc! o{t} {k})")
        else:
            t = rng.choice(act)
            sim.persistent(t, o)
            labels.append(f".persistentT {t} {o}")
            forms.append(f"o{o} (persistent! o{t})")
    pers = sorted(p for p, d in sim.objs.items() if d["persistent"])
    return labels, forms, pers, {p: sim.logical[p] for p in pers}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--programs", type=int, default=500)
    ap.add_argument("--seed", type=int, default=1)
    ns = ap.parse_args()
    rng = random.Random(ns.seed)
    progs = [random_program(rng) for _ in range(ns.programs)]

    work = scratch_dir("arraymap-")
    src = ["(ns arraymap-scenario)"]
    for n, (_, forms, pers, _) in enumerate(progs):
        shown = " ".join(f"[{p} (vec (map vec o{p}))]" for p in pers)
        src.append(f"(let [{' '.join(forms)}] (println \"MAPS {n}\" (pr-str [{shown}])))")
    with open(os.path.join(work, "arraymap_scenario.jank"), "w") as f:
        f.write("\n".join(src) + "\n")
    rc, out = run_jank(["run", "arraymap_scenario.jank"], work, timeout=3600)
    printed = dict(re.findall(r"^MAPS (\d+) (.*)$", out, re.M))
    if rc != 0 or len(printed) != ns.programs:
        print(out[-3000:])
        sys.exit(1)

    checks = []
    corrupted = 0
    for n, (labels, _, pers, logical) in enumerate(progs):
        # jank printed [[o entries] ...]; entries is a vector of [k v].
        maps = re.findall(r"\[(\d+) (\[(?:\[\d+ \d+\] ?)*\])\]", printed[str(n)])
        pairs = ", ".join(f'({o}, "{e}")' for o, e in maps)
        checks.append(f'#eval checkProgram "program-{n}" [{", ".join(labels)}] [{pairs}]\n')
        # A persistent map whose entries aren't what it should hold.
        for o, e in maps:
            got = re.findall(r"\[(\d+) (\d+)\]", e)
            if sorted(got) != sorted((str(k), str(v)) for k, v in logical[int(o)].items()):
                corrupted += 1
                break
    gen = os.path.join(SPECS, "JankSpecs", "Conformance", "ArrayMapObserved.lean")
    with open(gen, "w") as f:
        f.write("-- Generated by conformance/transients/arraymap.py: what the real jank printed.\n"
                "import JankSpecs.Conformance.ArrayMapReplay\n\nopen ArrayMap ArrayMap.Replay\n\n"
                + "".join(checks))
    p = subprocess.run(["lake", "build", "JankSpecs.Conformance.ArrayMapObserved"], cwd=SPECS,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = re.findall(r"(?:info|error): JankSpecs/Conformance/ArrayMapObserved\.lean:\d+:\d+: (.*)", p.stdout)
    bad = [l for l in lines if "conforms" not in l]
    print(f"== {ns.programs} programs ({work})")
    print(f"   programs where jank printed a persistent map with the wrong entries: {corrupted}")
    for l in bad[:10]:
        print("   " + l[:700])
    ok = p.returncode == 0 and len(lines) == ns.programs and not bad
    print(f"   {len(lines) - len(bad)} of {ns.programs} conform")
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
