#!/usr/bin/env python3
"""Conformance of jank's dynamic bindings and futures with
JankSpecs/Concurrency/Bindings.lean.

Generates jank programs from scenarios (sequences of the model's actions),
runs them with `jank run`, and turns what they print into traces of the model,
which `JankSpecs/Conformance/BindingsReplay.lean` checks. The scenarios are the
counterexamples the model checker printed in the build log, and random ones.

    python3 conformance/concurrency/bindings.py [--random N] [--seed S]

How actions map to jank, on the main thread:

- push v / pop: `(binding [*x* :vV] ...)`; bindings nest, so the program opens
  and closes them in order.
- spawn f i: `(future (body f))`; the body records its thread id (the OS's
  `pthread_self`) first, then returns `*x*`. The model's `i` is the real id,
  numbered in the order the program sees ids (the main thread's is 0).
- finish f: the body returning; it's placed right before the deref, since
  only the future itself reads its thread's frames.
- cancel f: the body sleeps after recording its id, the program waits for the
  id, then calls `future-cancel`.
- deref f: `@f`, printing what it returned.
"""

import argparse
import json
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPECS = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from jank_harness import dump, run_jank, scratch_dir  # noqa: E402

MAX_THREADS = 7   # futures 1..7 (Th := Fin 8)
MAX_TIDS = 6      # OS ids 0..5 (Tid := Fin 6)

PRELUDE = r'''(ns bindings-scenario (:include "pthread.h" "unistd.h"))
(cpp/raw "inline long jank_spec_tid() { return (long)(uintptr_t)pthread_self(); }")
(def ^:dynamic *x* :v0)
(def tids (atom {}))
(defn body [f slow?]
  (swap! tids assoc f (cpp/jank_spec_tid))
  (when slow? (cpp/usleep 4000000))
  *x*)
(defn wait-for-tid [f]
  (while (nil? (get @tids f)) (cpp/usleep 1000)))
(println "EV main" (cpp/jank_spec_tid))
'''


def program(actions):
    """The jank program for `actions` (spawn without its tid, which is
    observed). Returns the program text."""
    cancelled = {a[1] for a in actions if a[0] == "cancel"}
    lines = [PRELUDE]
    depth = 0
    for a in actions:
        ind = "  " * depth
        if a[0] == "push":
            lines.append(f"{ind}(binding [*x* :v{a[1]}]")
            lines.append(f'{ind}  (println "EV push {a[1]}")')
            depth += 1
        elif a[0] == "pop":
            depth -= 1
            lines.append(f'{"  " * depth}  (println "EV pop"))')
        elif a[0] == "spawn":
            f = a[1]
            slow = "true" if f in cancelled else "false"
            lines.append(f"{ind}(def f{f} (future (body {f} {slow})))")
            lines.append(f'{ind}(wait-for-tid {f})')
            lines.append(f'{ind}(println "EV spawn {f}" (get @tids {f}))')
        elif a[0] == "cancel":
            f = a[1]
            lines.append(f"{ind}(future-cancel f{f})")
            lines.append(f'{ind}(println "EV cancel {f}")')
        elif a[0] == "deref":
            f = a[1]
            lines.append(f'{ind}(println "EV deref {f}" (pr-str @f{f}))')
        # finish isn't a statement: it's the body returning.
    while depth > 0:
        depth -= 1
        lines.append(f'{"  " * depth}  (println "EV pop"))')
    return "\n".join(lines) + "\n"


def trace_of(actions, out):
    """Turns the program's events into model steps, numbering real thread ids.
    Raises ValueError if the program's events don't match the actions."""
    events = [l.split()[1:] for l in out.splitlines() if l.startswith("EV ")]
    if not events or events[0][0] != "main":
        raise ValueError("no main thread id")
    ids = {events[0][1]: 0}
    steps = []
    finished = set()
    cancelled = set()
    for ev in events[1:]:
        kind = ev[0]
        if kind == "push":
            steps.append((["push", int(ev[1])], None))
        elif kind == "pop":
            steps.append((["pop"], None))
        elif kind == "spawn":
            f, real = int(ev[1]), ev[2]
            if real not in ids:
                ids[real] = len(ids)
            steps.append((["spawn", f, ids[real]], None))
        elif kind == "cancel":
            steps.append((["cancel", int(ev[1])], None))
            cancelled.add(int(ev[1]))
        elif kind == "deref":
            f = int(ev[1])
            if f not in finished and f not in cancelled:
                steps.append((["finish", f], None))
                finished.add(f)
            v = ev[2]
            steps.append((["deref", f], ("deref", None if v == "nil" else int(v.lstrip(":v")))))
    if len(ids) > MAX_TIDS:
        raise ValueError(f"{len(ids)} thread ids, more than the replay instance has")
    return steps


def lean_steps(name, steps):
    def label(l):
        return "(." + " ".join(str(x) for x in l) + ")" if len(l) > 1 else f".{l[0]}"

    def obs(o):
        if o is None:
            return ".none"
        return ".deref none" if o[1] is None else f".deref (some {o[1]})"
    body = ",\n    ".join(f"({label(l)}, {obs(o)})" for l, o in steps)
    return f'#eval checkTrace "{name}" [\n    {body}]\n'


