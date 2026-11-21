#!/usr/bin/env python3
"""Conformance of jank's multimethods with JankSpecs/Blind/Multi.lean.

    python3 conformance/multi/run.py [--programs N] [--seed S]

Random programs of `derive`, `defmethod`, `prefer-method` and calls, over the
dispatch values `:pN/v0` .. `:pN/v3` and `:default` (4), each on its own
multimethod, run in one jank process and in one Clojure process. Every method
returns its dispatch value, so a call shows which method it used, or which
error it threw. `JankSpecs/Conformance/MultiReplay.lean` then checks that every
jank result is one the model allows (over all orders of the method table), and
prints where jank and Clojure differ.

Programs only take steps the model allows (no cyclic `derive`, no conflicting
`prefer-method`), so neither language throws while setting up. The
model checker's counterexamples come first.
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

N = 5          # dispatch values; 4 is :default
DEFAULT = 4

# The model checker's counterexamples (JankSpecs/Blind/Multi.lean).
TARGETED = [
    ("mm1-preference", [("derive", 3, 2), ("defmethod", 0), ("derive", 2, 1), ("defmethod", 2),
                        ("derive", 3, 0), ("prefer", 0, 1), ("call", 3)]),
    ("mm1-order", [("derive", 1, 0), ("derive", 0, 3), ("defmethod", 3), ("defmethod", 0),
                   ("derive", 0, 2), ("defmethod", 2), ("call", 1)]),
    ("like-clojure", [("derive", 3, 2), ("defmethod", 0), ("derive", 2, 0), ("defmethod", 2),
                      ("derive", 2, 1), ("prefer", 0, 1), ("call", 3)]),
]


class Model:
    """The program's state, to keep to steps the model allows."""

    def __init__(self):
        self.isa = {(a, a) for a in range(N)}
        self.methods = set()
        self.prefs = set()

    def prefers(self, x, y):
        return any((x2, y2) in self.prefs
                   for x2 in range(N) if (x, x2) in self.isa
                   for y2 in range(N) if (y, y2) in self.isa)

    def can_derive(self, x, y):
        return x != y and DEFAULT not in (x, y) and (x, y) not in self.isa and (y, x) not in self.isa

    def derive(self, x, y):
        self.isa |= {(a, b) for a in range(N) for b in range(N) if (a, x) in self.isa and (y, b) in self.isa}

    def can_prefer(self, x, y):
        return x != y and (x, y) not in self.prefs and not self.prefers(y, x)


def random_program(rng):
    m = Model()
    steps = []
    for _ in range(rng.randint(3, 9)):
        kind = rng.choice(["derive", "derive", "defmethod", "defmethod", "prefer", "call"])
        if kind == "derive":
            pairs = [(x, y) for x in range(N) for y in range(N) if m.can_derive(x, y)]
            if pairs:
                x, y = rng.choice(pairs)
                m.derive(x, y)
                steps.append(("derive", x, y))
        elif kind == "defmethod":
            free = [k for k in range(N) if k not in m.methods]
            if free:
                k = rng.choice(free)
                m.methods.add(k)
                steps.append(("defmethod", k))
        elif kind == "prefer":
            pairs = [(x, y) for x in range(N) for y in range(N) if m.can_prefer(x, y)]
            if pairs and len(m.prefs) < 2:
                x, y = rng.choice(pairs)
                m.prefs.add((x, y))
                steps.append(("prefer", x, y))
        else:
            steps.append(("call", rng.randrange(N)))
    for _ in range(2):
        steps.append(("call", rng.randrange(N)))
    return steps


def kw(n, v):
    return ":default" if v == DEFAULT else f":p{n}/v{v}"


def program_text(n, steps, catch):
    out = [f"(defmulti f{n} identity)"]
    for i, st in enumerate(steps):
        if st[0] == "derive":
            out.append(f"(derive {kw(n, st[1])} {kw(n, st[2])})")
        elif st[0] == "defmethod":
            out.append(f"(defmethod f{n} {kw(n, st[1])} [_] {st[1]})")
        elif st[0] == "prefer":
            out.append(f"(prefer-method f{n} {kw(n, st[1])} {kw(n, st[2])})")
        else:
            out.append(f'(println "CALL {n} {i}" (try (pr-str (f{n} {kw(n, st[1])})) {catch}))')
    return "\n".join(out)


