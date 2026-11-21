#!/usr/bin/env python3
"""Conformance of jank's module loader with JankSpecs/ModuleCache.lean.

Runs scenarios, sequences of the model's actions, on the real jank, records
what jank shows at each step, and checks every recorded trace against the model
with `JankSpecs/Conformance/ModuleCacheReplay.lean`.

The scenarios are the counterexamples the model checker prints in
ModuleCache.lean's build log, and random ones. It also checks, in that log,
that `#check_invariants` proved `deps_loaded` and `loaded_has_code`.

    python3 conformance/module_cache/run.py [--random N] [--seed S] [--only NAME]

How each action runs:

- editSrc / deleteSrc / deleteObj / touchSrc / tieSrcToObj change files. Every
  mtime is set from the model's clock (`BASE + clock` seconds), so jank compares
  the same times as the model.
- startRun starts `jank repl` (its nREPL server); load is then
  `(require 'm)`, or `(require 'm :reload)` when `m` is already loaded.
- A compile (startCompile, its loads, stop) is one `jank compile-module`, for
  the last module it loads; the object files it writes get the clock's next
  times, in load order, as in the model.
- Each module prints `LOAD <module> dir=<d> v= <version> aot= <bool>` (and,
  for `app`, `lib-macro= <version>`) when it loads; errors are classified by
  their message.
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
from jank_harness import Server, dump, jank_args, run_jank, scratch_dir  # noqa: E402

MODS = ["lib", "app"]
DEPS = {"app": "lib"}
DIRS = ["a", "b", "build"]
BUILD = 2
BASE = 1_000_000_000
LOAD_RE = re.compile(r"LOAD (\w+) dir=(\w+) v= (\d+) aot= (true|false)(?: lib-macro= (\d+))?")


class Nonconformance(Exception):
    pass


def failing_module(text):
    """The module a load error is about."""
    m = re.search(r"The module `([\w-]+)` could not be found", text) or \
        re.search(r"The registered module `([\w-]+)` has no source files", text) or \
        re.search(r"/(\w+)\.jank` does not exist", text) or \
        re.search(r"/(\w+)\.jank\"\]", text)
    return m.group(1) if m and m.group(1) in MODS else None


def classify_error(text):
    if "last_write_time" in text:
        return "fsError"
    if "unable-to-open-file" in text or "does not exist" in text:
        return "missingFile"
    if "binary-without-source" in text or "has no source files" in text:
        return "noSource"
    if "module-not-found" in text or "could not be found" in text:
        return "notFound"
    return None


class Run:
    def __init__(self, name):
        self.name = name
        self.w = scratch_dir(f"mc-{name}-")
        for d in DIRS[:2]:
            os.makedirs(os.path.join(self.w, d))
        self.build = os.path.join(self.w, "build")
        self.args = jank_args([os.path.join(self.w, d) for d in DIRS[:2]], self.build, "v")
        self.clock = 0
        self.next_ver = 1
        self.procs = {}
        self.steps = []  # [label, obs] (obs filled in later for compiles)
        self.log = []

    # Files.

    def src(self, d, m):
        return os.path.join(self.w, DIRS[d], MODS[m] + ".jank")

    def obj(self, d, m):
        assert d == BUILD, "object files are only in the build directory"
        return os.path.join(self.build, "v", MODS[m] + ".o")

    def set_time(self, path, t):
        os.utime(path, (BASE + t, BASE + t))

    def write_src(self, d, m, v):
        mod = MODS[m]
        dep = DEPS.get(mod)
        req = f" (:require [{dep}])" if dep else ""
        extra = f' "{dep}-macro=" ({dep}/ver)' if dep else ""
        with open(self.src(d, m), "w") as f:
            f.write(f"(ns {mod}{req})\n"
                    f"(defmacro ver [] {v})\n"
                    f"(defmacro aot? [] (boolean clojure.core/*compile-files*))\n"
                    f'(println "LOAD {mod} dir={DIRS[d]} v=" (ver) "aot=" (aot?){extra})\n')

    def record(self, label, obs=("none",)):
        self.steps.append([label, obs])
        return len(self.steps) - 1

    def do_editSrc(self, d, m):
        assert d != BUILD
        self.clock += 1
        self.write_src(d, m, self.next_ver)
        self.set_time(self.src(d, m), self.clock)
        self.next_ver += 1
        self.record(["editSrc", d, m])

    def do_deleteSrc(self, d, m):
        os.remove(self.src(d, m))
        self.record(["deleteSrc", d, m])

    def do_deleteObj(self, d, m):
        os.remove(self.obj(d, m))
        self.record(["deleteObj", d, m])

    def do_touchSrc(self, d, m):
        self.clock += 1
        self.set_time(self.src(d, m), self.clock)
        self.record(["touchSrc", d, m])

    def do_tieSrcToObj(self, ds, dob, m):
        t = os.stat(self.obj(dob, m)).st_mtime_ns
        os.utime(self.src(ds, m), ns=(t, t))
        self.record(["tieSrcToObj", ds, dob, m])

    # Processes.

    def do_startRun(self, p):
        server = Server(self.w, self.args)
        self.procs[p] = {"kind": "run", "server": server, "conn": server.connect(timeout=300),
                         "loaded": set()}
        self.record(["startRun", p])

    def do_startCompile(self, p):
        objs = {m: self.obj_stamp(m) for m in range(len(MODS))}
        self.procs[p] = {"kind": "compile", "loads": [], "objs": objs}
        self.record(["startCompile", p])

    def obj_stamp(self, m):
        path = self.obj(BUILD, m)
        if not os.path.exists(path):
            return None
        st = os.stat(path)
        return (st.st_mtime_ns, st.st_size, st.st_ino)

    def load_obs(self, m, out, err):
        lines = [l for l in LOAD_RE.findall(out)]
        self.log.append({"module": MODS[m], "out": out, "err": err[-2000:]})
        if lines:
            mods = [l[0] for l in lines]
            if mods != [MODS[m]]:
                raise Nonconformance(f"loading {MODS[m]} loaded {mods}")
            mod, d, v, aot, lib_ver = lines[0]
            return ("loaded", DIRS.index(d), int(v), aot == "true", int(lib_ver or 0))
        kind = classify_error(err)
        if kind is None:
            raise Nonconformance(f"loading {MODS[m]}: no LOAD line and an unknown error:\n{err[-1500:]}")
        return ("failed", kind)

    def do_load(self, p, m):
        proc = self.procs[p]
        if proc["kind"] == "run":
            mod = MODS[m]
            code = f"(require '{mod} :reload)" if m in proc["loaded"] else f"(require '{mod})"
            r = proc["conn"].eval(code, timeout=300)
            obs = self.load_obs(m, r["out"], r["err"] + "".join(r["ex"]))
            if obs[0] == "loaded":
                proc["loaded"].add(m)
            self.record(["load", p, m], obs)
        else:
            idx = self.record(["load", p, m], None)
            proc["loads"].append((m, idx))

    def do_stop(self, p):
        proc = self.procs.pop(p)
        if proc["kind"] == "run":
            proc["server"].stop()
        else:
            self.run_compile(proc)
        self.record(["stop", p])

    def run_compile(self, proc):
        """One `jank compile-module` for the compile's last module. Its steps
        are what jank did: the modules it loaded (their `LOAD` lines, in
        order), then the module its error names, if it failed; they replace
        the planned load steps."""
        loads = proc["loads"]
        if not loads:
            return
        target = MODS[loads[-1][0]]
        rc, out = run_jank(self.args + ["compile-module", target], self.w)
        self.log.append({"compile": target, "rc": rc, "out": out[-3000:]})
        p = self.steps[loads[0][1]][0][1]
        observed = []
        for mod, d, v, aot, lib_ver in LOAD_RE.findall(out):
            observed.append([["load", p, MODS.index(mod)],
                             ("loaded", DIRS.index(d), int(v), aot == "true", int(lib_ver or 0))])
        if rc != 0:
            kind = classify_error(out)
            failed = failing_module(out)
            if kind is None or failed is None:
                raise Nonconformance(f"compile of {target} failed with an unknown error:\n{out[-1500:]}")
            observed.append([["load", p, MODS.index(failed)], ("failed", kind)])
        first = loads[0][1]
        planned = {idx for _, idx in loads}
        self.steps = ([s for i, s in enumerate(self.steps[:first]) if i not in planned] + observed +
                      [s for i, s in enumerate(self.steps[first:], first) if i not in planned])
        # The object files it wrote get the clock's next times, in load order.
        for label, obs in observed:
            m = label[2]
            if obs[0] == "loaded" and self.obj_stamp(m) != proc["objs"][m]:
                self.clock += 1
                self.set_time(self.obj(BUILD, m), self.clock)

    def finish(self):
        """Ends the compiles still open (a counterexample can end inside
        one), which is when they run."""
        for p, proc in list(self.procs.items()):
            if proc["kind"] == "compile":
                self.do_stop(p)

    def enabled(self, a):
        """The model's `require`s which the files and processes show."""
        name, *args = a
        if name in ("deleteSrc", "touchSrc"):
            return os.path.exists(self.src(*args))
        if name == "deleteObj":
            return os.path.exists(self.obj(*args))
        if name == "tieSrcToObj":
            ds, dob, m = args
            return os.path.exists(self.src(ds, m)) and os.path.exists(self.obj(dob, m))
        if name in ("startRun", "startCompile"):
            return args[0] not in self.procs
        if name == "stop":
            return args[0] in self.procs
        if name == "load":
            p, m = args
            proc = self.procs.get(p)
            if proc is None:
                return False
            loaded = proc["loaded"] if proc["kind"] == "run" else {x for x, _ in proc["loads"]}
            if proc["kind"] == "compile" and m in loaded:
                return False
            return all(MODS.index(d) in loaded for k, d in DEPS.items() if k == MODS[m])
        return True

    def run(self, actions, skip_disabled=False):
        try:
            for a in actions:
                if not self.enabled(a):
                    if skip_disabled:
                        continue
                    raise AssertionError(f"{a} isn't enabled")
                getattr(self, "do_" + a[0])(*a[1:])
            self.finish()
        finally:
            for p, proc in list(self.procs.items()):
                if proc["kind"] == "run":
                    proc["server"].stop()