def counterexamples(log):
    """The counterexamples the model checker printed (`violationIsError
    false`) in the build log of Bindings.lean."""
    out = {}
    for m in re.finditer(r"❌ Violation: safety_failure \(violates: (\w+)\)\n((?:  .*\n)+)", log):
        acts = []
        for name, args in re.findall(r"State \d+ \(via (\w+)(?:\(([^)]*)\))?\):", m.group(2)):
            if name != "init":
                acts.append([name] + ([int(kv.split("=")[1]) for kv in args.split(", ")] if args else []))
        out.setdefault(m.group(1), acts)
    return out


def random_scenario(rng, length):
    acts, depth, next_f = [], 0, 1
    live, done, slow = [], [], []
    while len(acts) < length:
        c = rng.choices(["push", "pop", "spawn", "deref", "cancel", "redo"], [3, 2, 4, 4, 1, 1])[0]
        if c == "push" and depth < 2:
            acts.append(["push", rng.choice([1, 2])])
            depth += 1
        elif c == "pop" and depth > 0:
            acts.append(["pop"])
            depth -= 1
        elif c == "spawn" and next_f <= MAX_THREADS and len(live) < MAX_TIDS - 2:
            acts.append(["spawn", next_f])
            live.append(next_f)
            next_f += 1
        elif c == "deref" and live:
            f = live.pop(rng.randrange(len(live)))
            acts.append(["deref", f])
            done.append(f)
        elif c == "cancel" and next_f <= MAX_THREADS and len(live) < MAX_TIDS - 2:
            f = next_f
            next_f += 1
            acts += [["spawn", f], ["cancel", f], ["deref", f]]
            done.append(f)
        elif c == "redo" and done:
            acts.append(["deref", rng.choice(done)])
    for f in live:
        acts.append(["deref", f])
    return acts


def normalize_cex(acts):
    """A model counterexample as program actions: spawns lose their thread id
    (the OS picks it) and finishes are implied."""
    out = []
    for a in acts:
        if a[0] == "spawn":
            out.append(["spawn", a[1]])
        elif a[0] != "finish":
            out.append(a)
    spawned = {a[1] for a in out if a[0] == "spawn"}
    dereffed = {a[1] for a in out if a[0] == "deref"}
    out += [["deref", f] for f in sorted(spawned - dereffed)]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--random", type=int, default=30)
    ap.add_argument("--length", type=int, default=12)
    ap.add_argument("--seed", type=int, default=1)
    ns = ap.parse_args()

    build = subprocess.run(["lake", "build", "JankSpecs.Concurrency.Bindings"], cwd=SPECS,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    cexs = counterexamples(build.stdout)
    scenarios = [(f"cex-{k}", normalize_cex(v)) for k, v in cexs.items()]
    rng = random.Random(ns.seed)
    scenarios += [(f"random-{ns.seed}-{i}", random_scenario(rng, ns.length)) for i in range(ns.random)]

    work = scratch_dir("bindings-")
    traces, problems = [], []
    for name, acts in scenarios:
        src = program(acts)
        path = os.path.join(work, name + ".jank")
        with open(path, "w") as f:
            f.write(src)
        rc, out = run_jank(["run", path], work, timeout=300)
        try:
            if rc != 0:
                raise ValueError(f"jank exited with {rc}:\n{out[-1500:]}")
            steps = trace_of(acts, out)
            traces.append(lean_steps(name, steps))
            print(f"== {name}: {len(steps)} steps", flush=True)
        except ValueError as e:
            problems.append((name, str(e)))
            print(f"== {name}: {e}", flush=True)
        dump(os.path.join(work, name + ".json"), {"actions": acts, "out": out})

    gen = os.path.join(SPECS, "JankSpecs", "Conformance", "BindingsTraces.lean")
    with open(gen, "w") as f:
        f.write("-- Generated by conformance/concurrency/bindings.py: traces of the real jank.\n"
                "import JankSpecs.Conformance.BindingsReplay\n\nopen Bindings.Replay\n\n"
                + "\n".join(traces))
    p = subprocess.run(["lake", "build", "JankSpecs.Conformance.BindingsTraces"], cwd=SPECS,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    names = set(re.findall(r'#eval checkTrace "([^"]+)"', "\n".join(traces)))
    conforms = [c for c in re.findall(r"(\S+): conforms \((\d+) steps\)", p.stdout) if c[0] in names]
    failures = re.findall(r"error: .*?: (\S+): (step .*)", p.stdout)
    print(f"\n== replay against the model ({work})")
    for name, n in conforms:
        print(f"   {name}: conforms ({n} steps)")
    for name, why in failures:
        print(f"   {name}: DOES NOT CONFORM: {why}")
    for name, why in problems:
        print(f"   {name}: not run: {why[:300]}")
    ok = len(conforms) == len(traces) and not failures and not problems
    if p.returncode != 0 and not failures:
        print(p.stdout[-3000:])
        ok = False
    print("\nOK" if ok else "\nFAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
