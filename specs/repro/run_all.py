"""Runs the reproductions on one jank and keeps what each printed.

    python3 run_all.py                      # every file, on `jank` from the PATH
    JANK=~/.local/bin/jank-main python3 run_all.py
    JANK=... python3 run_all.py sort-empty-crashes.cljc nrepl-done-with-eval-error.py

Each `.cljc` and `.jank` file runs as `$JANK run --module-path . FILE`, each `.py` file with
`$JANK` set (they start jank themselves), all from a copy of this directory made for the run,
so that two builds never share what jank writes beside the files. What each printed is kept in
`../conformance/out/repro-runs/BUILD/FILE.txt`, BUILD named after where the jank binary is
(`homebrew-0.1`, the date of a build installed by ../install-jank-main.sh, or $JANK_BUILD),
and a line per file says how it ended. Each file prints its checks as `expected X, WHAT: GOT`;
BUILD.json beside the outputs keeps them, and a file's verdict: "like Clojure" when every
check got what it expected (and it ended normally), else "still there". Some checks write the
expected value another way than the result prints, so a fix can leave the verdict "still
there": check_runs.py also compares what each check got with a recorded run.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
JANK = os.environ.get("JANK", "jank")
LIMIT = int(os.environ.get("REPRO_LIMIT", "600"))


def build_name():
    """The build's name: $JANK_BUILD, or from where its binary really is."""
    if os.environ.get("JANK_BUILD"):
        return os.environ["JANK_BUILD"]
    path = shutil.which(JANK) or JANK
    real = os.path.realpath(path)
    if os.path.basename(real) == "jank" and "/shim/" not in real:
        parts = real.split(os.sep)
        if "Cellar" in parts:
            return "homebrew-" + parts[parts.index("Cellar") + 2]
    # A shim made by install-jank-main.sh: .../share/jank/DATE/shim/jank.
    parts = real.split(os.sep)
    if "shim" in parts:
        return parts[parts.index("shim") - 1]
    return real.strip(os.sep).replace(os.sep, "_")


def files(names):
    if names:
        return names
    return sorted(f for f in os.listdir(HERE)
                  if f.endswith((".cljc", ".jank", ".py"))
                  and not f.startswith(("_", "jank_harness", "run_", "repro_require_lib")))


def norm(s):
    return " ".join(s.split())


def checks(text):
    """The lines `expected X, WHAT: GOT` (or `expected X: GOT`) a file printed, each with
    whether GOT is X. A description doesn't hold a colon; an expected value may hold commas."""
    out = []
    for line in text.splitlines():
        line = line.strip()
        m = (re.match(r"^expected (.*?), ([^:]*?):\s+(.*)$", line)
             or re.match(r"^expected (.+?)():\s+(.*)$", line))
        if m:
            x, what, got = m.groups()
            out.append({"what": norm(what), "expected": norm(x), "got": norm(got),
                        "same": norm(x) == norm(got)})
    return out


def run(name, work, out_dir):
    """One file: (name, how it ended, seconds)."""
    env = dict(os.environ, JANK=JANK)
    if name.endswith(".py"):
        cmd = [sys.executable, os.path.join(work, name)]
    else:
        cmd = [JANK, "run", "--module-path", ".", name]
    began = time.time()
    try:
        p = subprocess.run(cmd, cwd=work, env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=LIMIT)
        text, ended = p.stdout.decode("utf-8", "replace"), f"exit {p.returncode}"
    except subprocess.TimeoutExpired as e:
        text = (e.stdout or b"").decode("utf-8", "replace")
        ended = f"still running after {LIMIT} s: stopped"
    seconds = time.time() - began
    with open(os.path.join(out_dir, name + ".txt"), "w") as f:
        f.write(f"# {' '.join(cmd)}\n# {ended}, {seconds:.0f} s\n{text}")
    return name, ended, seconds, text


def main():
    build = build_name()
    out_dir = os.path.join(HERE, "..", "conformance", "out", "repro-runs", build)
    os.makedirs(out_dir, exist_ok=True)
    work = tempfile.mkdtemp(prefix=f"repro-{build}-")
    shutil.copytree(HERE, work, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("__pycache__", "target"))
    names = files(sys.argv[1:])
    print(f"jank: {JANK} ({build}); {len(names)} files; output in {os.path.normpath(out_dir)}",
          flush=True)
    # The concurrency findings run many times and measure: one file at a time.
    results = {}
    try:
        for name in names:
            name, ended, seconds, text = run(name, work, out_dir)
            cs = checks(text)
            verdict = ("like Clojure" if cs and all(c["same"] for c in cs) and ended == "exit 0"
                       else "still there")
            results[name] = {"ended": ended, "verdict": verdict, "checks": cs}
            print(f"{name}: {ended}, {seconds:.0f} s, {verdict}", flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    # BUILD.json beside the outputs: each file's end, verdict and checks.
    path = os.path.join(out_dir, "..", build + ".json")
    old = json.load(open(path)) if os.path.exists(path) else {}
    old.update(results)
    json.dump(old, open(path, "w"), indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