def classify(text):
    if re.fullmatch(r"\d", text):
        return "default" if int(text) == DEFAULT else f"method {text}"
    if "Multiple methods" in text:
        return "ambiguous"
    if "No method" in text or "does not define a method" in text:
        return "none"
    return "other: " + text[:80]


def results(out):
    res = {}
    for n, i, text in re.findall(r"^CALL (\d+) (\d+) (.*)$", out, re.M):
        res[(int(n), int(i))] = classify(text.strip().strip('"'))
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--programs", type=int, default=200)
    ap.add_argument("--seed", type=int, default=1)
    ns = ap.parse_args()
    rng = random.Random(ns.seed)
    programs = TARGETED + [(f"random-{ns.seed}-{i}", random_program(rng)) for i in range(ns.programs)]

    work = scratch_dir("multi-")
    jank_src = ["(ns multi-scenario)"] + [
        program_text(n, steps, '(catch std.exception e (str (.what e))) (catch :default e "other")')
        for n, (_, steps) in enumerate(programs)]
    clj_src = ["(ns multi-scenario)"] + [
        program_text(n, steps, "(catch Exception e (.getMessage e))")
        for n, (_, steps) in enumerate(programs)]
    with open(os.path.join(work, "multi_scenario.jank"), "w") as f:
        f.write("\n".join(jank_src) + "\n")
    with open(os.path.join(work, "multi_scenario.clj"), "w") as f:
        f.write("\n".join(clj_src) + "\n")

    rc, out_j = run_jank(["run", "multi_scenario.jank"], work, timeout=3600)
    if rc != 0:
        print(out_j[-3000:])
        sys.exit(1)
    p = subprocess.run(["clojure", "-M", "multi_scenario.clj"], cwd=work, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, timeout=1800)
    if p.returncode != 0:
        print(p.stdout[-3000:])
        sys.exit(1)
    rj, rc_ = results(out_j), results(p.stdout)

    checks = []
    for n, (name, steps) in enumerate(programs):
        parts = []
        for i, st in enumerate(steps):
            if st[0] == "derive":
                parts.append(f".derive {st[1]} {st[2]}")
            elif st[0] == "defmethod":
                parts.append(f".defmethod {st[1]}")
            elif st[0] == "prefer":
                parts.append(f".prefer {st[1]} {st[2]}")
            else:
                parts.append(f'.call {st[1]} "{rj[(n, i)]}" "{rc_[(n, i)]}"')
        checks.append(f'#eval checkProgram "{name}" [{", ".join(parts)}]\n')

    gen = os.path.join(SPECS, "JankSpecs", "Conformance", "MultiObserved.lean")
    with open(gen, "w") as f:
        f.write("-- Generated by conformance/multi/run.py: results of the real jank and Clojure.\n"
                "import JankSpecs.Conformance.MultiReplay\n\nopen Multi.Replay\n\n" + "".join(checks))
    p = subprocess.run(["lake", "build", "JankSpecs.Conformance.MultiObserved"], cwd=SPECS,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = re.findall(r"(?:info|error): JankSpecs/Conformance/MultiObserved\.lean:\d+:\d+: (.*)", p.stdout)
    calls = sum(1 for _, steps in programs for st in steps if st[0] == "call")
    differ = [l for l in lines if "jank " in l and "Clojure " in l]
    print(f"== {len(programs)} programs, {calls} calls ({work})")
    for l in lines:
        if "conforms;" in l or "error" in l or "conforms" not in l:
            print("   " + l[:700])
    ok = p.returncode == 0 and len(lines) == len(programs) and all(l.split(": ", 1)[1].startswith("conforms") for l in lines)
    print(f"\n{sum(1 for l in lines if 'conforms' in l)} of {len(programs)} conform; "
          f"{len(differ)} programs where jank and Clojure differ")
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
