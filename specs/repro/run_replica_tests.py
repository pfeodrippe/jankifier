"""Runs the tests of the Lean replica of jank (repros.md, "Found by a Lean replica of jank") on
one jank, each test in its own process, and says which pass.

    JANK=~/.local/bin/jank-main python3 run_replica_tests.py TESTS_DIR [PREFIX ...]

TESTS_DIR is determinismo-workloads' workloads/jank-interop/lean/tests. Each test asserts
Clojure's result, so it fails on a jank which has the finding and passes on one which doesn't.
A test runs as `$JANK --module-path . run-main run-one -- NS TEST` from a copy of TESTS_DIR (one
per worker: some tests write files beside themselves), under en_US.UTF-8 as the tests ask,
with REPLICA_LIMIT seconds (default 180) and REPLICA_WORKERS at once (default 4). PREFIXes
(`d09`, `v12`, ...) run only the tests whose name starts with one of them followed by `-`.

Each test's output is kept in ../conformance/out/replica-runs/BUILD/NS.TEST.txt (BUILD as in
run_all.py), and BUILD.json beside it has {ns/test: outcome}: pass, fail (an assertion failed or
errored), exit N (the process ended otherwise: a crash, an abort), or timeout.
"""
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

from run_all import JANK, build_name

HERE = os.path.dirname(os.path.abspath(__file__))
LIMIT = int(os.environ.get("REPLICA_LIMIT", "180"))
WORKERS = int(os.environ.get("REPLICA_WORKERS", "4"))


def tests_of(tests_dir):
    """[(ns, test)] for every deftest under tests_dir/jank_lean."""
    out = []
    src = os.path.join(tests_dir, "jank_lean")
    for f in sorted(os.listdir(src)):
        if not f.endswith(".jank"):
            continue
        text = open(os.path.join(src, f), encoding="utf-8").read()
        ns = re.search(r"\(ns\s+([\w.-]+)", text).group(1)
        out += [(ns, t) for t in re.findall(r"\(deftest\s+([\w?!*<>=+-]+)", text)]
    return out


def outcome(returncode, text):
    if returncode != 0:
        return f"exit {returncode}"
    if re.search(r"^(FAIL|ERROR) in", text, re.M):
        return "fail"
    return "pass"


def main():
    tests_dir = os.path.abspath(sys.argv[1])
    prefixes = sys.argv[2:]
    build = build_name()
    out_dir = os.path.join(HERE, "..", "conformance", "out", "replica-runs", build)
    os.makedirs(out_dir, exist_ok=True)
    tests = [(ns, t) for ns, t in tests_of(tests_dir)
             if not prefixes or any(t.startswith(p + "-") for p in prefixes)]
    print(f"jank: {JANK} ({build}); {len(tests)} tests; output in {os.path.normpath(out_dir)}",
          flush=True)

    copies = [tempfile.mkdtemp(prefix=f"replica-{build}-") for _ in range(WORKERS)]
    for c in copies:
        shutil.copytree(tests_dir, c, dirs_exist_ok=True)
    free = list(copies)
    lock = threading.Lock()
    env = dict(os.environ, LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
    results = {}

    def run(ns, test):
        with lock:
            work = free.pop()
        cmd = [JANK, "--module-path", ".", "run-main", "run-one", "--", ns, test]
        began = time.time()
        try:
            p = subprocess.run(cmd, cwd=work, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=LIMIT)
            text = p.stdout.decode("utf-8", "replace")
            result = outcome(p.returncode, text)
        except subprocess.TimeoutExpired as e:
            text = (e.stdout or b"").decode("utf-8", "replace")
            result = "timeout"
        finally:
            with lock:
                free.append(work)
        with open(os.path.join(out_dir, f"{ns}.{test}.txt"), "w") as f:
            f.write(f"# {' '.join(cmd)}\n# {result}, {time.time() - began:.0f} s\n{text}")
        return f"{ns}/{test}", result

    try:
        with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
            for key, result in pool.map(lambda nt: run(*nt), tests):
                results[key] = result
                print(f"{key}: {result}", flush=True)
    finally:
        for c in copies:
            shutil.rmtree(c, ignore_errors=True)
    path = os.path.join(out_dir, "..", build + ".json")
    old = json.load(open(path)) if os.path.exists(path) else {}
    old.update(results)
    json.dump(old, open(path, "w"), indent=1, sort_keys=True)
    counts = {}
    for r in results.values():
        counts[r] = counts.get(r, 0) + 1
    print(f"done: {counts}; all results in {os.path.normpath(path)}", flush=True)


if __name__ == "__main__":
    main()