# Lean output.

def lean_label(label):
    return "(." + " ".join(str(x) for x in label) + ")"


def lean_obs(obs):
    if obs[0] == "none":
        return ".none"
    if obs[0] == "loaded":
        _, d, v, aot, lv = obs
        return f"(.loaded {d} {v} {'true' if aot else 'false'} {lv})"
    return f"(.failed .{obs[1]})"


def lean_trace(name, steps):
    body = ",\n    ".join(f"({lean_label(l)}, {lean_obs(o)})" for l, o in steps)
    return f'#eval checkTrace "{name}" [\n    {body}]\n'


# Scenarios.

def build_log():
    p = subprocess.run(["lake", "build", "JankSpecs.ModuleCache"], cwd=SPECS,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p.returncode, p.stdout


def counterexamples(log):
    """The counterexamples the model checker printed (`violationIsError
    false`) in ModuleCache.lean's build log, as action lists."""
    out = {}
    for m in re.finditer(r"❌ Violation: safety_failure \(violates: (\w+)\)\n((?:  .*\n)+)", log):
        acts = []
        for name, args in re.findall(r"State \d+ \(via (\w+)(?:\(([^)]*)\))?\):", m.group(2)):
            if name != "init":
                acts.append([name] + ([int(kv.split("=")[1]) for kv in args.split(", ")] if args else []))
        out.setdefault(m.group(1), acts)
    return out


def proved(log, names=("deps_loaded", "loaded_has_code")):
    """Whether `#check_invariants` proved `names` for initialization and every
    action."""
    i = log.find("Initialization must establish the invariant:")
    if i < 0:
        return False
    table = log[i:log.find("\n", log.find("tieSrcToObj", i) + 400)]
    rows = re.findall(r"^\s+(\w+) \.\.\. (\S+)", table, re.M)
    results = [r for n, r in rows if n in names]
    return bool(results) and all(r == "✅" for r in results)


def random_scenario(rng, length):
    """A random sequence of actions which the model allows (its `require`s),
    with compiles run as one block."""
    src = set()      # (d, m)
    objs = set()     # m
    procs = {}       # p -> set of loaded modules
    actions = []

    def add(a):
        actions.append(a)

    while len(actions) < length:
        choice = rng.choices(["edit", "touch", "delete", "tie", "compile", "start", "load", "stop"],
                             [5, 1, 1, 1, 3, 2, 5, 1])[0]
        d, m = rng.randrange(2), rng.randrange(2)
        if choice == "edit":
            add(["editSrc", d, m])
            src.add((d, m))
        elif choice == "touch" and (d, m) in src:
            add(["touchSrc", d, m])
        elif choice == "delete":
            if rng.random() < 0.5 and (d, m) in src:
                add(["deleteSrc", d, m])
                src.discard((d, m))
            elif m in objs:
                add(["deleteObj", BUILD, m])
                objs.discard(m)
        elif choice == "tie" and (d, m) in src and m in objs:
            add(["tieSrcToObj", d, BUILD, m])
        elif choice == "compile":
            free = [p for p in range(2) if p not in procs]
            if free:
                p = rng.choice(free)
                add(["startCompile", p])
                add(["load", p, 0])
                if rng.random() < 0.6:
                    add(["load", p, 1])
                add(["stop", p])
                objs.update({0, 1})  # possibly; only used to enable actions
        elif choice == "start":
            free = [p for p in range(2) if p not in procs]
            if free:
                p = rng.choice(free)
                add(["startRun", p])
                procs[p] = set()
        elif choice == "load" and procs:
            p = rng.choice(sorted(procs))
            if m == 1 and 0 not in procs[p]:
                m = 0
            add(["load", p, m])
            procs[p].add(m)  # may have failed; the replay checks what happened
        elif choice == "stop" and procs:
            p = rng.choice(sorted(procs))
            add(["stop", p])
            del procs[p]
    return actions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--random", type=int, default=20)
    ap.add_argument("--length", type=int, default=14)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--only")
    ns = ap.parse_args()

    rc, log = build_log()
    if rc != 0:
        print(log[-3000:])
        sys.exit(1)
    cexs = counterexamples(log)
    print(f"model: counterexamples for {sorted(cexs)}; deps_loaded and loaded_has_code proved: {proved(log)}")
    # Counterexamples whose violation isn't visible in their last step get the
    # steps that show it: M2's index picks `b`, which a load shows; M3's REPL
    # misses the object file the compile wrote, which shows once the compile
    # ends and the REPL loads the module.
    show = {"m2_first_match_wins": [["load", 0, 0]],
            "m3_index_sees_new_objects": [["stop", 1], ["load", 0, 0]]}
    scenarios = [(f"cex-{k}", v + show.get(k, [])) for k, v in cexs.items()]
    rng = random.Random(ns.seed)
    scenarios += [(f"random-{ns.seed}-{i}", random_scenario(rng, ns.length)) for i in range(ns.random)]
    if ns.only:
        scenarios = [s for s in scenarios if s[0] == ns.only]

    traces, results = [], []
    for name, actions in scenarios:
        run = Run(name)
        print(f"== {name}: {len(actions)} actions", flush=True)
        try:
            run.run(actions, skip_disabled=name.startswith("random"))
            status = "ran"
        except Nonconformance as e:
            status = f"nonconformance: {e}"
        except AssertionError as e:
            status = f"error: {e}"
        dump(os.path.join(run.w, "trace.json"),
             {"name": name, "actions": actions, "steps": run.steps, "log": run.log, "status": status})
        print(f"   {status} ({run.w})", flush=True)
        results.append((name, status))
        if status == "ran":
            traces.append(lean_trace(name, run.steps))

    gen = os.path.join(SPECS, "JankSpecs", "Conformance", "ModuleCacheTraces.lean")
    with open(gen, "w") as f:
        f.write("-- Generated by conformance/module_cache/run.py: traces of the real jank.\n"
                "import JankSpecs.Conformance.ModuleCacheReplay\n\n"
                "open ModuleCache.Replay\n\n" + "\n".join(traces))
    p = subprocess.run(["lake", "build", "JankSpecs.Conformance.ModuleCacheTraces"], cwd=SPECS,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    names = set(re.findall(r'#eval checkTrace "([^"]+)"', "\n".join(traces)))
    conforms = [c for c in re.findall(r"(\S+): conforms \((\d+) steps\)", p.stdout) if c[0] in names]
    failures = re.findall(r"error: .*?: (\S+): (step .*)", p.stdout)
    print("\n== replay against the model")
    for name, n in conforms:
        print(f"   {name}: conforms ({n} steps)")
    for name, why in failures:
        print(f"   {name}: DOES NOT CONFORM: {why}")
    other = [r for r in results if r[1] != "ran"]
    for name, status in other:
        print(f"   {name}: {status}")
    ok = len(conforms) == len(traces) and not failures and not other and proved(log) and len(cexs) == 5
    if p.returncode != 0 and not failures:
        print(p.stdout[-4000:])
        ok = False
    print("\nOK" if ok else "\nFAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
